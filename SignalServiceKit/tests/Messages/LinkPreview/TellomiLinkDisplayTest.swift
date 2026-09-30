//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import XCTest
@testable import SignalServiceKit

/// ADR-0063 §5.1 / §4.8（tellomi/tellomi#1423）：每个级别在气泡里显示什么，照定稿的卡片规格
/// （card-visual §3.7 / §3.9 / §3.10，2026-09-29）：标题、一行副行、域名行；发送端的描述从不显示。
/// 与 Android `TellomiLinkDisplayTest`、Desktop `linkPreviewDisplay_test` 同一批用例。
final class TellomiLinkDisplayTest: XCTestCase {

    private let en = Locale(identifier: "en_US")

    private lazy var strings = TellomiLinkDisplay.Strings(
        officialTitle: "Tellomi website",
        tellomiUser: "Tellomi user",
        place: "Location",
        kindName: { ["product": "Product", "web": "Web page", "video": "Video"][$0] },
        trackCount: { "\($0) tracks" },
        date: { "D\(Int($0.timeIntervalSince1970))" },
    )

    private let base = TellomiLinkCard(level: .generic, domain: "bilibili.com")

    private func make(_ card: TellomiLinkCard?, title: String? = "Sender title", locale: Locale? = nil) -> TellomiLinkDisplay? {
        TellomiLinkDisplay.make(snapshotTitle: title, card: card, locale: locale ?? en, strings: strings)
    }

    private func structured(_ kind: String, _ attrs: [(String, String)] = [], title: String? = "Title") -> TellomiLinkCard {
        var card = base
        card.level = .structured
        card.kind = kind
        card.title = title
        card.attrs = attrs.map { TellomiLinkCard.Attr(key: $0.0, value: $0.1) }
        return card
    }

    private func line(_ card: TellomiLinkCard) -> String? { make(card)?.description }

    func testNoDecisionKeepsSignalsDisplay() {
        XCTAssertNil(make(nil))
    }

    func testGenericShowsSnapshotTitleAndRegistrableDomainNeverTheDescription() {
        XCTAssertEqual(make(base), TellomiLinkDisplay(title: "Sender title", description: nil, domain: "bilibili.com", officialBadge: false))

        var untitled = base
        untitled.domain = "example.com"
        XCTAssertEqual(make(untitled, title: ""), TellomiLinkDisplay(title: nil, description: nil, domain: "example.com", officialBadge: false))
        XCTAssertEqual(make(untitled, title: nil)?.title, nil)
    }

    func testBrandShellShowsPlatformNameAndWhatTheLinkIs() {
        var card = base
        card.level = .brand
        card.provider = "taobao"
        card.providerName = TellomiLinkCard.LocalizedName(zhHans: "淘宝", zhHant: "淘寶", en: "Taobao")
        card.kind = "product"
        card.domain = "taobao.com"
        card.showImage = false

        XCTAssertEqual(make(card), TellomiLinkDisplay(title: "Taobao", description: "Product", domain: "taobao.com", officialBadge: false))
        XCTAssertEqual(make(card, locale: Locale(identifier: "zh_Hans_CN"))?.title, "淘宝")
        XCTAssertEqual(make(card, locale: Locale(identifier: "zh_Hant_TW"))?.title, "淘寶")
        XCTAssertEqual(make(card, locale: Locale(identifier: "zh_HK"))?.title, "淘寶")
        XCTAssertEqual(make(card, locale: Locale(identifier: "ja_JP"))?.title, "Taobao")

        var web = card
        web.kind = "web"
        XCTAssertEqual(line(web), "Web page")
        var noKind = card
        noKind.kind = nil
        XCTAssertNil(line(noKind))
        var unnamed = card
        unnamed.kind = "podcast"
        XCTAssertNil(line(unnamed), "no English kind id when the table has no name for it")
    }

    func testTraditionalChineseFallsBackToSimplifiedWhenTheRegistryHasNoTraditionalName() {
        let name = TellomiLinkCard.LocalizedName(zhHans: "淘宝", en: "Taobao")
        XCTAssertEqual(name.forLocale(Locale(identifier: "zh_Hant_TW")), "淘宝")
    }

