//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

public import Foundation

extension TellomiLinkDisplay.Strings {
    /// 界面语言的文案（card-visual §3.7 / §3.9 / §3.10）；与 Android `TellomiLinkDisplay.Strings.from`、Desktop 同一张表。
    public static func localized() -> TellomiLinkDisplay.Strings {
        return TellomiLinkDisplay.Strings(
            officialTitle: OWSLocalizedString(
                "TELLOMI_LINK_CARD_OFFICIAL_TITLE",
                comment: "Tellomi (ADR-0063 §4.8): fixed title of the card of a link to Tellomi's official website",
            ),
            tellomiUser: OWSLocalizedString(
                "TELLOMI_LINK_CARD_TELLOMI_USER",
                comment: "Tellomi (ADR-0063 §4.8): title of the card of a link to a Tellomi user, and the line under a name",
            ),
            place: OWSLocalizedString(
                "TELLOMI_LINK_CARD_PLACE",
                comment: "Tellomi (card-visual §3.7): title of a place link card that has no name",
            ),
            kindName: { kind in
                switch kind {
                case "video":
                    return OWSLocalizedString(
                        "TELLOMI_LINK_CARD_KIND_VIDEO",
                        comment: "Tellomi (card-visual §3.10): what a brand card's link is: video",
                    )
                case "channel":
                    return OWSLocalizedString(
                        "TELLOMI_LINK_CARD_KIND_CHANNEL",
                        comment: "Tellomi (card-visual §3.10): what a brand card's link is: channel",
                    )
                case "music.track":
                    return OWSLocalizedString(
                        "TELLOMI_LINK_CARD_KIND_MUSIC_TRACK",
                        comment: "Tellomi (card-visual §3.10): what a brand card's link is: music track",
                    )
                case "music.album":
                    return OWSLocalizedString(
                        "TELLOMI_LINK_CARD_KIND_MUSIC_ALBUM",
                        comment: "Tellomi (card-visual §3.10): what a brand card's link is: music album",
                    )
                case "music.playlist":
                    return OWSLocalizedString(
                        "TELLOMI_LINK_CARD_KIND_MUSIC_PLAYLIST",
                        comment: "Tellomi (card-visual §3.10): what a brand card's link is: music playlist",
                    )
                case "place":
                    return OWSLocalizedString(
                        "TELLOMI_LINK_CARD_KIND_PLACE",
                        comment: "Tellomi (card-visual §3.10): what a brand card's link is: place",
                    )
                case "app":
                    return OWSLocalizedString(
                        "TELLOMI_LINK_CARD_KIND_APP",
                        comment: "Tellomi (card-visual §3.10): what a brand card's link is: app",
                    )
                case "repo":
                    return OWSLocalizedString(
                        "TELLOMI_LINK_CARD_KIND_REPO",
                        comment: "Tellomi (card-visual §3.10): what a brand card's link is: repo",
                    )
                case "article":
                    return OWSLocalizedString(
                        "TELLOMI_LINK_CARD_KIND_ARTICLE",
                        comment: "Tellomi (card-visual §3.10): what a brand card's link is: article",
                    )
                case "product":
                    return OWSLocalizedString(
                        "TELLOMI_LINK_CARD_KIND_PRODUCT",
                        comment: "Tellomi (card-visual §3.10): what a brand card's link is: product",
                    )
                case "package":
                    return OWSLocalizedString(
                        "TELLOMI_LINK_CARD_KIND_PACKAGE",
                        comment: "Tellomi (card-visual §3.10): what a brand card's link is: package",
                    )
                case "question":
                    return OWSLocalizedString(
                        "TELLOMI_LINK_CARD_KIND_QUESTION",
                        comment: "Tellomi (card-visual §3.10): what a brand card's link is: question",
                    )
                case "deal":
                    return OWSLocalizedString(
                        "TELLOMI_LINK_CARD_KIND_DEAL",
                        comment: "Tellomi (card-visual §3.10): what a brand card's link is: deal",
                    )
                case "ride":
                    return OWSLocalizedString(
                        "TELLOMI_LINK_CARD_KIND_RIDE",
                        comment: "Tellomi (card-visual §3.10): what a brand card's link is: ride",
                    )
                case "payment":
                    return OWSLocalizedString(
                        "TELLOMI_LINK_CARD_KIND_PAYMENT",
                        comment: "Tellomi (card-visual §3.10): what a brand card's link is: payment",
                    )
                case "web":
                    return OWSLocalizedString(
                        "TELLOMI_LINK_CARD_KIND_WEB",
                        comment: "Tellomi (card-visual §3.10): what a brand card's link is: web",
                    )
                default:
                    return nil
                }
            },
            trackCount: { count in
                let number = NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
                let format = count == 1
                    ? OWSLocalizedString(
                        "TELLOMI_LINK_CARD_TRACK_COUNT_ONE",
                        comment: "Tellomi (card-visual §3.9): number of tracks on an album or playlist card, singular; %@ is the number",
                    )
                    : OWSLocalizedString(
                        "TELLOMI_LINK_CARD_TRACK_COUNT_OTHER",
                        comment: "Tellomi (card-visual §3.9): number of tracks on an album or playlist card, plural; %@ is the number",
                    )
                return String(format: format, number)
            },
            date: { date in
                TellomiLinkDisplay.formatDate(date, locale: .current, now: Date())
            },
        )
    }
}
