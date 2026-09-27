//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SafariServices
import XCTest
@testable import SignalUI

/// ADR-0063 §4.9 第 3 步的显式浏览器：`javascript:` 以及任何非 http(s) 的 URL 都不产生跳转（§8.1 第 7 行）。
@MainActor
final class TellomiExplicitBrowserTest: XCTestCase {

    private final class RecordingPresenter: TellomiExplicitBrowserPresenting {
        var presented = [SFSafariViewController]()

        func presentExplicitBrowser(_ viewController: SFSafariViewController) {
            presented.append(viewController)
        }
    }

    func testNonHttpSchemesProduceNoNavigation() throws {
        let presenter = RecordingPresenter()
        let rejected = [
            "javascript:alert(document.cookie)",
            "JavaScript:alert(1)",
            "javascript://tell.cc/%0Aalert(1)",
            "data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg==",
            "file:///private/var/mobile/Library/SMS/sms.db",
            "intent://scan/#Intent;scheme=zxing;package=com.google.zxing.client.android;end",
            "tel:+8613800000004",
            "sms:+8613800000004",
            "mailto:someone@tellomi.app",
            "sgnl://joingroup",
            "tellomi://tell.cc/u",
            "alipays://platformapi/startapp?appId=20000067",
            "weixin://dl/business",
            "ftp://ftp.tellomi-test.cn/file",
            "about:blank",
            "https:///no-host",
        ]
        for rawUrl in rejected {
            let url = try XCTUnwrap(URL(string: rawUrl), rawUrl)
            XCTAssertNil(TellomiExplicitBrowser.navigableUrl(url), rawUrl)
            XCTAssertNil(TellomiExplicitBrowser.makeViewController(for: url), rawUrl)
            XCTAssertFalse(TellomiExplicitBrowser.open(url, from: presenter), rawUrl)
        }
        XCTAssertEqual(presenter.presented.count, 0)
    }

    func testHttpsOpensInTheExplicitBrowser() throws {
        let presenter = RecordingPresenter()
        for rawUrl in ["https://www.bilibili.com/video/BV1GJ411x7h7", "HTTPS://tellomi.app/security", "http://www.tellomi-test.cn/"] {
            let url = try XCTUnwrap(URL(string: rawUrl))
            XCTAssertEqual(TellomiExplicitBrowser.navigableUrl(url), url)
            XCTAssertTrue(TellomiExplicitBrowser.open(url, from: presenter), rawUrl)
        }
        XCTAssertEqual(presenter.presented.count, 3)
        XCTAssertEqual(presenter.presented.first?.dismissButtonStyle, .close)
    }
}
