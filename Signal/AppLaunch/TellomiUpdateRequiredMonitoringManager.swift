//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// Tellomi（tellomi/tellomi#1139）：什么时候用「必须更新」阻断页盖住整个 App。
///
/// 照上游 `ClockSkewMonitoringManager` 的做法：过期状态一变（`AppExpiry.AppExpiryDidChange`，499 与到期定时器都会发），
/// 以及每次回到前台，都重新判断一次。盖不盖按 owner 2026-09-24 定的三条规则（taishi 中转包 6）：
/// - 只有服务端判定的（499、远程配置宣布到期）才盖；本机构建到期只降成只读（上游的会话列表提示 + 输入框换成「更新」）。
/// - 没有可用的更新渠道（App Store / TestFlight 对外开放之前）不盖：按钮无处可去，直接只读。
/// - 用户在阻断页选了「暂不更新，只看聊天记录」，这个版本就不再盖；装上新版本，这个选择就作废。
/// 连 Signal 官方服务时保持上游行为。
class TellomiUpdateRequiredMonitoringManager {
    private let appExpiry: AppExpiry
    private let windowManager: WindowManager
    private let userDefaults: UserDefaults

    init(
        appExpiry: AppExpiry,
        windowManager: WindowManager,
        userDefaults: UserDefaults = CurrentAppContext().appUserDefaults(),
    ) {
        self.appExpiry = appExpiry
        self.windowManager = windowManager
        self.userDefaults = userDefaults
    }

    func start() {
        AssertIsOnMainThread()

        windowManager.updateRequiredViewChatsOnlyHandler = { [weak self] in
            self?.chooseViewChatsOnly()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateIsBlocked),
            name: AppExpiry.AppExpiryDidChange,
            object: nil,
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateIsBlocked),
            name: .OWSApplicationDidBecomeActive,
            object: nil,
        )

        updateIsBlocked()
    }

    @objc
    private func updateIsBlocked() {
        AssertIsOnMainThread()

        windowManager.isUpdateRequiredBlockActive = Self.shouldBlock(
            appExpiry: appExpiry,
            now: Date(),
            isTellomiDeployment: !TSConstants.isUsingProductionService,
            hasUpdateChannel: Self.hasUpdateChannel(appStoreUrl: TSConstants.appStoreUrl),
            viewChatsOnlyChosen: Self.viewChatsOnlyChosen(userDefaults: userDefaults, currentAppVersion: AppVersionImpl.shared.currentAppVersion),
        )
    }

    /// 阻断页上确认了「暂不更新，只看聊天记录」。收起阻断页以后，锁上着就先看到应用锁（WindowManager 照常处理）。
    private func chooseViewChatsOnly() {
        AssertIsOnMainThread()

        Self.recordViewChatsOnly(userDefaults: userDefaults, currentAppVersion: AppVersionImpl.shared.currentAppVersion)
        updateIsBlocked()
    }

    static func shouldBlock(
        appExpiry: AppExpiry,
        now: Date,
        isTellomiDeployment: Bool,
        hasUpdateChannel: Bool,
        viewChatsOnlyChosen: Bool,
    ) -> Bool {
        guard isTellomiDeployment, appExpiry.isExpired(now: now) else {
            return false
        }
        // 规则 2：本机构建到期只降成只读，不盖。
        guard !appExpiry.isBuildTooOld(now: now) else {
            return false
        }
        // 规则 3、规则 1。
        return hasUpdateChannel && !viewChatsOnlyChosen
    }

    /// 规则 3 的判据：「立即更新」打开的 `appStoreUrl` 是不是我们自己的 App Store / TestFlight 条目。
    /// 上游是 Signal 的 App Store 条目，Signal-iOS#23 之后是官网下载页（还没上架），都不算，所以现在 iOS 不会盖阻断页。
    /// 上架后把 `appStoreUrl` 换成 App Store 地址，这里自然成立；阻断页的按钮也就不可能把人送去装 Signal。
    static func hasUpdateChannel(appStoreUrl: URL) -> Bool {
        guard
            let host = appStoreUrl.host?.lowercased(),
            ["apps.apple.com", "itunes.apple.com", "testflight.apple.com"].contains(host)
        else {
            return false
        }
        return !appStoreUrl.path.contains("id874139669")
    }

    static let viewChatsOnlyVersionKey = "TellomiUpdateRequiredViewChatsOnlyVersion"

    static func viewChatsOnlyChosen(userDefaults: UserDefaults, currentAppVersion: String) -> Bool {
        return userDefaults.string(forKey: viewChatsOnlyVersionKey) == currentAppVersion
    }

    static func recordViewChatsOnly(userDefaults: UserDefaults, currentAppVersion: String) {
        userDefaults.set(currentAppVersion, forKey: viewChatsOnlyVersionKey)
    }
}
