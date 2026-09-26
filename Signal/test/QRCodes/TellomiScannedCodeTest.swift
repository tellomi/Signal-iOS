//
// Copyright 2026 Tellomi
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

import LibSignalClient
import SignalServiceKit
@testable import Signal
@testable import SignalUI

/// Tellomi（tellomi/tellomi#947，需求 `share-qr-and-invite.md` §3.2）：一个扫码器认所有 Tellomi 的码；
/// 以及 #1113 的「接受」半边——通话链接 / 群邀请 / 用户名链接的解析器都认 tell.cc。
class TellomiScannedCodeTest: XCTestCase {
    private let linkDevicePayload = "?uuid=asd&pub_key=BQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

    func testUsernameLinkInBothShapes() throws {
        let usernameLink = try XCTUnwrap(Usernames.UsernameLink(handle: UUID(), entropy: Data(repeating: 7, count: 32)))
        // #1113 之后生成的就是 tell.cc/u#eu/…（与 Desktop 相同）；旧版本发出过的 signal.me/#eu/… 仍要认
        let tellShape = usernameLink.url.absoluteString
        XCTAssertTrue(tellShape.hasPrefix("https://tell.cc/u#eu/"))
        let legacy = tellShape.replacingOccurrences(of: "https://tell.cc/u#eu/", with: "https://signal.me/#eu/")

        XCTAssertEqual(TellomiScannedCode(scannedString: legacy), .usernameLink(usernameLink))
        XCTAssertEqual(TellomiScannedCode(scannedString: tellShape), .usernameLink(usernameLink))
        XCTAssertEqual(TellomiScannedCode(scannedString: " \(tellShape)\n"), .usernameLink(usernameLink))
    }

    func testPlainUsernames() {
        XCTAssertEqual(TellomiScannedCode(scannedString: "https://tell.cc/ceshi.57"), .plainUsername("ceshi.57"))
        XCTAssertEqual(TellomiScannedCode(scannedString: "https://tell.cc/u#u/ceshi.57"), .plainUsername("ceshi.57"))
    }

    func testGroupInvitesInBothShapes() {
        // 存的是扫到的原链接（见 testGroupInviteKeepsTheOriginalLink）
        XCTAssertEqual(TellomiScannedCode(scannedString: "https://tell.cc/g#abc"), .groupInvite(URL(string: "https://tell.cc/g#abc")!))
        XCTAssertEqual(TellomiScannedCode(scannedString: "https://signal.group/#abc"), .groupInvite(URL(string: "https://signal.group/#abc")!))
        // 手机号名片不能被当成群邀请（Android #973 撞过的坑）
        if case .groupInvite = TellomiScannedCode(scannedString: "https://tell.cc/u#p/+16505550100") {
            XCTFail("tell.cc/u#p/… 被当成了群邀请")
        }
    }

    /// `rawValue` 会进发出去的链接预览；三端收消息都要求「预览 URL 出现在正文里」，
    /// 存换算后的 signal.group 形状，收件人的群卡片会被丢掉（taishi 审查 2026-09-24）。解码只读 fragment，新旧形状相同。
    func testGroupInviteKeepsTheOriginalLink() throws {
        for original in ["https://tell.cc/g#abc", "https://tell.cc/g/#abc", "tellomi://tell.cc/g#abc", "https://signal.group/#abc"] {
            let url = try XCTUnwrap(URL(string: original))
            let parsed = try XCTUnwrap(PossibleGroupInviteLinkUrl.parseFrom(url), original)
            XCTAssertEqual(parsed.rawValue, url, original)
            XCTAssertEqual(parsed.rawValue.fragment, "abc", original)
        }
    }

    /// #1113：群邀请生成 tell.cc/g#…，并且自己生成的能被自己解析回来
    func testGroupInviteLinkIsGeneratedInTellShapeAndRoundTrips() throws {
        let secretParams = try GroupSecretParams.generate()
        let link = try GroupInviteLink(masterKey: secretParams.getMasterKey(), inviteLinkPassword: GroupInviteLink.generateInviteLinkPassword())
        let url = link.url()
        XCTAssertTrue(url.absoluteString.hasPrefix("https://tell.cc/g#"))
        let parsed = try GroupInviteLink.parseFrom(try XCTUnwrap(PossibleGroupInviteLinkUrl.parseFrom(url)))
        XCTAssertEqual(parsed, link)
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

    /// 默认样式不带中心标：和显式传 `.brandedWithoutLogo` 生成的图逐字节相同（默认值改回带标会红）。
    /// 带标为什么不行，见 `QRCodeGenerator.generateQRCode` 的注释。
    func testDefaultQRCodeHasNoCenterMark() throws {
        let url = try XCTUnwrap(URL(string: "https://tell.cc/u#eu/abc"))
        let byDefault = try XCTUnwrap(QRCodeGenerator().generateQRCode(url: url)?.pngData())
        let withoutLogo = try XCTUnwrap(QRCodeGenerator().generateQRCode(url: url, stylingMode: .brandedWithoutLogo)?.pngData())
        XCTAssertEqual(byDefault, withoutLogo)
    }

    /// 和真实设备关联码长度相近的链接，默认样式生成 30 次，全部要能解出原文（取自已关闭的 Signal-iOS #27，taishi 审查建议并进来）。
    /// 注意它测不出「带标」：完美的数字图带标也能解，问题出在摄像头 / zbar 上，所以上面单独钉默认值。
    func testDefaultQRCodeDecodes() throws {
        let detector = try XCTUnwrap(CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh],
        ))

        for _ in 0..<30 {
            let pubKey = (0..<33).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
            let url = try XCTUnwrap(URL(string: "sgnl://linkdevice?uuid=\(UUID().uuidString)&pub_key=\(pubKey)"))

            let image = try XCTUnwrap(QRCodeGenerator().generateQRCode(url: url))

            // 生成的码是黑色前景、透明背景；先铺白底再解。
            let flattened = UIGraphicsImageRenderer(size: image.size).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: image.size))
                image.draw(at: .zero)
            }
            let ciImage = try XCTUnwrap(CIImage(image: flattened))
            let decoded = (detector.features(in: ciImage).first as? CIQRCodeFeature)?.messageString

            XCTAssertEqual(decoded, url.absoluteString)
        }
    }

    func testCallLinkParserAcceptsTellShape() throws {
        let callLink = CallLink.generate()
        // #1113 之后生成的是 tell.cc/call#key=…（不带斜杠）；带斜杠的（Desktop 发过）和旧的 signal.link/call/ 仍要认
        let tellShape = callLink.url().absoluteString
        XCTAssertTrue(tellShape.hasPrefix("https://tell.cc/call#key="))
        let tellShapeWithSlash = tellShape.replacingOccurrences(of: "https://tell.cc/call#", with: "https://tell.cc/call/#")
        let legacy = tellShape.replacingOccurrences(of: "https://tell.cc/call#", with: "https://signal.link/call/#")

        XCTAssertEqual(CallLink(url: try XCTUnwrap(URL(string: tellShape))), callLink)
        XCTAssertEqual(CallLink(url: try XCTUnwrap(URL(string: tellShapeWithSlash))), callLink)
        XCTAssertEqual(CallLink(url: try XCTUnwrap(URL(string: legacy))), callLink)
    }
}
