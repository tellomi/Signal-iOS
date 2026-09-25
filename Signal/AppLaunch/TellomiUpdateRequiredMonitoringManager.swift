//
// Copyright 2026 Tellomi
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// Tellomi（tellomi/tellomi#1139）：App 被判定过期（服务端 499 / 构建过期）时，用「必须更新」阻断页盖住整个 App。
///
/// 照上游 `ClockSkewMonitoringManager` 的做法：过期状态一变（`AppExpiry.AppExpiryDidChange`，499 与到期定时器都会发），
/// 以及每次回到前台，都重新判断一次。连 Signal 官方服务时保持上游行为（只有会话列表那条提示）。
class TellomiUpdateRequiredMonitoringManager {
    private let appExpiry: AppExpiry
    private let windowManager: WindowManager

    init(appExpiry: AppExpiry, windowManager: WindowManager) {
        self.appExpiry = appExpiry
        self.windowManager = windowManager
    }

    func start() {
        AssertIsOnMainThread()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateIsBlocked),
            name: AppExpiry.AppExpiryDidChange,
            object: nil,
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateIsBlocked),
            name: UIApplication.didBecomeActiveNotification,
            object: nil,
        )

        updateIsBlocked()
    }

    @objc
    private func updateIsBlocked() {
        AssertIsOnMainThread()

        windowManager.updateRequiredBlockReason = Self.blockReason(
            appExpiry: appExpiry,
            now: Date(),
            isTellomiDeployment: !TSConstants.isUsingProductionService,
        )
    }

    /// 要不要拦、按哪种原因说。
    static func blockReason(
        appExpiry: AppExpiry,
        now: Date,
        isTellomiDeployment: Bool,
    ) -> TellomiUpdateRequiredAppBlockingViewController.Reason? {
        guard isTellomiDeployment, appExpiry.isExpired(now: now) else {
            return nil
        }
        return appExpiry.isBuildTooOld(now: now) ? .buildTooOld : .serverRejected
    }
}
