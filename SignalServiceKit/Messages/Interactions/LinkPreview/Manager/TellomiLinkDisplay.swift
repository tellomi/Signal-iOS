//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

public import Foundation

/// 气泡里的链接卡片按 rust/links 定的级别显示什么（ADR-0063 §5.1 阶梯），照定稿的卡片规格
/// （card-visual §3.7 / §3.9 / §3.10，2026-09-29）：标题、一行副行、域名行；发送端写的描述任何级别都不显示。
/// 与 Android `TellomiLinkDisplay.kt`、Desktop `linkPreviewDisplay.std.ts` 同一张表。
///
/// - generic：发送端快照里的标题 + 可注册域名；
/// - brand：平台名和这条链接是什么（kind 的名字），不用发送端写的字、不用图；
/// - structured：校验过的标题和 kind 的副行（attrs、数量、时长）；视频的发布日期接在域名后面；
/// - 用户卡、官网卡：文字全由 URL 算出来，不用发送端的（§4.8、§6.1）；
/// - 群、通话、贴纸卡：等第一方卡版式（§5.2），之前照 Signal 原样显示；
/// - 纯链接：无图卡，域名当标题只写一次（§3.5，只出在「消息就是这条链接」时）。
///
/// 版式、染色、按钮不在这里定。图显不显示看 ``TellomiLinkCard/showImage``，由调用方决定。
public struct TellomiLinkDisplay: Equatable, Sendable {
    public var title: String?
    public var description: String?
    public var domain: String?
    public var officialBadge: Bool
    /// 无图卡（card-visual §3.5 / §3.7）：域名当标题，行尾一个链接图标，没有别的行。
    public var isPlainLink: Bool
    /// 域名冒充知名域名（ADR-0063 §6.1）：用危险色显示。
    public var isLookalike: Bool

    public init(
        title: String?,
        description: String?,
        domain: String?,
        officialBadge: Bool,
        isPlainLink: Bool = false,
        isLookalike: Bool = false,
    ) {
        self.title = title
        self.description = description
        self.domain = domain
        self.officialBadge = officialBadge
        self.isPlainLink = isPlainLink
        self.isLookalike = isLookalike
    }

    /// 要用到资源或时钟的都从这里进来，`make` 才是纯函数。
    public struct Strings {
        public var officialTitle: String
        public var tellomiUser: String
        /// 没有名字的位置卡的标题（card-visual §3.7）。
        public var place: String
        /// kind 的名字，给品牌壳的副行（§3.10）；表里没有名字的 kind 返回 nil。
        public var kindName: (String) -> String?
        /// 「12 首」（§3.9）。
        public var trackCount: (Int) -> String
        /// 发布日期：中等长度、不带时刻，今年的不带年（§3.9）。
        public var date: (Date) -> String

        public init(
            officialTitle: String,
            tellomiUser: String,
            place: String,
            kindName: @escaping (String) -> String?,
            trackCount: @escaping (Int) -> String,
            date: @escaping (Date) -> String,
        ) {
            self.officialTitle = officialTitle
            self.tellomiUser = tellomiUser
            self.place = place
            self.kindName = kindName
            self.trackCount = trackCount
            self.date = date
        }
    }

    /// 副行各段之间：U+00B7「·」（card-visual §3.7）。
    private static let separator = " \u{00B7} "
    /// 域名行里域名与发布日期之间：U+22C5「⋅」（card-visual §3.4 / §3.7；Signal 原来的预览卡也是它）。和副行的分隔符是两个字符，不通用。
    private static let domainDateSeparator = " \u{22C5} "
    private static let platformNames = ["ios": "iOS", "android": "Android"]

