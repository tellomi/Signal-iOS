//
// Copyright 2026 Tellomi
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

/// Tellomi（tellomi/tellomi#1158「撞词」）：设备被登出不能写成「注销」。
/// 中文里「注销」是注销账号（7 天冷静期、本机记录立即删除），把「此设备不再登录」也叫「注销」，用户会以为账号没了。
/// 这两句是上游翻译带进来的，同步上游翻译时容易被换回去，这里钉住（测试进程只跑英文，所以直接读 zh_CN.lproj）。
final class TellomiLogoutWordingTest: XCTestCase {
    func testDeviceLoggedOutIsWordedAsLoggedOutNotAccountDeletion() throws {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "zh_CN", ofType: "lproj"))
        let bundle = try XCTUnwrap(Bundle(path: path))
        for key in ["DEREGISTRATION_WARNING", "NOT_REGISTERED_BOTTOM"] {
            let text = bundle.localizedString(forKey: key, value: nil, table: nil)
            XCTAssertNotEqual(text, key)
            XCTAssertFalse(text.contains("注销"), "\(key): \(text)")
            XCTAssertTrue(text.contains("退出登录"), "\(key): \(text)")
        }
    }
}
