//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit
import UIKit

class AppIconBadgeUpdater {
    private let badgeManager: BadgeManager

    init(badgeManager: BadgeManager) {
        self.badgeManager = badgeManager
    }

    func startObserving() {
        badgeManager.addObserver(self)
    }
}

extension AppIconBadgeUpdater: BadgeObserver {
    func didUpdateBadgeCount(_ badgeManager: BadgeManager, badgeCount: BadgeCount) {
        // Tellomi（ADR-0072 §4.1 第 3 步）：本机已退出登录时图标上不露未读数。
        if DependenciesBridge.shared.tsAccountManager.isTellomiLoggedOutWithMaybeSneakyTransaction {
            UIApplication.shared.applicationIconBadgeNumber = 0
            return
        }
        UIApplication.shared.applicationIconBadgeNumber = Int(badgeCount.unreadTotalCount)
    }
}