    /// nil：不覆盖，照 Signal 的方式显示这条预览。
    public static func make(
        snapshotTitle: String?,
        card: TellomiLinkCard?,
        locale: Locale,
        strings: Strings,
    ) -> TellomiLinkDisplay? {
        guard let card else {
            return nil
        }
        switch card.level {
        case .plainLink:
            // 只有「消息就是这条链接」时才到气泡（TellomiLinkOnly）。
            return TellomiLinkDisplay(
                title: card.domain,
                description: nil,
                domain: nil,
                officialBadge: false,
                isPlainLink: true,
                isLookalike: card.lookalike != nil,
            )
        case .generic:
            return generic(snapshotTitle: snapshotTitle, card: card, title: card.title)
        case .brand:
            return TellomiLinkDisplay(
                title: card.providerName?.forLocale(locale),
                description: card.kind.flatMap(strings.kindName),
                domain: card.domain,
                officialBadge: false,
            )
        case .structured:
            return structured(snapshotTitle: snapshotTitle, card: card, strings: strings)
        case .firstParty:
            switch card.firstParty?.type {
            case "official":
                return TellomiLinkDisplay(
                    title: strings.officialTitle,
                    description: card.firstParty?.path,
                    domain: card.domain,
                    officialBadge: card.officialBadge,
                )
            case "user":
                let display = card.firstParty?.display
                return TellomiLinkDisplay(
                    title: display ?? strings.tellomiUser,
                    description: display != nil ? strings.tellomiUser : nil,
                    domain: card.domain,
                    officialBadge: false,
                )
            default:
                return nil
            }
        }
    }

    private static func generic(snapshotTitle: String?, card: TellomiLinkCard, title: String?) -> TellomiLinkDisplay {
        return TellomiLinkDisplay(
            title: title.nonEmpty ?? snapshotTitle.nonEmpty,
            description: nil,
            domain: card.domain,
            officialBadge: false,
        )
    }

    private static func structured(snapshotTitle: String?, card: TellomiLinkCard, strings: Strings) -> TellomiLinkDisplay {
        var attrs = [String: String]()
        for attr in card.attrs where attrs[attr.key] == nil {
            attrs[attr.key] = attr.value
        }
        func text(_ key: String) -> String? { attrs[key].nonEmpty }
        func count(_ key: String) -> String? {
            guard let value = attrs[key].flatMap({ Int($0) }), value > 0 else { return nil }
            return strings.trackCount(value)
        }
        func line(_ parts: String?...) -> String? {
            let present = parts.compactMap { $0 }
            return present.isEmpty ? nil : present.joined(separator: separator)
        }
        func withLine(_ subLine: String?) -> TellomiLinkDisplay {
            var display = generic(snapshotTitle: snapshotTitle, card: card, title: card.title)
            display.description = subLine
            return display
        }

        switch card.kind {
        case "video":
            let published = text("published_at").flatMap(parseDate)
            var domain = card.domain
            if let cardDomain = card.domain, let published {
                domain = cardDomain + domainDateSeparator + strings.date(published)
            }
            return TellomiLinkDisplay(
                title: card.title.nonEmpty ?? snapshotTitle.nonEmpty,
                description: line(text("author"), formatDuration(attrs["duration_ms"])),
                domain: domain,
                officialBadge: false,
            )
        case "channel":
            return withLine(line(text("author")))
        case "music.track":
            return withLine(line(text("artist"), text("album"), formatDuration(attrs["duration_ms"])))
        case "music.album":
            return withLine(line(text("artist"), count("track_count")))
        case "music.playlist":
            return withLine(line(text("author"), count("track_count")))
        case "app":
            return withLine(line(text("developer"), attrs["platform"].flatMap { platformNames[$0] }))
        case "repo":
            return withLine(line(text("owner")))
        case "place":
            return TellomiLinkDisplay(
                title: text("name") ?? card.title.nonEmpty ?? snapshotTitle.nonEmpty ?? strings.place,
                description: line(text("address")),
                domain: card.domain,
                officialBadge: false,
            )
        default:
            return generic(snapshotTitle: snapshotTitle, card: card, title: card.title)
        }
    }

    /// 四舍五入到秒；不到一小时 `m:ss`，否则 `h:mm:ss`；0、负数、不是数字都不显示（§3.9）。
    /// 四舍五入以后是 0 秒的（1–499 ms）也算 0，不显示「0:00」。
    public static func formatDuration(_ value: String?) -> String? {
        guard let ms = value.flatMap({ Int64($0) }), ms > 0 else {
            return nil
        }
        let totalSeconds = (ms + 500) / 1000
        guard totalSeconds > 0 else {
            return nil
        }
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// RFC 3339；解析不了就是 nil。
    private static func parseDate(_ value: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: value) {
            return date
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value)
    }

    /// 中等长度的日期（设备时区），今年的不带年（§3.9）。
    public static func formatDate(_ date: Date, locale: Locale, now: Date, calendar: Calendar = .current) -> String {
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMd" : "yMMMd")
        return formatter.string(from: date)
    }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}
