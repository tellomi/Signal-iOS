//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import XCTest
@testable import SignalServiceKit

/// card-visual §3.2 / §3.3 / §3.8（tellomi/tellomi#1423）：卡片的版式和按自己图片取的颜色由 rust/links 定
/// （`layout` / `tint`），客户端只读结果、不自己算。与 Android `TellomiLinkVisualTest`、Desktop `linkCardVisual_test` 同一批用例。
final class TellomiLinkVisualTest: XCTestCase {

    private let orange = """
    {"tinted":true,"source":"#FE7500","light":{"background":"#FE7500","text":"#000000"},"dark":{"background":"#994600","text":"#FFFFFF"}}
    """
    private let card = TellomiLinkCard(level: .generic, domain: "bilibili.com", tintable: true)

    private struct FakeBridge: TellomiLinkVisual.Bridge {
        var layoutName = "icon"
        var tintJson = ""
        var fails = false
        var onLayout: (UInt32, UInt32, String, String) -> Void = { _, _, _, _ in }
        var onTint: (String, UInt32, UInt32, Data) -> Void = { _, _, _, _ in }

        func layout(imageWidth: UInt32, imageHeight: UInt32, kind: String, level: String) throws -> String {
            struct Failure: Error {}
            if fails { throw Failure() }
            onLayout(imageWidth, imageHeight, kind, level)
            return layoutName
        }

        func tint(layout: String, width: UInt32, height: UInt32, rgba: Data) throws -> String {
            struct Failure: Error {}
            if fails { throw Failure() }
            onTint(layout, width, height, rgba)
            return tintJson
        }
    }

    func testTheFourShapesAreReadAnythingElseIsNoDecision() {
        XCTAssertEqual(TellomiLinkVisual.parseLayout("first_party"), .firstParty)
        XCTAssertEqual(TellomiLinkVisual.parseLayout("large_image"), .largeImage)
        XCTAssertEqual(TellomiLinkVisual.parseLayout("icon"), .icon)
        XCTAssertEqual(TellomiLinkVisual.parseLayout("no_image"), .noImage)
        XCTAssertNil(TellomiLinkVisual.parseLayout("hologram"))
        XCTAssertNil(TellomiLinkVisual.parseLayout(""))
        XCTAssertNil(TellomiLinkVisual.parseLayout("\"icon\""))
    }

    func testATintedResultHasALightAndADarkSetOfColours() {
        let tint = TellomiLinkVisual.parseTint(orange)
        XCTAssertEqual(
            tint,
            TellomiLinkVisual.Tint(
                tinted: true,
                light: .init(background: .init(red: 0xFE, green: 0x75, blue: 0x00), text: .init(red: 0, green: 0, blue: 0)),
                dark: .init(background: .init(red: 0x99, green: 0x46, blue: 0x00), text: .init(red: 0xFF, green: 0xFF, blue: 0xFF)),
            ),
        )
        XCTAssertEqual(tint?.colors(isDark: false)?.background, .init(red: 0xFE, green: 0x75, blue: 0x00))
        XCTAssertEqual(tint?.colors(isDark: true)?.background, .init(red: 0x99, green: 0x46, blue: 0x00))
        XCTAssertEqual(tint?.colors(isDark: true)?.text, .init(red: 0xFF, green: 0xFF, blue: 0xFF))
    }

