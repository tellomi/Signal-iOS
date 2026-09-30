//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import SignalServiceKit

/// card-visual §3.6：读屏念的词和拼法，简体、香港繁体、台湾繁体、英文各一份，逐字钉住（三端共用同一份，Android / Desktop 照同一张表）。
/// 不看当前语言，直接读 App 里每张语言表；用词和界面上已有的一致（链接 / 連結、貼圖包 / 贴纸包、群组 / 群組）。
final class TellomiLinkCardAccessibilityStringsTest: XCTestCase {

    /// 读屏专用的串（这一版新增的）：段与段之间的分隔符（中文「，」、英文「, 」带空格）、第三方卡的第一段、按钮那一段、第一方群卡和贴纸包卡的第一段。
    private static let expected: [String: [String: String]] = [
        "TELLOMI_LINK_CARD_A11Y_SEPARATOR": ["en": ", ", "zh_CN": "，", "zh_HK": "，", "zh_TW": "，"],
        "TELLOMI_LINK_CARD_A11Y_LINK": ["en": "Link", "zh_CN": "链接", "zh_HK": "連結", "zh_TW": "連結"],
        "TELLOMI_LINK_CARD_A11Y_BUTTON_FORMAT": ["en": "button: %@", "zh_CN": "按钮：%@", "zh_HK": "按鈕：%@", "zh_TW": "按鈕：%@"],
        "TELLOMI_LINK_CARD_A11Y_TELLOMI_GROUP": ["en": "Tellomi group", "zh_CN": "Tellomi 群组", "zh_HK": "Tellomi 群組", "zh_TW": "Tellomi 群組"],
        "TELLOMI_LINK_CARD_A11Y_TELLOMI_STICKER_PACK": ["en": "Tellomi sticker pack", "zh_CN": "Tellomi 贴纸包", "zh_HK": "Tellomi 貼圖包", "zh_TW": "Tellomi 貼圖包"],
    ]

    /// 第一方另外三种卡的第一段**沿用卡片上已有的串**（不新建同义串）；值必须和共用的那张表一样。
    private static let sharedKindStrings: [String: [String: String]] = [
        "TELLOMI_LINK_CARD_TELLOMI_USER": ["en": "Tellomi user", "zh_CN": "Tellomi 用户", "zh_HK": "Tellomi 用戶", "zh_TW": "Tellomi 用戶"],
        "TELLOMI_LINK_CARD_CALL_TITLE": ["en": "Tellomi call", "zh_CN": "Tellomi 通话", "zh_HK": "Tellomi 通話", "zh_TW": "Tellomi 通話"],
        "TELLOMI_LINK_CARD_OFFICIAL_TITLE": ["en": "Tellomi website", "zh_CN": "Tellomi 官网", "zh_HK": "Tellomi 官網", "zh_TW": "Tellomi 官網"],
    ]

