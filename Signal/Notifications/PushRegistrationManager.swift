//
// Copyright 2017 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
public import PushKit
public import SignalServiceKit
import UIKit

public enum PushRegistrationError: Error {
    case assertionError(description: String)
    case pushNotSupported(description: String)
    case timeout
    /// Tellomi（tellomi/tellomi#1338）：还没同意跨境告知，不向 Apple 要令牌，见 `requestPushTokens`。
    case crossBorderConsentRequired
}

/**
 * Singleton used to integrate with push notification services - registration and routing received remote notifications.
 */
public class PushRegistrationManager: NSObject, PKPushRegistryDelegate {

    private let appReadiness: AppReadiness

    init(appReadiness: AppReadiness) {
        self.appReadiness = appReadiness
        (preauthChallengeGuarantee, preauthChallengeFuture) = Guarantee<String>.pending()

        super.init()

        // Tellomi（tellomi/tellomi#1338）：同意跨境之后，把之前被闸挡下的那次补上，见 `requestPushTokens`。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(crossBorderConsentDidChange),
            name: TellomiCrossBorderConsent.didChangeNotification,
            object: nil,
        )
    }

    // Coordinates blocking of the calloutQueue while we wait for an incoming call
    private let incomingCallFuture = AtomicValue<GuaranteeFuture<Void>?>(nil, lock: .init())

    // Private callout queue that we can use to synchronously wait for our call to start
    // TODO: Rewrite call message routing to be able to synchronously report calls
    private static let calloutQueue = DispatchQueue(
        label: "org.signal.push-registration",
        autoreleaseFrequency: .workItem,
    )
    private var calloutQueue: DispatchQueue { Self.calloutQueue }

    private var vanillaTokenPromise: Promise<Data>?
    private var vanillaTokenFuture: Future<Data>?

    @MainActor
    private var voipRegistry: PKPushRegistry?

    /// Tellomi（tellomi/tellomi#1338）：同意跨境之前有人要过令牌、被闸挡下了（已注册的人升级上来，启动 / 回前台时）。
    @MainActor
    private var hasHeldBackTokenRequestUntilCrossBorderConsent = false

    private var preauthChallengeGuarantee: Guarantee<String>
    private var preauthChallengeFuture: GuaranteeFuture<String>

    // MARK: Public interface

    public func needsNotificationAuthorization() async -> Bool {
        let notificationSettings = await UNUserNotificationCenter.current().notificationSettings()
        return notificationSettings.authorizationStatus == .notDetermined
    }

    public typealias ApnRegistrationId = RegistrationRequestFactory.ApnRegistrationId

    /// - parameter timeOutEventually: If the OS fails to get back to us with the apns token after
    /// we have requested it and significant time has passed, do we time out or keep waiting? Default to keep waiting.
    @MainActor
    public func requestPushTokens(
        forceRotation: Bool,
        timeOutEventually: Bool = false,
    ) async throws -> ApnRegistrationId {
        Logger.info("")
        // Tellomi（tellomi/tellomi#1338）：跨境告知同意之前不向 Apple 要 APNs / PushKit 令牌（需求
        // privacy-compliance-hk-cross-border.md 2.1：「推送注册……都等同意之后」）。已注册的人升级上来、还没同意时，
        // 启动和回前台的 `SyncPushTokensJob` 都走到这里；以前只挡住了「把令牌传给服务端」，向 Apple 要令牌照样发生。
        // 新用户注册、关联设备都是先同意再要令牌，不受影响。挡下的这次在同意之后补一次（`crossBorderConsentDidChange`）。
        guard TellomiCrossBorderConsent.hasAgreed else {
            Logger.warn("Cross-border notice not accepted yet; not requesting APNs / PushKit tokens.")
            hasHeldBackTokenRequestUntilCrossBorderConsent = true
            throw PushRegistrationError.crossBorderConsentRequired
        }
        // Tellomi（tellomi/tellomi#1112、#1218 F-01）：上游在这里无条件 requestAuthorization，于是注册中途拿令牌时
        // 系统通知框会直接弹出来（没有说明、也不在用户做相关操作时）。通知授权改由首屏说明页的「继续」去问
        // （`TellomiNotificationPrimer`）；还没问过（.notDetermined）时这里只拿令牌、不弹框。
        // iOS 10 起 APNs 令牌（含注册用的静默推送挑战）不依赖用户授权；上面那条「必须先注册设置才给令牌」的注释是 iOS 8 时代的。
        // 已经问过的（允许 / 拒绝）照上游：requestAuthorization 不会再弹框，只会把通知分类登记上。
        if await self.needsNotificationAuthorization() {
            Logger.info("Notification authorization not determined yet; fetching push token without prompting.")
        } else {
            await self.registerUserNotificationSettings()
        }

#if targetEnvironment(simulator)
        if TSConstants.isUsingProductionService {
            throw PushRegistrationError.pushNotSupported(description: "Production APNs isn't supported on simulators.")
        }
#endif

        let vanillaPushToken = try await registerForVanillaPushToken(forceRotation: forceRotation, timeOutEventually: timeOutEventually)

        // We need the voip registry to handle voip pushes relayed from the NSE.
        createVoipRegistryIfNecessary()

        return ApnRegistrationId(apnsToken: vanillaPushToken)
    }

    public func didFinishReportingIncomingCall() {
        incomingCallFuture.swap(nil)?.resolve()
    }

    // MARK: Tellomi：跨境同意之后补一次（tellomi/tellomi#1338）

    @MainActor
    @objc
    private func crossBorderConsentDidChange() {
        guard hasHeldBackTokenRequestUntilCrossBorderConsent, TellomiCrossBorderConsent.hasAgreed else {
            return
        }
        hasHeldBackTokenRequestUntilCrossBorderConsent = false
        Logger.info("Cross-border notice accepted; syncing the push tokens held back before.")
        syncPushTokensAfterCrossBorderConsent()
    }

    /// 拿令牌并报给服务端（启动时那一次被闸挡掉了，不补要等下次启动）。单元测试里换掉：`SyncPushTokensJob` 要用 `AppEnvironment`。
    func syncPushTokensAfterCrossBorderConsent() {
        SyncPushTokensJob.run()
    }

    // MARK: Vanilla push token

    /// Receives a pre-auth challenge token.
    ///
    /// Notably, this method is not responsible for requesting these tokens—that must be
    /// managed elsewhere. Before you request one, you should call this method.
    public func receivePreAuthChallengeToken() async -> String { await preauthChallengeGuarantee.awaitable() }

    /// Clears any existing pre-auth challenge token. If none exists, this method does nothing.
    public func clearPreAuthChallengeToken() {
        if preauthChallengeGuarantee.isSealed {
            (preauthChallengeGuarantee, preauthChallengeFuture) = Guarantee<String>.pending()
        }
    }

    public func didReceiveVanillaPreAuthChallengeToken(_ challenge: String) {
        appReadiness.runNowOrWhenAppDidBecomeReadySync {
            AssertIsOnMainThread()
            Logger.info("received vanilla preauth challenge")
            self.preauthChallengeFuture.resolve(challenge)
        }
    }

    // Vanilla push token is obtained from the system via AppDelegate
    public func didReceiveVanillaPushToken(_ tokenData: Data) {
        guard let vanillaTokenFuture = self.vanillaTokenFuture else {
            Logger.warn("System volunteered a push token even though we didn't request one. Syncing.")
            Task {
                do {
                    try await SyncPushTokensJob(mode: .normal).run()
                    Logger.info("Done syncing push tokens after system volunteered one.")
                } catch {
                    Logger.error("Failed to sync push tokens after system volunteered one.")
                }
            }
            return
        }

        vanillaTokenFuture.resolve(tokenData)
    }

    // Vanilla push token is obtained from the system via AppDelegate
    public func didFailToReceiveVanillaPushToken(error: Error) {
        guard let vanillaTokenFuture = self.vanillaTokenFuture else {
            owsFailDebug("promise completion in \(#function) unexpectedly nil")
            return
        }

        vanillaTokenFuture.reject(error)
    }

    // MARK: PKPushRegistryDelegate - voIP Push Token

    public func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType) {
        assertOnQueue(calloutQueue)
        owsAssertDebug(type == .voIP)

        // Synchronously wait until the app is ready.
        let appReady = DispatchSemaphore(value: 0)
        appReadiness.runNowOrWhenAppDidBecomeReadySync {
            appReady.signal()
        }
        appReady.wait()

        // This branch MUST start a CallKit call before it returns or else we risk
        // a PushKit penalty that may prevent us from handling future calls.
        let callRelayPayload = CallMessagePushPayload(payload.dictionaryPayload)
        if let callRelayPayload {
            Logger.info("Received VoIP push from the NSE: \(callRelayPayload)")
            let (guarantee, future) = Guarantee<Void>.pending()
            incomingCallFuture.set(future)
            AppEnvironment.shared.callService.earlyRingNextIncomingCall.set(true)
            CallMessageRelay.handleVoipPayload(callRelayPayload)
            Logger.info("Waiting for call to start: \(callRelayPayload)")
            guarantee.timeout(
                on: DispatchQueue.global(qos: .userInitiated),
                seconds: 5,
                substituteValue: (),
            ).wait()
            Logger.info("Returning back to PushKit. Good luck! \(callRelayPayload)")
            return
        }

        owsFailDebug("Ignoring PKPush without a valid payload.")
    }

    public func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
        // voip tokens are no longer supported
    }

    public func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        // It's not clear when this would happen. We've never previously handled it, but we should at
        // least start learning if it happens.
        owsFailDebug("Invalid state")
    }

    // MARK: helpers

    // User notification settings must be registered *before* AppDelegate will
    // return any requested push tokens.
    public func registerUserNotificationSettings() async {
        await SSKEnvironment.shared.notificationPresenterRef.registerNotificationSettings()
    }

    /**
     * When users have disabled notifications and background fetch, the system hangs when returning a push token.
     * More specifically, after registering for remote notification, the app delegate calls neither
     * `didFailToRegisterForRemoteNotificationsWithError` nor `didRegisterForRemoteNotificationsWithDeviceToken`
     * This behavior is identical to what you'd see if we hadn't previously registered for user notification settings, though
     * in this case we've verified that we *have* properly registered notification settings.
     */
    @MainActor
    private func isSusceptibleToFailedPushRegistration() async -> Bool {
        // Only affects users who have disabled both: background refresh *and* notifications
        guard UIApplication.shared.backgroundRefreshStatus == .denied else {
            Logger.info("has backgroundRefreshStatus != .denied, not susceptible to push registration failure")
            return false
        }

        let notificationSettings = await UNUserNotificationCenter.current().notificationSettings()

        // This was ported from UIApplication.shared.currentUserNotificationSettings.types == [] so it only looks at these three settings.
        guard notificationSettings.alertSetting != .enabled, notificationSettings.badgeSetting != .enabled, notificationSettings.soundSetting != .enabled else {
            Logger.info("notificationSettings was not empty, not susceptible to push registration failure.")
            return false
        }

        Logger.warn("background refresh and notifications were disabled. Device is susceptible to push registration failure.")
        return true
    }

    @MainActor
    private func registerForVanillaPushToken(
        forceRotation: Bool,
        timeOutEventually: Bool,
    ) async throws -> String {
        Logger.info("")

        if let vanillaTokenPromise {
            Logger.info("already pending promise for vanilla push token")
            return try await vanillaTokenPromise.awaitable().toHex()
        }

        // No pending vanilla token yet. Create a new promise
        let (promise, future) = Promise<Data>.pending()
        self.vanillaTokenPromise = promise
        defer { self.vanillaTokenPromise = nil }
        self.vanillaTokenFuture = future

        if forceRotation {
            UIApplication.shared.unregisterForRemoteNotifications()
        }
        UIApplication.shared.registerForRemoteNotifications()

        if timeOutEventually {
            do {
                return try await withUncooperativeTimeout(seconds: 20, operation: {
                    return try await self._registerForVanillaPushToken(promise)
                })
            } catch is UncooperativeTimeoutError {
                throw PushRegistrationError.timeout
            }
        } else {
            return try await _registerForVanillaPushToken(promise)
        }
    }

    @MainActor
    private func _registerForVanillaPushToken(_ promise: Promise<Data>) async throws -> String {
        let pushTokenData: Data
        do {
            pushTokenData = try await withUncooperativeTimeout(seconds: 10, operation: {
                return try await promise.awaitable()
            })
        } catch is UncooperativeTimeoutError {
            if await self.isSusceptibleToFailedPushRegistration() || Platform.isSimulator {
                // If we've timed out on a device known to be susceptible to failures, quit trying
                // so the user doesn't remain indefinitely hung for no good reason.
                throw PushRegistrationError.pushNotSupported(description: "Device configuration disallows push notifications")
            } else {
                Logger.warn("Push registration is taking a while. Continuing to wait since this configuration is not known to fail push registration.")
                // Sometimes registration can just take a while.
                // If we're not on a device known to be susceptible to push registration failure,
                // just return the original promise.
                pushTokenData = try await promise.awaitable()
            }
        }
        if await self.isSusceptibleToFailedPushRegistration() {
            // Sentinel in case this bug is fixed.
            owsFailDebug("Device was unexpectedly able to complete push registration even though it was susceptible to failure.")
        }
        Logger.info("successfully registered for vanilla push notifications")
        return pushTokenData.toHex()
    }

    @MainActor
    private func createVoipRegistryIfNecessary() {
        guard voipRegistry == nil else { return }
        let voipRegistry = PKPushRegistry(queue: calloutQueue)
        self.voipRegistry = voipRegistry
        voipRegistry.desiredPushTypes = [.voIP]
        voipRegistry.delegate = self
    }
}
