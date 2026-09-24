//
// Copyright 2019 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Thrown when a request isn't sent because the app is already expired.
public struct AppExpiredError: Error {}

public final class AppExpiry {

    public static let appExpiredStatusCode: UInt = 499

    private let keyValueStore: KeyValueStore

    private let appVersion: AppVersionNumber4
    private let buildDate: Date

    private struct ExpirationState: Codable, Equatable {
        let appVersion: String

        enum Mode: String, Codable {
            case `default`
            case immediately
            case atDate
        }

        let mode: Mode

        let expirationDate: Date?

        init(appVersion: String, mode: Mode = .default, expirationDate: Date? = nil) {
            self.appVersion = appVersion
            self.mode = mode
            self.expirationDate = expirationDate

            // It'd be great to enforce this with an associated object
            // on the enum, but Codable conformance with associated
            // objects is a very manual process.
            owsAssertDebug(mode != .atDate || expirationDate != nil)
        }
    }

    private let expirationState: AtomicValue<ExpirationState>

    static let keyValueCollection = "AppExpiry"
    static let keyValueKey = "expirationState"

    public convenience init(appVersion: any AppVersion) {
        self.init(appVersion: appVersion.currentAppVersion4, buildDate: appVersion.buildDate)
    }

#if TESTABLE_BUILD

    public static func forUnitTests(buildDate: Date = Date()) -> Self {
        return Self(appVersion: try! AppVersionNumber4(AppVersionNumber("1.2.3.4")), buildDate: buildDate)
    }

#endif

    public init(
        appVersion: AppVersionNumber4,
        buildDate: Date,
    ) {
        self.keyValueStore = KeyValueStore(collection: Self.keyValueCollection)
        self.appVersion = appVersion
        self.buildDate = buildDate

        self.expirationState = AtomicValue(
            .init(appVersion: appVersion.wrappedValue.rawValue, mode: .default),
            lock: .sharedGlobal,
        )
    }

    public func warmCaches(with tx: DBReadTransaction) {
        let persistedExpirationState: ExpirationState? = try? self.keyValueStore.getCodableValue(
            forKey: Self.keyValueKey,
            failDebugOnParseError: false,
            transaction: tx,
        )

        // We only want to restore the persisted state if it's for our current version.
        guard
            let persistedExpirationState,
            persistedExpirationState.appVersion == appVersion.wrappedValue.rawValue
        else {
            return
        }

        expirationState.set(persistedExpirationState)
    }

    private func updateExpirationState(_ state: ExpirationState, db: any DB) async {
        expirationState.set(state)

        await db.awaitableWrite { transaction in
            do {
                // Don't write or fire notification if the value hasn't changed.
                let oldState: ExpirationState? = try self.keyValueStore.getCodableValue(
                    forKey: Self.keyValueKey,
                    transaction: transaction,
                )
                if let oldState, oldState == state {
                    return
                }
            } catch {
                owsFailDebug("Error reading expiration state \(error)")
            }
            do {
                try self.keyValueStore.setCodable(
                    state,
                    key: Self.keyValueKey,
                    transaction: transaction,
                )
            } catch {
                owsFailDebug("Error persisting expiration state \(error)")
            }
        }

        await didUpdateExpirationState()
    }

    @MainActor
    private func didUpdateExpirationState() {
        _refreshExpirationTimerIfStarted()
        NotificationCenter.default.post(name: Self.AppExpiryDidChange, object: nil)
    }

    public func setHasAppExpiredAtCurrentVersion(db: any DB) async {
        Logger.warn("")

        let newState = ExpirationState(appVersion: appVersion.wrappedValue.rawValue, mode: .immediately)
        await updateExpirationState(newState, db: db)
    }

    public func setExpirationDateForCurrentVersion(_ newExpirationDate: Date?, now: Date, db: any DB) async {
        guard !isExpired(now: now) else {
            Logger.warn("Ignoring expiration date change for expired build.")
            return
        }

        let newState: ExpirationState
        if let newExpirationDate {
            Logger.warn("Considering remote expiration of \(newExpirationDate)")
            // Ignore any expiration date that is later than when the app expires by default.
            guard newExpirationDate < defaultExpirationDate else { return }
            newState = .init(
                appVersion: appVersion.wrappedValue.rawValue,
                mode: .atDate,
                expirationDate: newExpirationDate,
            )
        } else {
            newState = .init(appVersion: appVersion.wrappedValue.rawValue, mode: .default)
        }
        await updateExpirationState(newState, db: db)
    }

    public static let AppExpiryDidChange = Notification.Name("AppExpiryDidChange")