    private func table(_ localization: String) throws -> [String: String] {
        let path = try XCTUnwrap(
            Bundle.main.app.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: localization),
            "no Localizable.strings for \(localization)",
        )
        return try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String], "unreadable table for \(localization)")
    }

    func testEveryLanguageHasTheExactWording() throws {
        for localization in ["en", "zh_CN", "zh_HK", "zh_TW"] {
            let table = try table(localization)
            for (key, values) in Self.expected.merging(Self.sharedKindStrings, uniquingKeysWith: { first, _ in first }) {
                XCTAssertEqual(table[key], values[localization], "\(localization) \(key)")
            }
        }
    }

    /// 分隔符：中文是全角「，」（U+FF0C，后面不带空格），英文是「, 」（半角逗号 + 一个空格）。
    func testTheSeparatorIsTheRightCharacterInEveryLanguage() throws {
        for localization in ["zh_CN", "zh_HK", "zh_TW"] {
            let separator = try XCTUnwrap(try table(localization)["TELLOMI_LINK_CARD_A11Y_SEPARATOR"])
            XCTAssertEqual(separator.unicodeScalars.map(\.value), [0xFF0C], localization)
        }
        let english = try XCTUnwrap(try table("en")["TELLOMI_LINK_CARD_A11Y_SEPARATOR"])
        XCTAssertEqual(english.unicodeScalars.map(\.value), [0x2C, 0x20])
    }

    /// 用每种语言真实的语言表里的串（不用假串）拼出文档里的例句：分隔符、链接、按钮、类型几段凑起来就是共用那张表里的整句。
    func testTheRealResourcesComposeTheExampleSentencesInEveryLanguage() throws {
        let examples: [String: (link: String, group: String, user: String, official: String)] = [
            "en": (
                "Link, Ke Jie Go Course, bilibili.com",
                "Tellomi group, Book Club, 12 members, button: Join Group",
                "Tellomi user, @kaixin, button: Message",
                "Tellomi website, /download, button: Open",
            ),
            "zh_CN": (
                "链接，柯洁围棋入门课，bilibili.com",
                "Tellomi 群组，读书会，12 位成员，按钮：加入群聊",
                "Tellomi 用户，@kaixin，按钮：发消息",
                "Tellomi 官网，/download，按钮：打开",
            ),
            "zh_HK": (
                "連結，柯潔圍棋入門課，bilibili.com",
                "Tellomi 群組，讀書會，12 個成員，按鈕：加入群組",
                "Tellomi 用戶，@kaixin，按鈕：傳送訊息",
                "Tellomi 官網，/download，按鈕：開啟",
            ),
            "zh_TW": (
                "連結，柯潔圍棋入門課，bilibili.com",
                "Tellomi 群組，讀書會，12 個成員，按鈕：加入群組",
                "Tellomi 用戶，@kaixin，按鈕：傳送訊息",
                "Tellomi 官網，/download，按鈕：開啟",
            ),
        ]
        let titles: [String: (link: String, group: String, members: String, join: String, message: String, open: String)] = [
            "en": ("Ke Jie Go Course", "Book Club", "12 members", "Join Group", "Message", "Open"),
            "zh_CN": ("柯洁围棋入门课", "读书会", "12 位成员", "加入群聊", "发消息", "打开"),
            "zh_HK": ("柯潔圍棋入門課", "讀書會", "12 個成員", "加入群組", "傳送訊息", "開啟"),
            "zh_TW": ("柯潔圍棋入門課", "讀書會", "12 個成員", "加入群組", "傳送訊息", "開啟"),
        ]
        for localization in ["en", "zh_CN", "zh_HK", "zh_TW"] {
            let table = try table(localization)
            func string(_ key: String) throws -> String { try XCTUnwrap(table[key], "\(localization) \(key)") }
            let format = try string("TELLOMI_LINK_CARD_A11Y_BUTTON_FORMAT")
            let strings = TellomiLinkCardAccessibility.Strings(
                separator: try string("TELLOMI_LINK_CARD_A11Y_SEPARATOR"),
                link: try string("TELLOMI_LINK_CARD_A11Y_LINK"),
                button: { String(format: format, $0) },
                kindGroup: try string("TELLOMI_LINK_CARD_A11Y_TELLOMI_GROUP"),
                kindStickerPack: try string("TELLOMI_LINK_CARD_A11Y_TELLOMI_STICKER_PACK"),
                kindUser: try string("TELLOMI_LINK_CARD_TELLOMI_USER"),
                kindCall: try string("TELLOMI_LINK_CARD_CALL_TITLE"),
                kindOfficial: try string("TELLOMI_LINK_CARD_OFFICIAL_TITLE"),
            )
            let text = try XCTUnwrap(titles[localization])
            let expected = try XCTUnwrap(examples[localization])
            func firstParty(_ kind: TellomiFirstPartyCard.Kind, _ title: String, _ subtitle: String?, _ action: String) -> String {
                TellomiLinkCardAccessibility.description(
                    firstParty: TellomiFirstPartyCard.Display(kind: kind, title: title, subtitle: subtitle, action: action, officialBadge: false),
                    strings: strings,
                )
            }
            XCTAssertEqual(TellomiLinkCardAccessibility.description(title: text.link, domain: "bilibili.com", strings: strings), expected.link, localization)
            XCTAssertEqual(firstParty(.group, text.group, text.members, text.join), expected.group, localization)
            XCTAssertEqual(firstParty(.user, "@kaixin", try string("TELLOMI_LINK_CARD_TELLOMI_USER"), text.message), expected.user, localization)
            XCTAssertEqual(firstParty(.official, try string("TELLOMI_LINK_CARD_OFFICIAL_TITLE"), "/download", text.open), expected.official, localization)
        }
    }

    func testTheButtonFormatTakesExactlyTheTextOfTheButton() throws {
        for localization in ["en", "zh_CN", "zh_HK", "zh_TW"] {
            let format = try XCTUnwrap(try table(localization)["TELLOMI_LINK_CARD_A11Y_BUTTON_FORMAT"])
            XCTAssertEqual(format.components(separatedBy: "%@").count, 2, "\(localization)：恰好一个 %@")
            XCTAssertEqual(String(format: format, "X").contains("X"), true, localization)
        }
    }

    /// 界面上已有的同义词和读屏词用同一个字：链接 / 連結（「已复制链接」）、贴纸包 / 貼圖包、群组 / 群組。
    func testTheWordsAgreeWithTheOnesAlreadyOnTheCards() throws {
        for localization in ["zh_CN", "zh_HK", "zh_TW"] {
            let table = try table(localization)
            let link = try XCTUnwrap(Self.expected["TELLOMI_LINK_CARD_A11Y_LINK"]?[localization])
            XCTAssertTrue(try XCTUnwrap(table["TELLOMI_LINKS_LINK_COPIED"]).contains(link), "\(localization)：「已复制链接」里的「\(link)」")
            let pack = localization == "zh_CN" ? "贴纸包" : "貼圖包"
            XCTAssertTrue(try XCTUnwrap(Self.expected["TELLOMI_LINK_CARD_A11Y_TELLOMI_STICKER_PACK"]?[localization]).contains(pack), localization)
            let group = localization == "zh_CN" ? "群组" : "群組"
            XCTAssertTrue(try XCTUnwrap(Self.expected["TELLOMI_LINK_CARD_A11Y_TELLOMI_GROUP"]?[localization]).contains(group), localization)
        }
    }
}
