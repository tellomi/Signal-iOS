//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import SignalServiceKit

/// card-visual §3.6：读屏怎么读一张链接卡片，三端同一份拼法和措辞（`a11y-strings.md`）。
/// - 第三方卡：`[链接, 标题, 域名]`，缺哪段跳哪段，**不读副行**；
/// - 第一方卡：`[类型, 标题, 副标题, 按钮：动作]`，和类型重复的标题 / 副标题不再拼，官网卡不读「官方」徽标；
/// - 段与段之间按本语言的分隔符：简体 / 繁体「，」，英文「, 」。
final class TellomiLinkCardAccessibilityTest: XCTestCase {

    private typealias Strings = TellomiLinkCardAccessibility.Strings

    private let en = Strings(
        separator: ", ",
        link: "Link",
        button: { "button: \($0)" },
        kindGroup: "Tellomi group",
        kindStickerPack: "Tellomi sticker pack",
        kindUser: "Tellomi user",
        kindCall: "Tellomi call",
        kindOfficial: "Tellomi website",
    )

    private let zhHans = Strings(
        separator: "，",
        link: "链接",
        button: { "按钮：\($0)" },
        kindGroup: "Tellomi 群组",
        kindStickerPack: "Tellomi 贴纸包",
        kindUser: "Tellomi 用户",
        kindCall: "Tellomi 通话",
        kindOfficial: "Tellomi 官网",
    )

    private let zhHant = Strings(
        separator: "，",
        link: "連結",
        button: { "按鈕：\($0)" },
        kindGroup: "Tellomi 群組",
        kindStickerPack: "Tellomi 貼圖包",
        kindUser: "Tellomi 用戶",
        kindCall: "Tellomi 通話",
        kindOfficial: "Tellomi 官網",
    )

    private func thirdParty(_ strings: Strings, title: String?, domain: String?) -> String {
        TellomiLinkCardAccessibility.description(title: title, domain: domain, strings: strings)
    }

