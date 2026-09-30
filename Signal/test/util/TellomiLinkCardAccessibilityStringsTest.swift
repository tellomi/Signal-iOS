//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import SignalServiceKit

/// card-visual §3.6：读屏念的几个新词，简体、香港繁体、台湾繁体、英文各一份，逐字钉住（另两端照同一份抄）。
/// 不看当前语言，直接读 App 里每张语言表；用词和界面上已有的一致（链接 / 連結、貼圖包 / 贴纸包、群组 / 群組）。
final class TellomiLinkCardAccessibilityStringsTest: XCTestCase {

    private static let expected: [String: [String: String]] = [
        "TELLOMI_LINK_CARD_A11Y_LINK": ["en": "Link", "zh_CN": "链接", "zh_HK": "連結", "zh_TW": "連結"],
        "TELLOMI_LINK_CARD_A11Y_BUTTON_FORMAT": ["en": "Button: %@", "zh_CN": "按钮：%@", "zh_HK": "按鈕：%@", "zh_TW": "按鈕：%@"],
        "TELLOMI_LINK_CARD_A11Y_TELLOMI_GROUP": ["en": "Tellomi group", "zh_CN": "Tellomi 群组", "zh_HK": "Tellomi 群組", "zh_TW": "Tellomi 群組"],
        "TELLOMI_LINK_CARD_A11Y_TELLOMI_STICKER_PACK": ["en": "Tellomi sticker pack", "zh_CN": "Tellomi 贴纸包", "zh_HK": "Tellomi 貼圖包", "zh_TW": "Tellomi 貼圖包"],
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
            for (key, values) in Self.expected {
                XCTAssertEqual(table[key], values[localization], "\(localization) \(key)")
            }
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