    func testVideoShowsAuthorAndDurationAndThePublishDateAfterTheDomain() throws {
        let publishedAt = "2026-09-01T08:00:00+08:00"
        let card = structured(
            "video",
            [("duration_ms", "3723000"), ("author", "柯洁"), ("published_at", publishedAt)],
            title: "《柯洁围棋入门课》",
        )
        let seconds = Int(ISO8601DateFormatter().date(from: publishedAt)!.timeIntervalSince1970)

        // card-visual §3.7 / §3.4：域名行里域名与发布日期之间是 U+22C5「⋅」，副行各段之间是 U+00B7「·」，两个字符不通用。
        XCTAssertEqual(
            make(card),
            TellomiLinkDisplay(title: "《柯洁围棋入门课》", description: "柯洁 \u{00B7} 1:02:03", domain: "bilibili.com \u{22C5} D\(seconds)", officialBadge: false),
        )
        XCTAssertEqual(make(structured("video", [("published_at", "not a date")]))?.domain, "bilibili.com")
    }

    /// 副行用「 · 」（U+00B7），域名行用「 ⋅ 」（U+22C5）：肉眼几乎一样，所以逐个码点钉住，谁也不许换成谁。
    func testTheSubLineAndTheDomainLineUseDifferentSeparators() throws {
        let card = structured("video", [("duration_ms", "65000"), ("author", "Up"), ("published_at", "2026-09-01T08:00:00+08:00")])
        let display = try XCTUnwrap(make(card))
        let subLine = try XCTUnwrap(display.description)
        let domainLine = try XCTUnwrap(display.domain)
        XCTAssertTrue(subLine.unicodeScalars.contains("\u{00B7}"), "副行的分隔符是 U+00B7：\(subLine.unicodeScalars.map(\.value))")
        XCTAssertFalse(subLine.unicodeScalars.contains("\u{22C5}"), "副行里不该有 U+22C5")
        XCTAssertTrue(domainLine.unicodeScalars.contains("\u{22C5}"), "域名行的分隔符是 U+22C5：\(domainLine.unicodeScalars.map(\.value))")
        XCTAssertFalse(domainLine.unicodeScalars.contains("\u{00B7}"), "域名行里不该有 U+00B7")
    }

    func testEachStructuredKindHasItsOwnSubLine() {
        XCTAssertEqual(line(structured("channel", [("author", "Up")])), "Up")
        XCTAssertEqual(line(structured("music.track", [("album", "Album"), ("duration_ms", "225000"), ("artist", "Artist")])), "Artist · Album · 3:45")
        XCTAssertEqual(line(structured("music.album", [("track_count", "12"), ("artist", "Artist")])), "Artist · 12 tracks")
        XCTAssertEqual(line(structured("music.playlist", [("author", "Curator"), ("track_count", "30")])), "Curator · 30 tracks")
        XCTAssertEqual(line(structured("app", [("platform", "ios"), ("developer", "Developer")])), "Developer · iOS")
        XCTAssertEqual(line(structured("app", [("platform", "android")])), "Android")
        XCTAssertEqual(line(structured("repo", [("owner", "tellomi")])), "tellomi")
        XCTAssertNil(line(structured("video", [("published_at", "2026-09-01T00:00:00Z")])), "a video's date is on the domain line, not the sub line")
    }

    func testSubLineSkipsMissingAndInvalidValues() {
        XCTAssertEqual(line(structured("video", [("duration_ms", "65000")])), "1:05")
        XCTAssertNil(line(structured("video", [("duration_ms", "0")])))
        XCTAssertNil(line(structured("music.album", [("track_count", "0")])))
        XCTAssertNil(line(structured("music.album", [("track_count", "many")])))
        XCTAssertNil(line(structured("repo", [("author", "Someone")])), "attrs of other kinds are not shown")
    }

    func testPlaceIsTitledByItsNameAndNeverShowsCoordinates() {
        let place = structured("place", [("lat", "31.2"), ("lng", "121.4"), ("coord_sys", "gcj02")], title: nil)
        XCTAssertEqual(make(place, title: ""), TellomiLinkDisplay(title: "Location", description: nil, domain: "bilibili.com", officialBadge: false))
        XCTAssertEqual(make(place)?.title, "Sender title")

        let named = structured("place", [("name", "外滩"), ("address", "上海市黄浦区中山东一路")], title: "Title")
        XCTAssertEqual(make(named), TellomiLinkDisplay(title: "外滩", description: "上海市黄浦区中山东一路", domain: "bilibili.com", officialBadge: false))
    }

