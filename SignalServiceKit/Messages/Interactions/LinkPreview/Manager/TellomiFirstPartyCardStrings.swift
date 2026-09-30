//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

extension TellomiFirstPartyCard.Strings {
    /// 界面语言的文案（card-visual §3.9 / §3.10 / §5.2）；与 Android `TellomiFirstPartyCard.Strings.from`、Desktop 同一张表。
    public static func localized() -> TellomiFirstPartyCard.Strings {
        return localized(locale: .current)
    }

    /// `locale`：数字（千分位）按哪个地区的习惯排。产品里取当前的，测试里逐个语言传进来。
    static func localized(locale: Locale) -> TellomiFirstPartyCard.Strings {
        return TellomiFirstPartyCard.Strings(
            officialTitle: OWSLocalizedString(
                "TELLOMI_LINK_CARD_OFFICIAL_TITLE",
                comment: "Tellomi (ADR-0063 §4.8): fixed title of the card of a link to Tellomi's official website",
            ),
            tellomiUser: OWSLocalizedString(
                "TELLOMI_LINK_CARD_TELLOMI_USER",
                comment: "Tellomi (ADR-0063 §4.8): title of the card of a link to a Tellomi user, and the line under a name",
            ),
            callTitle: OWSLocalizedString(
                "TELLOMI_LINK_CARD_CALL_TITLE",
                comment: "Tellomi (card-visual §5.2): title of a call card that has no room name",
            ),
            actionMessage: OWSLocalizedString(
                "TELLOMI_LINK_CARD_ACTION_MESSAGE",
                comment: "Tellomi (card-visual §3.10): button at the bottom of a user card",
            ),
            actionJoinGroup: OWSLocalizedString(
                "TELLOMI_LINK_CARD_ACTION_JOIN_GROUP",
                comment: "Tellomi (card-visual §3.10): button at the bottom of a group invite card",
            ),
            actionOpen: OWSLocalizedString(
                "TELLOMI_LINK_CARD_ACTION_OPEN",
                comment: "Tellomi (card-visual §3.10): button at the bottom of a card that opens something (a group you are in, the official website)",
            ),
            actionJoinCall: OWSLocalizedString(
                "TELLOMI_LINK_CARD_ACTION_JOIN_CALL",
                comment: "Tellomi (card-visual §3.10): button at the bottom of a call card",
            ),
            actionAddStickers: OWSLocalizedString(
                "TELLOMI_LINK_CARD_ACTION_ADD_STICKERS",
                comment: "Tellomi (card-visual §3.10): button at the bottom of a sticker pack card that is not installed yet",
            ),
            actionViewStickers: OWSLocalizedString(
                "TELLOMI_LINK_CARD_ACTION_VIEW_STICKERS",
                comment: "Tellomi (card-visual §3.10): button at the bottom of a sticker pack card that is already installed",
            ),
            groupJoined: OWSLocalizedString(
                "TELLOMI_LINK_CARD_GROUP_JOINED",
                comment: "Tellomi (card-visual §5.2): line under the name of a group invite card when you are already a member",
            ),
            stickersAdded: OWSLocalizedString(
                "TELLOMI_LINK_CARD_STICKERS_ADDED",
                comment: "Tellomi (card-visual §5.2): line under the name of a sticker pack card when the pack is already installed",
            ),
            memberCount: { count in
                // 复数文案走 PluralAware.stringsdict（各语言自己的复数规则；数字按 `locale` 加千分位，不缩写）。
                String(
                    format: OWSLocalizedString(
                        "TELLOMI_LINK_CARD_MEMBER_COUNT_%ld",
                        tableName: "PluralAware",
                        comment: "Tellomi (card-visual §3.9): number of members on a group card; the number has thousands separators and is never abbreviated",
                    ),
                    locale: locale,
                    count,
                )
            },
            stickerCount: { count in
                String(
                    format: OWSLocalizedString(
                        "TELLOMI_LINK_CARD_STICKER_COUNT_%ld",
                        tableName: "PluralAware",
                        comment: "Tellomi (card-visual §3.9): number of stickers on a sticker pack card; the number has thousands separators and is never abbreviated",
                    ),
                    locale: locale,
                    count,
                )
            },
        )
    }

    /// 「官方」小徽标的文字（只有官网卡带，card-visual §5.2）。
    public static func officialBadge() -> String {
        OWSLocalizedString(
            "TELLOMI_LINK_CARD_OFFICIAL_BADGE",
            comment: "Tellomi (card-visual §5.2): small badge next to the title of the card of Tellomi’s official website",
        )
    }
}