    func testANeutralImageKeepsTheDefaultColours() {
        let tint = TellomiLinkVisual.parseTint(##"{"tinted":false,"source":"#808082"}"##)
        XCTAssertEqual(tint, TellomiLinkVisual.Tint(tinted: false))
        XCTAssertNil(tint?.colors(isDark: false))
        XCTAssertNil(TellomiLinkVisual.Tint(tinted: true).colors(isDark: true))
    }

    func testAnythingItDoesNotUnderstandIsNoDecision() {
        XCTAssertNil(TellomiLinkVisual.parseTint("not json"))
        XCTAssertNil(TellomiLinkVisual.parseTint("{}"))
        XCTAssertNil(TellomiLinkVisual.parseTint(##"{"tinted":true}"##))
        // 不是 #RRGGBB 的颜色不用。
        XCTAssertNil(TellomiLinkVisual.parseTint(
            ##"{"tinted":true,"light":{"background":"red","text":"#000000"},"dark":{"background":"#994600","text":"#FFFFFF"}}"##,
        ))
        XCTAssertNil(TellomiLinkVisual.parseTint(
            ##"{"tinted":true,"light":{"background":"#FE750","text":"#000000"},"dark":{"background":"#994600","text":"#FFFFFF"}}"##,
        ))
    }

    func testOnlyThirdPartyCardsWithAnImageAreTintedAndNeverInAMessageRequest() {
        XCTAssertTrue(TellomiLinkVisual.shouldTint(card: card, layout: .icon, isMessageRequest: false))
        XCTAssertTrue(TellomiLinkVisual.shouldTint(card: card, layout: .largeImage, isMessageRequest: false))
        XCTAssertFalse(TellomiLinkVisual.shouldTint(card: card, layout: .icon, isMessageRequest: true))
        var notTintable = card
        notTintable.tintable = false
        XCTAssertFalse(TellomiLinkVisual.shouldTint(card: notTintable, layout: .icon, isMessageRequest: false))
        var payment = card
        payment.payment = true
        XCTAssertFalse(TellomiLinkVisual.shouldTint(card: payment, layout: .icon, isMessageRequest: false))
        XCTAssertFalse(TellomiLinkVisual.shouldTint(card: card, layout: .firstParty, isMessageRequest: false))
        XCTAssertFalse(TellomiLinkVisual.shouldTint(card: card, layout: .noImage, isMessageRequest: false))
        XCTAssertFalse(TellomiLinkVisual.shouldTint(card: card, layout: nil, isMessageRequest: false))
        XCTAssertFalse(TellomiLinkVisual.shouldTint(card: nil, layout: .icon, isMessageRequest: false))
    }

    func testTheLayoutIsAskedForTheSizeOfTheImageTheCardShowsAndNoneForACardThatShowsNone() {
        var asked = [[String]]()
        var bridge = FakeBridge()
        bridge.onLayout = { asked.append(["\($0)", "\($1)", $2, $3]) }

        var structured = card
        structured.level = .structured
        structured.kind = "video"
        XCTAssertEqual(TellomiLinkVisual.layout(bridge: bridge, card: structured, imageWidth: 1200, imageHeight: 630), .icon)
        XCTAssertEqual(asked[0], ["1200", "630", "video", "structured"])

        var firstParty = card
        firstParty.level = .firstParty
        firstParty.kind = "tellomi.group"
        _ = TellomiLinkVisual.layout(bridge: bridge, card: firstParty, imageWidth: 1200, imageHeight: 630)
        XCTAssertEqual(asked[1], ["1200", "630", "tellomi.group", "first_party"])

        var noImage = card
        noImage.showImage = false
        _ = TellomiLinkVisual.layout(bridge: bridge, card: noImage, imageWidth: 1200, imageHeight: 630)
        XCTAssertEqual(asked[2], ["0", "0", "", "generic"], "不显示图的卡，问的时候没有图")

        var plain = card
        plain.level = .plainLink
        _ = TellomiLinkVisual.layout(bridge: bridge, card: plain, imageWidth: 0, imageHeight: 0)
        XCTAssertEqual(asked[3][3], "plain_link")
    }

    func testABridgeThatFailsIsNoDecision() {
        var failing = FakeBridge()
        failing.fails = true
        XCTAssertNil(TellomiLinkVisual.layout(bridge: failing, card: card, imageWidth: 100, imageHeight: 100))
        XCTAssertNil(TellomiLinkVisual.tint(bridge: failing, layout: .icon, rgba: Data(count: 32 * 32 * 4)))
    }

    func testTheTintIsAskedWithA32By32RGBAImage() {
        var seen: (String, UInt32, UInt32, Int)?
        var bridge = FakeBridge(tintJson: orange)
        bridge.onTint = { seen = ($0, $1, $2, $3.count) }

        XCTAssertNotNil(TellomiLinkVisual.tint(bridge: bridge, layout: .icon, rgba: Data(count: 32 * 32 * 4)))
        XCTAssertEqual(seen?.0, "icon")
        XCTAssertEqual(seen?.1, 32)
        XCTAssertEqual(seen?.2, 32)
        XCTAssertEqual(seen?.3, 32 * 32 * 4)

        // 不是 32×32×4 字节的像素不交给 rust/links。
        seen = nil
        XCTAssertNil(TellomiLinkVisual.tint(bridge: bridge, layout: .icon, rgba: Data(count: 10)))
        XCTAssertNil(seen)
    }

    func testACardGetsItsShapeAndTheColoursOfItsImage() {
        let bridge = FakeBridge(tintJson: orange)
        let visual = TellomiLinkVisual.decide(bridge: bridge, card: card, imageWidth: 100, imageHeight: 100) { Data(count: 32 * 32 * 4) }
        XCTAssertEqual(visual.layout, .icon)
        XCTAssertEqual(visual.tint?.colors(isDark: false)?.background, .init(red: 0xFE, green: 0x75, blue: 0x00))
    }

    func testNoCardNoDecision() {
        XCTAssertEqual(
            TellomiLinkVisual.decide(bridge: FakeBridge(), card: nil, imageWidth: 100, imageHeight: 100) { XCTFail("not read"); return nil },
            TellomiLinkVisual.Visual.none,
        )
        XCTAssertEqual(
            TellomiLinkVisual.decide(bridge: FakeBridge(layoutName: "hologram"), card: card, imageWidth: 100, imageHeight: 100) { XCTFail("not read"); return nil },
            TellomiLinkVisual.Visual.none,
        )
    }

    func testACardThatIsNotTintedNeverReadsItsImage() {
        var notTintable = card
        notTintable.tintable = false
        XCTAssertEqual(
            TellomiLinkVisual.decide(bridge: FakeBridge(), card: notTintable, imageWidth: 100, imageHeight: 100) { XCTFail("not read"); return nil },
            TellomiLinkVisual.Visual(layout: .icon, tint: nil),
        )

        var firstParty = card
        firstParty.level = .firstParty
        XCTAssertEqual(
            TellomiLinkVisual.decide(bridge: FakeBridge(layoutName: "first_party"), card: firstParty, imageWidth: 100, imageHeight: 100) { XCTFail("not read"); return nil },
            TellomiLinkVisual.Visual(layout: .firstParty, tint: nil),
        )

        XCTAssertEqual(
            TellomiLinkVisual.decide(bridge: FakeBridge(layoutName: "no_image"), card: card, imageWidth: 0, imageHeight: 0) { XCTFail("not read"); return nil },
            TellomiLinkVisual.Visual(layout: .noImage, tint: nil),
        )
    }

    func testAnImageThatIsNotOnTheDeviceYetGivesAShapeAndNoColours() {
        XCTAssertEqual(
            TellomiLinkVisual.decide(bridge: FakeBridge(), card: card, imageWidth: 100, imageHeight: 100) { nil },
            TellomiLinkVisual.Visual(layout: .icon, tint: nil),
        )
    }

    func testANeutralImageGivesNoColours() {
        let bridge = FakeBridge(tintJson: ##"{"tinted":false,"source":"#808082"}"##)
        XCTAssertEqual(
            TellomiLinkVisual.decide(bridge: bridge, card: card, imageWidth: 100, imageHeight: 100) { Data(count: 32 * 32 * 4) },
            TellomiLinkVisual.Visual(layout: .icon, tint: nil),
        )
    }
}
