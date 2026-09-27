//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import LibSignalClient

/// 主设备「退出登录」（ADR-0072）：本机锁住，服务端不改。
///
/// - 退出（保留聊天记录，§4.1）：先按需让已链接设备退出（`DELETE /v1/devices/{id}`），再注销推送令牌
///   （`DELETE /v1/accounts/apn`），两步都成功才写本机的「已退出」标记。任何一步失败（比如没网）都**不退出**，
///   交给界面提示「退出登录需要联网，请稍后再试」。这样不会出现「App 已经退出，推送却还在来」。
/// - 退出并删除本机数据（§4.3）：上面两步尽量做，失败也不拦；之后由界面走现有的「删除所有数据」。
///
/// 服务端上这台设备一直是注册着的：别人发来的消息在服务器上排队，重新登录（只用验证会话证明本人，
/// **不调** `POST /v1/registration`）后收到。
public struct TellomiAccountLogout {

    public enum LogoutError: Error {
        /// 没网或连不上服务器：不退出。
        case networkUnavailable
        /// 服务端报错等其它失败：不退出。
        case failed(Error)
    }

    private let db: any DB
    private let deviceService: OWSDeviceService
    private let deviceStore: OWSDeviceStore
    private let networkManager: any NetworkManagerProtocol
    private let registrationStateChangeManager: RegistrationStateChangeManager
    private let registrationSessionManager: RegistrationSessionManager
    private let isReachable: () -> Bool
    private let forgetUploadedPushToken: () -> Void
    private let logger = PrefixedLogger(prefix: "[Logout]")

    public init(
        db: any DB,
        deviceService: OWSDeviceService,
        deviceStore: OWSDeviceStore,
        networkManager: any NetworkManagerProtocol,
        registrationStateChangeManager: RegistrationStateChangeManager,
        registrationSessionManager: RegistrationSessionManager,
        isReachable: @escaping () -> Bool,
        forgetUploadedPushToken: @escaping () -> Void,
    ) {
        self.db = db
        self.deviceService = deviceService
        self.deviceStore = deviceStore
        self.networkManager = networkManager
        self.registrationStateChangeManager = registrationStateChangeManager
        self.registrationSessionManager = registrationSessionManager
        self.isReachable = isReachable
        self.forgetUploadedPushToken = forgetUploadedPushToken
    }

    public static func fromGlobals() -> TellomiAccountLogout {
        return TellomiAccountLogout(
            db: DependenciesBridge.shared.db,
            deviceService: DependenciesBridge.shared.deviceService,
            deviceStore: DependenciesBridge.shared.deviceStore,
            networkManager: SSKEnvironment.shared.networkManagerRef,
            registrationStateChangeManager: DependenciesBridge.shared.registrationStateChangeManager,
            registrationSessionManager: DependenciesBridge.shared.registrationSessionManager,
            isReachable: { SSKEnvironment.shared.reachabilityManagerRef.isReachable },
            forgetUploadedPushToken: { SSKEnvironment.shared.preferencesRef.unsetRecordedAPNSTokens() },
        )
    }

    /// `DELETE /v1/accounts/apn`：服务端清掉这台设备的 APNs 令牌（`AccountController.deleteApnRegistrationId`），
    /// 之后不再给它发推送；消息照样存进队列（`MessageSender` 在设备没登记推送时只是不推）。
    public static func deletePushTokenRequest() -> TSRequest {
        return TSRequest(
            url: URL(string: "v1/accounts/apn")!,
            method: "DELETE",
            parameters: nil,
        )
    }

    /// 本机记着的设备列表里有没有已链接设备（替代方案页据此决定显不显示「同时让已链接的设备退出」）。
    public func hasLinkedDevices(tx: DBReadTransaction) -> Bool {
        return deviceStore.hasLinkedDevices(tx: tx)
    }

    /// 刷新一次已链接设备列表（尽量；失败就用本机记着的）。
    public func refreshLinkedDevicesBestEffort() async {
        guard isReachable() else { return }
        do {
            _ = try await deviceService.refreshDevices()
        } catch {
            logger.warn("Couldn't refresh linked devices: \(error)")
        }
    }