    private func firstParty(
        _ strings: Strings,
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

    func testAThirdPartyCardReadsLinkTitleAndDomainInEveryLanguage() {
        XCTAssertEqual(thirdParty(zhHans, title: "柯洁围棋入门课", domain: "bilibili.com"), "链接，柯洁围棋入门课，bilibili.com")
        XCTAssertEqual(thirdParty(zhHant, title: "柯潔圍棋入門課", domain: "bilibili.com"), "連結，柯潔圍棋入門課，bilibili.com")
        XCTAssertEqual(thirdParty(en, title: "Ke Jie Go Course", domain: "bilibili.com"), "Link, Ke Jie Go Course, bilibili.com")
    }

    /// 只显示卡片时整条消息就剩这一段：纯链接的标题位写的就是域名。
    func testAPlainLinkReadsLinkAndTheDomain() {
        XCTAssertEqual(thirdParty(zhHans, title: "bilibili.com", domain: nil), "链接，bilibili.com")
        XCTAssertEqual(thirdParty(en, title: nil, domain: "bilibili.com"), "Link, bilibili.com")
    }

    func testMissingPartsAreSkippedAndBlankOnesCountAsMissing() {
        XCTAssertEqual(thirdParty(en, title: "  ", domain: "taobao.com"), "Link, taobao.com")
        XCTAssertEqual(thirdParty(en, title: "Taobao", domain: nil), "Link, Taobao")
        XCTAssertEqual(thirdParty(en, title: "\n", domain: " "), "")
    }

    func testNothingToReadIsEmptyNotJustTheWordLink() {
        XCTAssertEqual(thirdParty(en, title: nil, domain: nil), "")
        XCTAssertEqual(thirdParty(zhHans, title: " ", domain: nil), "")
    }

    /// 分隔符跟着语言走：中文没有半角逗号，英文没有全角逗号。
    func testTheSeparatorFollowsTheLanguage() {
        XCTAssertFalse(thirdParty(zhHans, title: "标题", domain: "a.com").contains(","))
        XCTAssertFalse(thirdParty(en, title: "Title", domain: "a.com").contains("，"))
        XCTAssertEqual(thirdParty(en, title: "Title", domain: "a.com").components(separatedBy: ", ").count, 3)
    }

    // MARK: - 第一方卡

    func testAGroupCardReadsTheKindTheNameTheMembersAndTheButton() {
        XCTAssertEqual(
            firstParty(zhHans, .group, title: "读书会", subtitle: "12 位成员", action: "加入群聊"),
            "Tellomi 群组，读书会，12 位成员，按钮：加入群聊",
        )
        XCTAssertEqual(
            firstParty(zhHant, .group, title: "讀書會", subtitle: "12 個成員", action: "加入群組"),
            "Tellomi 群組，讀書會，12 個成員，按鈕：加入群組",
        )
        XCTAssertEqual(
            firstParty(en, .group, title: "Book Club", subtitle: "12 members", action: "Join Group"),
            "Tellomi group, Book Club, 12 members, button: Join Group",
        )
    }

    func testAStickerPackCard() {
        XCTAssertEqual(
            firstParty(zhHans, .sticker, title: "Bandit", subtitle: "24 个贴纸", action: "添加"),
            "Tellomi 贴纸包，Bandit，24 个贴纸，按钮：添加",
        )
        XCTAssertEqual(
            firstParty(en, .sticker, title: "Bandit", subtitle: "Added", action: "View"),
            "Tellomi sticker pack, Bandit, Added, button: View",
        )
    }

    /// 用户卡：标题是本地名字或 @nickname，副标题「Tellomi 用户」和类型那一段重复，不再拼。
    func testAUserCardDoesNotRepeatTellomiUser() {
        XCTAssertEqual(
            firstParty(zhHans, .user, title: "@kaixin", subtitle: "Tellomi 用户", action: "发消息"),
            "Tellomi 用户，@kaixin，按钮：发消息",
        )
        XCTAssertEqual(
            firstParty(en, .user, title: "@kaixin", subtitle: "Tellomi user", action: "Message"),
            "Tellomi user, @kaixin, button: Message",
        )
        // 认不出名字的用户卡：标题就是「Tellomi 用户」，没有副标题
        XCTAssertEqual(firstParty(zhHans, .user, title: "Tellomi 用户", action: "发消息"), "Tellomi 用户，按钮：发消息")
        XCTAssertEqual(firstParty(zhHant, .user, title: "Tellomi 用戶", action: "傳送訊息"), "Tellomi 用戶，按鈕：傳送訊息")
    }

    /// 官网卡：标题是固定的「Tellomi 官网」（和类型重复，不拼），副标题是路径；不读「官方」徽标。
    func testTheOfficialWebsiteCardReadsThePathAndNotTheBadge() {
        XCTAssertEqual(
            firstParty(zhHans, .official, title: "Tellomi 官网", subtitle: "/download", action: "打开", badge: true),
            "Tellomi 官网，/download，按钮：打开",
        )
        XCTAssertEqual(
            firstParty(en, .official, title: "Tellomi website", subtitle: "/download", action: "Open", badge: true),
            "Tellomi website, /download, button: Open",
        )
        XCTAssertFalse(firstParty(en, .official, title: "Tellomi website", action: "Open", badge: true).contains("Official"))
    }

    func testACallCardReadsTheRoomNameOrJustTheKind() {
        XCTAssertEqual(firstParty(zhHans, .call, title: "周五例会", action: "加入通话"), "Tellomi 通话，周五例会，按钮：加入通话")
        XCTAssertEqual(firstParty(zhHans, .call, title: "Tellomi 通话", action: "加入通话"), "Tellomi 通话，按钮：加入通话")
        XCTAssertEqual(firstParty(en, .call, title: "Tellomi call", action: "Join Call"), "Tellomi call, button: Join Call")
    }

    func testAFirstPartyCardWithoutASubtitleOrAButtonSkipsThem() {
        XCTAssertEqual(firstParty(en, .group, title: "群", action: "Open"), "Tellomi group, 群, button: Open")
        XCTAssertEqual(firstParty(en, .group, title: "群", subtitle: "  ", action: " "), "Tellomi group, 群")
    }
}
