//
// Copyright 2026 Tellomi
// SPDX-License-Identifier: AGPL-3.0-only
//

import UserNotifications
import XCTest

@testable import Signal

/// Tellomi（tellomi/tellomi#1218 F-01、#1112）：首屏通知说明页与「通知已关闭」提示条的判定。
final class TellomiNotificationPrimerTest: XCTestCase {

    func testPrimerShowsOnceWhileNotDetermined() {
        XCTAssertTrue(TellomiNotificationPrimer.shouldShowPrimer(authorizationStatus: .notDetermined, hasShown: false))
        // 点过「继续」就不再出，哪怕系统框被用户划掉、状态还是 notDetermined
        XCTAssertFalse(TellomiNotificationPrimer.shouldShowPrimer(authorizationStatus: .notDetermined, hasShown: true))
    }

    func testPrimerNeverShowsOnceTheSystemHasAsked() {
        // 老版本注册时已经问过（授了 / 拒了）的用户升级上来，不再出说明页
        for status: UNAuthorizationStatus in [.authorized, .denied, .provisional, .ephemeral] {
            XCTAssertFalse(TellomiNotificationPrimer.shouldShowPrimer(authorizationStatus: status, hasShown: false), "\(status.rawValue)")
        }
    }

    func testReminderOnlyWhenDenied() {
        XCTAssertTrue(TellomiNotificationPrimer.shouldShowDisabledReminder(authorizationStatus: .denied))
        // 还没问过：不能在说明页之前先挂「已关闭」
        XCTAssertFalse(TellomiNotificationPrimer.shouldShowDisabledReminder(authorizationStatus: .notDetermined))
        for status: UNAuthorizationStatus in [.authorized, .provisional, .ephemeral] {
            XCTAssertFalse(TellomiNotificationPrimer.shouldShowDisabledReminder(authorizationStatus: status), "\(status.rawValue)")
        }
    }

    func testPrimerAndReminderNeverShowTogether() {
        for status: UNAuthorizationStatus in [.notDetermined, .denied, .authorized, .provisional, .ephemeral] {
            for hasShown in [false, true] {
                let primer = TellomiNotificationPrimer.shouldShowPrimer(authorizationStatus: status, hasShown: hasShown)
                let reminder = TellomiNotificationPrimer.shouldShowDisabledReminder(authorizationStatus: status)
                XCTAssertFalse(primer && reminder, "status=\(status.rawValue) hasShown=\(hasShown)")
            }
        }
    }
}