    /// 退出登录（保留聊天记录）。按 ADR-0072 §4.1 的顺序：已链接设备（可选）→ 推送令牌 → 本机标记。
    public func logOut(alsoUnlinkLinkedDevices: Bool) async throws(LogoutError) {
        guard isReachable() else {
            logger.warn("Not reachable; staying logged in")
            throw .networkUnavailable
        }
        var didAttemptPushTokenDeletion = false
        do {
            if alsoUnlinkLinkedDevices {
                try await unlinkLinkedDevices()
            }
            didAttemptPushTokenDeletion = true
            _ = try await networkManager.asyncRequest(Self.deletePushTokenRequest())
        } catch {
            logger.warn("Logout failed; staying logged in: \(error)")
            if didAttemptPushTokenDeletion {
                // 请求可能已经到了服务端、只是回应丢了：让下一次同步重新登记令牌，别停在「登录着却收不到推送」。
                forgetUploadedPushToken()
            }
            if error.isNetworkFailureOrTimeout {
                throw .networkUnavailable
            }
            throw .failed(error)
        }
        // 重新登录时要重新登记令牌（SyncPushTokensJob 看到本机没记着令牌就会上传）。
        forgetUploadedPushToken()
        await db.awaitableWrite { tx in
            // 重新登录必须重新收一次验证码：丢掉本机可能还记着的旧验证会话（它可能早就 verified 了）。
            registrationSessionManager.clearPersistedSession(tx)
            registrationStateChangeManager.setIsTellomiLoggedOut(true, tx: tx)
        }
        logger.info("Logged out on this device")
    }

    /// 退出并删除本机数据之前（ADR-0072 §4.3 第 1 步）：尽量注销推送令牌（勾了的话也让已链接设备退出），失败或没网都不拦。
    public func signOffBestEffortBeforeDeletingLocalData(alsoUnlinkLinkedDevices: Bool) async {
        guard isReachable() else {
            logger.warn("Not reachable; deleting local data without signing off")
            return
        }
        do {
            try await withUncooperativeTimeout(seconds: Self.bestEffortTimeout) {
                if alsoUnlinkLinkedDevices {
                    do {
                        try await self.unlinkLinkedDevices()
                    } catch {
                        self.logger.warn("Couldn't unlink linked devices: \(error)")
                    }
                }
                _ = try await self.networkManager.asyncRequest(Self.deletePushTokenRequest())
            }
        } catch {
            logger.warn("Couldn't delete push token: \(error)")
        }
    }

    static let bestEffortTimeout: TimeInterval = 15

    private func unlinkLinkedDevices() async throws {
        _ = try await deviceService.refreshDevices()
        let linkedDevices = db.read { tx in
            deviceStore.fetchAll(tx: tx).filter { !$0.deviceId.isPrimary }
        }
        for device in linkedDevices {
            logger.info("Unlinking device \(device.deviceId)")
            try await deviceService.unlinkDevice(deviceId: device.deviceId)
        }
    }
}

// MARK: - 打码的手机号

/// 欢迎页「上次登录」和换号确认里显示的号码：国家码 + 国内号码的前 3 位和后 4 位，中间四个星号，
/// 例如 `+86 138****5678`（ADR-0072 §4.1 第 4 步）。国内号码不够 8 位时只留后 4 位。
public enum TellomiMaskedPhoneNumber {
    public static func format(callingCode: String, nationalNumber: String) -> String {
        let digits = asciiDigits(nationalNumber)
        let masked: String
        if digits.count >= 8 {
            masked = "\(digits.prefix(3))****\(digits.suffix(4))"
        } else if digits.count > 4 {
            masked = "****\(digits.suffix(4))"
        } else {
            masked = "****"
        }
        return "+\(asciiDigits(callingCode)) \(masked)"
    }

    /// 从 E164 拆出国家码和国内号码再打码；拆不出国家码（不应该发生）就只露后 4 位。
    public static func format(e164: E164, phoneNumberUtil: PhoneNumberUtil) -> String {
        let digits = asciiDigits(e164.stringValue)
        if
            let callingCode = phoneNumberUtil.parseE164(e164)?.getCallingCode(),
            digits.hasPrefix("\(callingCode)")
        {
            let callingCodeString = "\(callingCode)"
            return format(callingCode: callingCodeString, nationalNumber: String(digits.dropFirst(callingCodeString.count)))
        }
        return "+****\(digits.suffix(4))"
    }

    private static func asciiDigits(_ string: String) -> String {
        return String(string.filter { ("0"..."9").contains($0) })
    }
}