    public var expirationDate: Date {
        let state = expirationState.get()
        switch state.mode {
        case .default:
            return defaultExpirationDate
        case .atDate:
            guard let expirationDate = state.expirationDate else {
                owsFailDebug("Missing expiration date, expiring immediately")
                return .distantPast
            }
            return expirationDate
        case .immediately:
            return .distantPast
        }
    }

    public func isExpired(now: Date) -> Bool { expirationDate < now }

    /// Tellomi（tellomi/tellomi#1139）：「必须更新」阻断页要分辨「构建本身过了有效期」和「服务端拒绝（499）/
    /// 远程配置宣布到期」，两种说法不同。过期状态是私有的，这里只暴露构建年龄这一条。
    public func isBuildTooOld(now: Date) -> Bool { defaultExpirationDate < now }

    // Tellomi（tellomi/tellomi#1142，需求 app-update-and-version-policy 第 3.6 节）：上游 90 天。Tellomi 发版没那么勤，
    // 90 天不发版所有人会同时停止收发；兜底保留，时长三端统一 180 天（owner 可改）。
    public static let defaultExpirationInterval: TimeInterval = 180 * .day

    private var defaultExpirationDate: Date {
        return buildDate.addingTimeInterval(Self.defaultExpirationInterval)
    }

    @MainActor
    private var expirationWorkItem: DispatchWorkItem?

    @MainActor
    private func _refreshExpirationTimerIfStarted() {
        if self.expirationWorkItem != nil {
            self.refreshExpirationTimer()
        }
    }

    @MainActor
    public func refreshExpirationTimer() {
        let now = Date()
        let expirationDate = self.expirationDate

        self.expirationWorkItem?.cancel()
        self.expirationWorkItem = nil

        guard now < expirationDate else {
            return
        }

        let expirationDelay = self.expirationDate.timeIntervalSince(now)
        let wallDeadline: DispatchWallTime = .now() + expirationDelay

        // This is a DispatchWorkItem so that we can use the wall clock.
        let expirationWorkItem = DispatchWorkItem(block: { [weak self] in
            NotificationCenter.default.post(name: Self.AppExpiryDidChange, object: nil)
            self?.refreshExpirationTimer()
        })
        self.expirationWorkItem = expirationWorkItem
        DispatchQueue.main.asyncAfter(wallDeadline: wallDeadline, execute: expirationWorkItem)
    }
}

// MARK: - Tellomi：跨境单独告知与同意（tellomi/tellomi#1133）

/// 服务端还在香港的这段时间，**同意跨境之前不发任何网络请求**（需求 `docs/product/specs/privacy-compliance-hk-cross-border.md`
/// 2.1 / 2.7）。和「App 过期」同一种闸：`OWSChatConnection._canOpenWebSocketError()` 不开连接，`OWSURLSession` 直接失败。
/// 失败时报的是 `OWSHTTPError.networkFailure(.genericFailure)`（和「没网」一样），各处本来就会按没网处理、稍后重试，
/// 不会走到只在 Debug 构建里崩的 `owsFailDebug`。
/// 实测：全新安装启动 11 秒内就连了 grpc.chat.tellomi.app（未注册连接），用户什么都还没同意（#1133 的评论）。
/// 记录放在 App Group 的 UserDefaults，通知扩展也读得到。**告知文字是草稿**，版本号等 #1132 定稿后对齐 `docs/legal/manifest.json`。
public enum TellomiCrossBorderConsent {
    /// 告知文本的版本。文本有实质变化就改这里，已经同意过的人会被重新询问（同意前网络也会重新关上）。
    public static let noticeVersion = "0.1.0-draft"

    public static let didChangeNotification = Notification.Name("TellomiCrossBorderConsentDidChange")

    private static let versionKey = "TellomiCrossBorderConsent.version"
    private static let dateKey = "TellomiCrossBorderConsent.date"

    public static var hasAgreed: Bool {
        CurrentAppContext().appUserDefaults().string(forKey: versionKey) == noticeVersion
    }

    /// 网络闸：还没同意就不联网。单元测试里不拦——测试用的是假网络，拦了只会让无关的用例失败。
    public static var blocksNetwork: Bool {
        !CurrentAppContext().isRunningTests && !hasAgreed
    }

    /// 本机记一份（版本 + 时间），然后放开网络。服务端的最小记录点由 taishi 设计（tellomi/tellomi#1133）。
    public static func recordAgreement() {
        let defaults = CurrentAppContext().appUserDefaults()
        defaults.set(noticeVersion, forKey: versionKey)
        defaults.set(Date(), forKey: dateKey)
        NotificationCenter.default.postOnMainThread(name: didChangeNotification, object: nil)
    }
}
