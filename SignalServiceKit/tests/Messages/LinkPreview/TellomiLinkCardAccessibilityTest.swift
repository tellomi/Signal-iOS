//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import SignalServiceKit

/// card-visual §3.6：读屏怎么读一张链接卡片。只用卡片上可见的文字；第三方卡「链接，标题，副行，域名」，第一方卡「类型，名称，副行，官方，按钮：动作」。
final class TellomiLinkCardAccessibilityTest: XCTestCase {

    private let strings = TellomiLinkCardAccessibility.Strings(
        link: "Link",
        button: { "Button: \($0)" },
        tellomiGroup: "Tellomi group",
        tellomiStickerPack: "Tellomi sticker pack",
        officialBadge: "Official",
    )

    private func description(title: String?, subtitle: String? = nil, domain: String? = nil) -> String {
        TellomiLinkCardAccessibility.description(title: title, subtitle: subtitle, domain: domain, strings: strings)
    }

    private func firstParty(
        _ kind: TellomiFirstPartyCard.Kind,
        title: String,
        subtitle: String? = nil,
        action: String,
        badge: Bool = false,
    ) -> String {
        TellomiLinkCardAccessibility.description(
            firstParty: TellomiFirstPartyCard.Display(kind: kind, title: title, subtitle: subtitle, action: action, officialBadge: badge),
            strings: strings,
        )
    }

    // MARK: - 第三方卡

    func testAThirdPartyCardReadsLinkTitleSubtitleAndDomain() {
        XCTAssertEqual(description(title: "某个视频", subtitle: "某位 UP 主 · 4:17", domain: "bilibili.com"), "Link, 某个视频, 某位 UP 主 · 4:17, bilibili.com")
        XCTAssertEqual(description(title: "Wikipedia", domain: "wikipedia.org"), "Link, Wikipedia, wikipedia.org")
    }

    /// 只显示卡片时整条消息就剩这一段：纯链接的标题位写的就是域名。
    func testAPlainLinkReadsLinkAndTheDomain() {
        XCTAssertEqual(description(title: "bilibili.com"), "Link, bilibili.com")
        XCTAssertEqual(description(title: nil, domain: "bilibili.com"), "Link, bilibili.com")
    }

    func testMissingPartsAreSkippedAndBlankOnesCountAsMissing() {
        XCTAssertEqual(description(title: "  ", subtitle: "\n", domain: "taobao.com"), "Link, taobao.com")
        XCTAssertEqual(description(title: "Taobao", subtitle: "Product", domain: "taobao.com"), "Link, Taobao, Product, taobao.com")
    }

    func testNothingToReadIsEmptyNotJustTheWordLink() {
        XCTAssertEqual(description(title: nil), "")
        XCTAssertEqual(description(title: " ", subtitle: "", domain: nil), "")
    }

    // MARK: - 第一方卡

    func testAGroupCardSaysWhatItIsThenTheNameTheMembersAndTheButton() {
        XCTAssertEqual(
            firstParty(.group, title: "周末爬山群", subtitle: "128 members", action: "Join Group"),
            "Tellomi group, 周末爬山群, 128 members, Button: Join Group",
        )
    }

    func testAStickerPackCard() {
        XCTAssertEqual(
            firstParty(.sticker, title: "Bandit", subtitle: "24 stickers", action: "Add"),
            "Tellomi sticker pack, Bandit, 24 stickers, Button: Add",
        )
    }

    /// 用户卡、官网卡的标题 / 副行里本来就写着是什么，不再加类型。
    func testAUserCardAndTheOfficialWebsiteCardAlreadySayWhatTheyAre() {
        XCTAssertEqual(firstParty(.user, title: "@hk881qb", subtitle: "Tellomi user", action: "Message"), "@hk881qb, Tellomi user, Button: Message")
        XCTAssertEqual(firstParty(.user, title: "Tellomi user", action: "Message"), "Tellomi user, Button: Message")
        XCTAssertEqual(
            firstParty(.official, title: "Tellomi website", subtitle: "/download", action: "Open", badge: true),
            "Tellomi website, Official, /download, Button: Open",
        )
    }

    func testAFirstPartyCardWithoutASubtitleSkipsIt() {
        XCTAssertEqual(firstParty(.group, title: "群", action: "Open"), "Tellomi group, 群, Button: Open")
    }
}
