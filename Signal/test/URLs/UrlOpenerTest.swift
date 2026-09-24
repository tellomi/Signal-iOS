//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

import SignalServiceKit
@testable import Signal

class UrlOpenerTest: XCTestCase {
    func testCanOpenWhenNotRegistered() {
        // We need to be able to parse URLs before global state has been
        // initialized. There's no perfect way to test for this, but we can
        // enumerate all the different parsers we may execute & ensure that they
        // can all return a result before we've created any global state.
        let urlsToTest: [String] = [
            "https://signal.me/#p/+16505550100",
            "https://signal.art/addstickers/#pack_id=00000000000000000000000000000000&pack_key=0000000000000000000000000000000000000000000000000000000000000000",
            "sgnl://addstickers/?pack_id=00000000000000000000000000000000&pack_key=0000000000000000000000000000000000000000000000000000000000000000",
            "https://signal.group",
            "https://signal.tube/#example.com",
            "sgnl://linkdevice/?uuid=00000000-0000-4000-8000-000000000000&pub_key=BQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        ]
        for urlToTest in urlsToTest {
            XCTAssertNotNil(UrlOpener.parseUrl(URL(string: urlToTest)!), "\(urlToTest)")
        }
    }

    // MARK: - Tellomi 形状（docs/signal/LINKS_AND_SCHEMES.md；与 Android #973 同一张表）

    func testTellomiShapesParse() {
        let urlsToTest: [String] = [
            "https://tell.cc/u#p/+16505550100",
            "tellomi://tell.cc/u#p/+16505550100",
            "https://tell.cc/u#u/ceshi.57",
            "tellomi://tell.cc/u#u/ceshi.57",
            "https://tell.cc/ceshi.57",
            "tellomi://tell.cc/ceshi.57",
            "https://tell.cc/g#CjQKIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEhAAAAAAAAAAAAAAAAAAAAAA",
            "tellomi://tell.cc/g#CjQKIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEhAAAAAAAAAAAAAAAAAAAAAA",
            "https://tell.cc/s#pack_id=00000000000000000000000000000000&pack_key=0000000000000000000000000000000000000000000000000000000000000000",
            "tellomi://addstickers/?pack_id=00000000000000000000000000000000&pack_key=0000000000000000000000000000000000000000000000000000000000000000",
            "tellomi://linkdevice/?uuid=00000000-0000-4000-8000-000000000000&pub_key=BQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        ]
        for urlToTest in urlsToTest {
            XCTAssertNotNil(UrlOpener.parseUrl(URL(string: urlToTest)!), "\(urlToTest)")
        }
    }

    func testTellomiLegacyEquivalent() {
        let cases: [(String, String)] = [
            ("https://tell.cc/u#p/+16505550100", "https://signal.me/#p/+16505550100"),
            ("tellomi://tell.cc/u#eu/abc", "https://signal.me/#eu/abc"),
            ("https://tell.cc/g#xyz", "https://signal.group/#xyz"),
            ("tellomi://tell.cc/s#pack_id=1&pack_key=2", "https://signal.art/addstickers/#pack_id=1&pack_key=2"),
            ("https://tell.cc/call#key=abcd", "https://signal.link/call/#key=abcd"),
            ("tellomi://linkdevice/?uuid=1&pub_key=2", "sgnl://linkdevice/?uuid=1&pub_key=2"),
            ("tellomicaptcha://turnstile.k.registration.t", "signalcaptcha://turnstile.k.registration.t"),
            // 不是 Tellomi 形状的原样返回
            ("https://signal.me/#p/+16505550100", "https://signal.me/#p/+16505550100"),
            ("sgnl://linkdevice/?uuid=1", "sgnl://linkdevice/?uuid=1"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(TellomiLinks.legacyEquivalent(of: URL(string: input)!).absoluteString, expected, input)
        }
        XCTAssertEqual(TellomiLinks.plainUsername(in: URL(string: "https://tell.cc/u#u/ceshi.57")!), "ceshi.57")
        XCTAssertEqual(TellomiLinks.plainUsername(in: URL(string: "tellomi://tell.cc/u/#u/linktest.56")!), "linktest.56")
        // 裸形状（与 Android 对齐）：tell.cc/<username>，带 `.<数字>` 判别位才算用户名，保留字路径不算
        XCTAssertEqual(TellomiLinks.plainUsername(in: URL(string: "https://tell.cc/ceshi.57")!), "ceshi.57")
        XCTAssertEqual(TellomiLinks.plainUsername(in: URL(string: "tellomi://tell.cc/linktest.56/")!), "linktest.56")
        XCTAssertNil(TellomiLinks.plainUsername(in: URL(string: "https://tell.cc/u")!))
        XCTAssertNil(TellomiLinks.plainUsername(in: URL(string: "https://tell.cc/call#key=abc")!))
        XCTAssertNil(TellomiLinks.plainUsername(in: URL(string: "https://tell.cc/u#p/+16505550100")!))
        XCTAssertNil(TellomiLinks.plainUsername(in: URL(string: "https://tell.cc/g#u/notauser")!))
        // tell.cc/u#p/… 不能被当成群邀请（Android #973 撞过的坑）
        XCTAssertNil(PossibleGroupInviteLinkUrl.parseFrom(TellomiLinks.legacyEquivalent(of: URL(string: "https://tell.cc/u#p/+16505550100")!)))
    }

    // MARK: - 「扫一扫」统一（tellomi/tellomi#947）

    func testScannedCodeClassification() throws {
        let usernameLink = try XCTUnwrap(Usernames.UsernameLink(handle: UUID(), entropy: Data(repeating: 7, count: 32)))
        let legacyUsernameUrl = usernameLink.url.absoluteString
        let tellomiUsernameUrl = legacyUsernameUrl.replacingOccurrences(of: "https://signal.me/#eu/", with: "https://tell.cc/u#eu/")
        XCTAssertNotEqual(legacyUsernameUrl, tellomiUsernameUrl)
        for scanned in [legacyUsernameUrl, tellomiUsernameUrl] {
            guard case .usernameLink(let parsed) = TellomiScannedCode.classify(scanned) else {
                return XCTFail("\(scanned) should be a username link")
            }
            XCTAssertEqual(parsed, usernameLink)
        }

        let pubKey = "BQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        for scanned in [
            "sgnl://linkdevice?uuid=00000000-0000-4000-8000-000000000000&pub_key=\(pubKey)",
            "tellomi://linkdevice?uuid=00000000-0000-4000-8000-000000000000&pub_key=\(pubKey)",
        ] {
            guard case .linkDevice = TellomiScannedCode.classify(scanned) else {
                return XCTFail("\(scanned) should be a device-linking code")
            }
        }
        for scanned in [
            "sgnl://rereg?uuid=00000000-0000-4000-8000-000000000000&pub_key=\(pubKey)",
            "tellomi://rereg?uuid=00000000-0000-4000-8000-000000000000&pub_key=\(pubKey)",
        ] {
            guard case .quickRestore = TellomiScannedCode.classify(scanned) else {
                return XCTFail("\(scanned) should be a quick-restore code")
            }
        }

        // 明文用户名、群邀请：和点链接一样交给 UrlOpener
        for scanned in [
            "https://tell.cc/ceshi.57",
            "https://tell.cc/u#u/ceshi.57",
            "https://tell.cc/g#CjQKIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEhAAAAAAAAAAAAAAAAAAAAAA",
        ] {
            guard case .openableUrl = TellomiScannedCode.classify(scanned) else {
                return XCTFail("\(scanned) should be opened like a tapped link")
            }
        }

        // 其它网址 / 文字：显示出来，不静默忽略（也不能走 UrlOpener 的 owsFailDebug）
        for scanned in ["https://example.com/menu", "WIFI:S:office;T:WPA;P:secret;;", "hello"] {
            guard case .other(let text) = TellomiScannedCode.classify(scanned) else {
                return XCTFail("\(scanned) should be shown as plain content")
            }
            XCTAssertEqual(text, scanned)
        }
    }
}
