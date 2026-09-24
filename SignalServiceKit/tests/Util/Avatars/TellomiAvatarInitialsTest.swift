//
// Copyright 2026 Tellomi
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest
@testable import SignalServiceKit

/// Tellomi（tellomi/tellomi#1215）：默认头像上的字。
final class TellomiAvatarInitialsTest: XCTestCase {
    func testChineseNamesTakeTheLastTwoCharacters() {
        XCTAssertEqual(TellomiNames.hanAbbreviation("欧阳娜娜"), "娜娜")
        XCTAssertEqual(TellomiNames.hanAbbreviation("张三"), "张三")
        XCTAssertEqual(TellomiNames.hanAbbreviation("李"), "李")
        XCTAssertEqual(TellomiNames.hanAbbreviation("陈 志明"), "志明")
        // 译名中间的间隔号不算字
        XCTAssertEqual(TellomiNames.hanAbbreviation("马克·卡尔"), "卡尔")
    }

    func testOtherNamesAreLeftToTheSystem() {
        XCTAssertNil(TellomiNames.hanAbbreviation("John Smith"))
        XCTAssertNil(TellomiNames.hanAbbreviation("张 San"))
        XCTAssertNil(TellomiNames.hanAbbreviation("はな"))
        XCTAssertNil(TellomiNames.hanAbbreviation(""))
        XCTAssertNil(TellomiNames.hanAbbreviation("·"))
    }

    func testContactInitialsUseTheChineseRule() {
        // 注册页只有一个框：全名在 givenName 里。上游交给系统缩写，四个字的名字会因为「超过 3 个字符」直接没有字
        var oneField = PersonNameComponents()
        oneField.givenName = "欧阳娜娜"
        XCTAssertEqual(AvatarBuilder.contactInitials(for: oneField), "娜娜")

        // 老资料的名 / 姓分开存：姓在前拼起来再取
        var split = PersonNameComponents()
        split.givenName = "三"
        split.familyName = "张"
        XCTAssertEqual(AvatarBuilder.contactInitials(for: split), "张三")

        var latin = PersonNameComponents()
        latin.givenName = "John"
        latin.familyName = "Smith"
        XCTAssertEqual(AvatarBuilder.contactInitials(for: latin), "JS")
    }
}