    func testStructuredKindThisBuildDoesNotKnowShowsLikeGeneric() {
        let card = structured("podcast", [("author", "Host")], title: "Episode 1")
        XCTAssertEqual(make(card), TellomiLinkDisplay(title: "Episode 1", description: nil, domain: "bilibili.com", officialBadge: false))
    }

    func testOfficialSiteCardShowsFixedTextThePathAndTheBadge() {
        var card = base
        card.level = .firstParty
        card.kind = "tellomi.official"
        card.domain = "tellomi.app"
        card.officialBadge = true
        card.firstParty = TellomiLinkCard.FirstParty(type: "official", path: "/download")
        card.showImage = false

        XCTAssertEqual(
            make(card, title: "Account locked, reply with your code"),
            TellomiLinkDisplay(title: "Tellomi website", description: "/download", domain: "tellomi.app", officialBadge: true),
        )
    }

    func testUserCardIsNamedFromTheURLNeverBySender() {
        func user(_ display: String?) -> TellomiLinkCard {
            var card = base
            card.level = .firstParty
            card.kind = "tellomi.user"
            card.domain = "tell.cc"
            card.firstParty = TellomiLinkCard.FirstParty(type: "user", display: display, username: display == nil ? nil : "kefu.57")
            card.showImage = false
            return card
        }
        XCTAssertEqual(make(user("@kefu.57"), title: "@kefu"), TellomiLinkDisplay(title: "@kefu.57", description: "Tellomi user", domain: "tell.cc", officialBadge: false))
        XCTAssertEqual(make(user(nil), title: "@kefu"), TellomiLinkDisplay(title: "Tellomi user", description: nil, domain: "tell.cc", officialBadge: false))
    }

    func testPlainLinkCardShowsTheDomainOnceAsTheTitleWithTheLinkIcon() {
        let plain = TellomiLinkCard(level: .plainLink, domain: "163.com", showImage: false)
        XCTAssertEqual(
            make(plain),
            TellomiLinkDisplay(title: "163.com", description: nil, domain: nil, officialBadge: false, isPlainLink: true, isLookalike: false),
        )
        var imitation = plain
        imitation.domain = "bi1ibili.com"
        imitation.lookalike = "bilibili.com"
        XCTAssertEqual(make(imitation)?.isLookalike, true)
    }

    func testGroupCallAndStickerCardsKeepSignalsDisplay() {
        var card = base
        card.level = .firstParty
        card.kind = "tellomi.group"
        card.firstParty = TellomiLinkCard.FirstParty(type: "group", title: "周末爬山群", memberCount: 12)
        XCTAssertNil(make(card))
    }

    func testFormatsDurations() {
        XCTAssertEqual(TellomiLinkDisplay.formatDuration("500"), "0:01")
        XCTAssertEqual(TellomiLinkDisplay.formatDuration("225000"), "3:45")
        XCTAssertEqual(TellomiLinkDisplay.formatDuration("3727000"), "1:02:07")
        XCTAssertNil(TellomiLinkDisplay.formatDuration("0"))
        XCTAssertNil(TellomiLinkDisplay.formatDuration("-5"))
        XCTAssertNil(TellomiLinkDisplay.formatDuration("long"))
        XCTAssertNil(TellomiLinkDisplay.formatDuration(nil))
    }

    /// card-visual §3.9：「四舍五入到秒；0 或非法不显示」。四舍五入以后是 0 秒的（1–499 ms）等于 0，不显示「0:00」。
    func testADurationThatRoundsToZeroSecondsIsNotShown() {
        XCTAssertNil(TellomiLinkDisplay.formatDuration("1"))
        XCTAssertNil(TellomiLinkDisplay.formatDuration("499"))
        XCTAssertEqual(TellomiLinkDisplay.formatDuration("500"), "0:01", "500 ms 进位到 1 秒")
        XCTAssertEqual(TellomiLinkDisplay.formatDuration("1499"), "0:01")
        XCTAssertEqual(TellomiLinkDisplay.formatDuration("1500"), "0:02")
        XCTAssertEqual(TellomiLinkDisplay.formatDuration("59499"), "0:59")
        XCTAssertEqual(TellomiLinkDisplay.formatDuration("59500"), "1:00", "进位到整分钟")
        XCTAssertEqual(TellomiLinkDisplay.formatDuration("3599500"), "1:00:00", "进位到整小时")
        XCTAssertNil(TellomiLinkDisplay.formatDuration("0"))
        XCTAssertNil(TellomiLinkDisplay.formatDuration("-1"))
        XCTAssertNil(TellomiLinkDisplay.formatDuration("-500"))
        XCTAssertNil(TellomiLinkDisplay.formatDuration(""))
        XCTAssertNil(TellomiLinkDisplay.formatDuration("12.5"), "不是整数就是非法")
        XCTAssertNil(TellomiLinkDisplay.formatDuration("1e3"))
        XCTAssertNil(TellomiLinkDisplay.formatDuration(" 500"))
    }

