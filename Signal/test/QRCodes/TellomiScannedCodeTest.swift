//
// Copyright 2026 Tellomi
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

import SignalServiceKit
@testable import Signal
@testable import SignalUI

/// Tellomi（tellomi/tellomi#947，需求 `share-qr-and-invite.md` §3.2）：一个扫码器认所有 Tellomi 的码；
/// 以及 #1113 的「接受」半边——通话链接 / 群邀请 / 用户名链接的解析器都认 tell.cc。
class TellomiScannedCodeTest: XCTestCase {
    private let linkDevicePayload = "?uuid=asd&pub_key=BQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

    func testUsernameLinkInBothShapes() throws {
        let usernameLink = try XCTUnwrap(Usernames.UsernameLink(handle: UUID(), entropy: Data(repeating: 7, count: 32)))
        let legacy = usernameLink.url.absoluteString
        XCTAssertTrue(legacy.hasPrefix("https://signal.me/#eu/"))
        // Desktop 的二维码是 tell.cc/u#eu/…
        let tellShape = legacy.replacingOccurrences(of: "https://signal.me/#eu/", with: "https://tell.cc/u#eu/")

        XCTAssertEqual(TellomiScannedCode(scannedString: legacy), .usernameLink(usernameLink))
        XCTAssertEqual(TellomiScannedCode(scannedString: tellShape), .usernameLink(usernameLink))
        XCTAssertEqual(TellomiScannedCode(scannedString: " \(tellShape)\n"), .usernameLink(usernameLink))
    }

    func testPlainUsernames() {
        XCTAssertEqual(TellomiScannedCode(scannedString: "https://tell.cc/ceshi.57"), .plainUsername("ceshi.57"))
        XCTAssertEqual(TellomiScannedCode(scannedString: "https://tell.cc/u#u/ceshi.57"), .plainUsername("ceshi.57"))
    }

    func testGroupInvitesInBothShapes() {
        let legacy = URL(string: "https://signal.group/#abc")!
        XCTAssertEqual(TellomiScannedCode(scannedString: "https://tell.cc/g#abc"), .groupInvite(legacy))
        XCTAssertEqual(TellomiScannedCode(scannedString: "https://signal.group/#abc"), .groupInvite(legacy))
        // 手机号名片不能被当成群邀请（Android #973 撞过的坑）
        XCTAssertNotEqual(TellomiScannedCode(scannedString: "https://tell.cc/u#p/+16505550100"), .groupInvite(legacy))
    }

    func testDeviceLinkCodesInBothSchemes() {
        let tellomi = "tellomi://linkdevice" + linkDevicePayload
        let legacy = "sgnl://linkdevice" + linkDevicePayload
        XCTAssertEqual(TellomiScannedCode(scannedString: tellomi), .deviceLink(tellomi))
        XCTAssertEqual(TellomiScannedCode(scannedString: legacy), .deviceLink(legacy))
    }

    func testQuickRestoreCodesAreNotShownAsText() {
        // 新手机快速恢复码：与应用内相机同一个处理，不落到「显示内容」
        let legacy = "sgnl://rereg" + linkDevicePayload
        XCTAssertEqual(TellomiScannedCode(scannedString: legacy), .quickRestore(legacy))
    }

    func testAnythingElseIsShownNotIgnored() {
        XCTAssertEqual(TellomiScannedCode(scannedString: "https://example.com/a?b=c"), .other("https://example.com/a?b=c"))
        XCTAssertEqual(TellomiScannedCode(scannedString: "  你好 hello  "), .other("你好 hello"))
    }

    func testCallLinkParserAcceptsTellShape() throws {
        let callLink = CallLink.generate()
        let legacy = callLink.url().absoluteString
        XCTAssertTrue(legacy.hasPrefix("https://signal.link/call/#key="))
        let tellShape = legacy.replacingOccurrences(of: "https://signal.link/call/#", with: "https://tell.cc/call#")
        let tellShapeWithSlash = legacy.replacingOccurrences(of: "https://signal.link/call/#", with: "https://tell.cc/call/#")

        XCTAssertEqual(CallLink(url: try XCTUnwrap(URL(string: tellShape))), callLink)
        XCTAssertEqual(CallLink(url: try XCTUnwrap(URL(string: tellShapeWithSlash))), callLink)
        XCTAssertEqual(CallLink(url: try XCTUnwrap(URL(string: legacy))), callLink)
    }
}
