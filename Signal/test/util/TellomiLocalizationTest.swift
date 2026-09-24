//
// Copyright 2026 Tellomi
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import SignalServiceKit

/// Tellomi：当前语言缺键时回落英文，而不是把键名显示在界面上；中文三种语言的表必须覆盖英文的全部键。
final class TellomiLocalizationTest: XCTestCase {

    private var tempDirectory: URL!
    private var germanTable: Bundle!
    private var englishTable: Bundle!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        germanTable = try makeTable("de", entries: ["BOTH": "beide"])
        englishTable = try makeTable("en", entries: ["BOTH": "both", "ONLY_EN": "english only"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        try super.tearDownWithError()
    }

    /// An `xx.lproj` directory used directly as a bundle: its `Localizable.strings` is the only table it has,
    /// the same way the app's table for the user's language is the only one iOS consults.
    private func makeTable(_ language: String, entries: [String: String]) throws -> Bundle {
        let directory = tempDirectory.appendingPathComponent("\(language).lproj")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let text = entries.map { "\"\($0.key)\" = \"\($0.value)\";" }.joined(separator: "\n")
        try text.write(to: directory.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        return try XCTUnwrap(Bundle(path: directory.path))
    }

    func testPlatformShowsTheKeyWhenTheTableLacksIt() {
        // 这条钉住的是平台行为，也是这次修复的前提：缺键时系统返回键名，不会自己回落英文。
        XCTAssertEqual(germanTable.localizedString(forKey: "BOTH", value: "", table: nil), "beide")
        XCTAssertEqual(germanTable.localizedString(forKey: "ONLY_EN", value: "", table: nil), "ONLY_EN")
    }

    func testFallsBackToEnglishWhenTheCurrentLanguageLacksTheKey() {
        func lookup(_ key: String, value: String = "") -> String {
            TellomiLocalization.localizedString(key, tableName: nil, value: value, bundle: germanTable, englishBundle: englishTable)
        }
        XCTAssertEqual(lookup("BOTH"), "beide")
        XCTAssertEqual(lookup("ONLY_EN"), "english only")
        XCTAssertEqual(lookup("NOWHERE"), "NOWHERE")
        XCTAssertEqual(lookup("NOWHERE", value: "default"), "default")
    }

    func testWithoutAnEnglishTableBehavesLikeUpstream() {
        let result = TellomiLocalization.localizedString("ONLY_EN", tableName: nil, value: "", bundle: germanTable, englishBundle: nil)
        XCTAssertEqual(result, "ONLY_EN")
    }

    func testAppHasAnEnglishTable() throws {
        let english = try XCTUnwrap(TellomiLocalization.englishBundle(in: Bundle.main.app))
        XCTAssertEqual(english.localizedString(forKey: "ONBOARDING_SPLASH_TITLE", value: "", table: nil).isEmpty, false)
        XCTAssertNotEqual(english.localizedString(forKey: "ONBOARDING_SPLASH_TITLE", value: "", table: nil), "ONBOARDING_SPLASH_TITLE")
    }

    /// 用 App 里真实的每一张语言表查英文表的每一个键：哪种语言都不能把键名显示出来。
    /// 基线上 `ABOUT_SECTION_FOOTER_TELLOMI` 就只有中英文，没有回落时 de / ja 等 40 多种语言显示的是键名。
    func testNoLanguageShowsRawKeys() throws {
        let app = Bundle.main.app
        let english = try XCTUnwrap(TellomiLocalization.englishBundle(in: app))
        let englishPath = try XCTUnwrap(english.path(forResource: "Localizable", ofType: "strings"))
        let englishTable = try XCTUnwrap(NSDictionary(contentsOfFile: englishPath) as? [String: String])
        let localizations = app.localizations.filter { $0 != "en" && $0 != "Base" }
        XCTAssertGreaterThan(localizations.count, 10, "\(localizations)")
        for localization in localizations {
            let table = try XCTUnwrap(app.path(forResource: localization, ofType: "lproj").flatMap { Bundle(path: $0) }, localization)
            let raw = englishTable
                .filter { key, englishValue in
                    englishValue != key && TellomiLocalization.localizedString(key, tableName: nil, value: "", bundle: table, englishBundle: english) == key
                }
                .keys
                .sorted()
            XCTAssertEqual(raw, [], "\(localization) shows \(raw.count) raw keys")
        }
    }

    /// 中文三种语言是 Tellomi 的主要用户，每个新键都要有中文，不能靠英文回落。
    func testChineseTablesCoverEveryEnglishKey() throws {
        func keys(_ localization: String) throws -> Set<String> {
            let path = try XCTUnwrap(
                Bundle.main.app.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: localization),
                "no Localizable.strings for \(localization)",
            )
            let table = try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String], "unreadable table for \(localization)")
            return Set(table.keys)
        }
        let english = try keys("en")
        XCTAssertGreaterThan(english.count, 1000, "the English table should be the full app table")
        for localization in ["zh_CN", "zh_HK", "zh_TW"] {
            let missing = english.subtracting(try keys(localization)).sorted()
            XCTAssertEqual(missing, [], "\(localization) lacks \(missing.count) keys")
        }
    }
}