    /// 时长四舍五入成 0 时，视频副行里不画这一段（只有作者就只有作者；什么都没有就不占这一行）。
    func testAVideoWhoseDurationRoundsToZeroShowsNoDurationInTheSubLine() {
        XCTAssertEqual(line(structured("video", [("author", "Up"), ("duration_ms", "499")])), "Up")
        XCTAssertNil(line(structured("video", [("duration_ms", "499")])))
        XCTAssertEqual(line(structured("music.track", [("artist", "Artist"), ("duration_ms", "300")])), "Artist")
    }

    func testPublishDateOmitsTheYearOnlyForThisYear() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = ISO8601DateFormatter().date(from: "2026-09-29T12:00:00Z")!
        let thisYear = ISO8601DateFormatter().date(from: "2026-09-03T12:00:00Z")!
        let lastYear = ISO8601DateFormatter().date(from: "2025-12-01T12:00:00Z")!

        XCTAssertEqual(TellomiLinkDisplay.formatDate(thisYear, locale: en, now: now, calendar: calendar), "Sep 3")
        XCTAssertEqual(TellomiLinkDisplay.formatDate(lastYear, locale: en, now: now, calendar: calendar), "Dec 1, 2025")
    }
}

/// `classify` 的 JSON 长什么样（`rust/links/tests/data/bridge-golden.json` 同一份形状）。
final class TellomiLinkCardTest: XCTestCase {

    func testParsesAClassifyResult() throws {
        let json = """
        {"level":"structured","provider":"bilibili","provider_name":{"zh-Hans":"哔哩哔哩","en":"Bilibili"},\
        "kind":"video","route":"video","title":"《柯洁围棋入门课》","description":null,\
        "attrs":[{"key":"author","value":"柯洁"},{"key":"duration_ms","value":"3723000"}],\
        "domain":"bilibili.com","official_badge":false,"first_party":null,"lookalike":null,\
        "show_image":true,"tintable":true,"payment":false,"reason":"structured"}
        """
        let card = try XCTUnwrap(TellomiLinkCard.parse(json))

        XCTAssertEqual(card.level, .structured)
        XCTAssertEqual(card.providerName, TellomiLinkCard.LocalizedName(zhHans: "哔哩哔哩", en: "Bilibili"))
        XCTAssertEqual(card.attrs, [TellomiLinkCard.Attr(key: "author", value: "柯洁"), TellomiLinkCard.Attr(key: "duration_ms", value: "3723000")])
        XCTAssertEqual(card.domain, "bilibili.com")
        XCTAssertTrue(card.showImage)
        XCTAssertTrue(card.tintable)
    }

    func testParsesAFirstPartyCardWithCounts() throws {
        let json = """
        {"level":"first_party","kind":"tellomi.group","attrs":[],"domain":"tell.cc","official_badge":false,\
        "first_party":{"type":"group","title":"周末爬山群","member_count":12},\
        "show_image":false,"tintable":false,"payment":false}
        """
        let card = try XCTUnwrap(TellomiLinkCard.parse(json))

        XCTAssertEqual(card.firstParty, TellomiLinkCard.FirstParty(type: "group", title: "周末爬山群", memberCount: 12))
        XCTAssertFalse(card.showImage)
    }

    func testMissingOptionalFieldsTakeTheirDefaults() throws {
        let card = try XCTUnwrap(TellomiLinkCard.parse(#"{"level":"plain_link"}"#))
        XCTAssertEqual(card, TellomiLinkCard(level: .plainLink))
        XCTAssertTrue(card.showImage)
    }

    func testALevelThisBuildDoesNotKnowIsNoDecision() {
        XCTAssertNil(TellomiLinkCard.parse(#"{"level":"hologram"}"#))
        XCTAssertNil(TellomiLinkCard.parse("not json"))
        XCTAssertNil(TellomiLinkCard.parse("{}"))
    }
}
