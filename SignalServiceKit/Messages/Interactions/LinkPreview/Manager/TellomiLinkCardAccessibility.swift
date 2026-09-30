//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// card-visual §3.6：读屏怎么读一张链接卡片。整条消息是一个无障碍元素，卡片的这一段拼进它的标签，只用卡片上已经有的可见文字，不另造信息：
/// - 第三方卡和纯链接：「链接，标题，副行，域名」；缺哪段跳哪段；
/// - 第一方卡：「类型，名称，副行，官方，按钮：动作」，类型只有群和贴纸包需要点名（用户卡、官网卡的标题 / 副行里本来就写着）。
/// 「只显示卡片」时正文组件被拿掉（card-visual §3.5），没有这一段 VoiceOver 读不到链接的任何内容。
/// 动作按钮的焦点与触发、染色卡的按下态、动态字体换排版是第二波，不在这里。
public enum TellomiLinkCardAccessibility {

    /// 要用到资源的都从这里进来，拼接才是纯函数。
    public struct Strings {
        /// 「链接」：第三方卡读的第一个词。
        public var link: String
        /// 「按钮：%@」：第一方卡底部的动作。
        public var button: (String) -> String
        public var tellomiGroup: String
        public var tellomiStickerPack: String
        /// 官网卡标题后面的「官方」徽标的文字（画在标题里，不是单独的标签）。
        public var officialBadge: String

        public init(
            link: String,
            button: @escaping (String) -> String,
            tellomiGroup: String,
            tellomiStickerPack: String,
            officialBadge: String,
        ) {
            self.link = link
            self.button = button
            self.tellomiGroup = tellomiGroup
            self.tellomiStickerPack = tellomiStickerPack
            self.officialBadge = officialBadge
        }
    }

    /// 各段之间的连接：和消息的无障碍标签里其它组件之间一样。
    private static let separator = ", "

    /// 第三方卡、纯链接、Signal 原来的预览卡：「链接，标题，副行，域名」。全都没有就是空串。
    public static func description(title: String?, subtitle: String?, domain: String?, strings: Strings) -> String {
        let parts = [title, subtitle, domain].compactMap { $0?.strippedOrNil }
        guard !parts.isEmpty else {
            return ""
        }
        return ([strings.link] + parts).joined(separator: separator)
    }

    /// 第一方卡：「类型，名称，副行，官方，按钮：动作」。
    public static func description(firstParty card: TellomiFirstPartyCard.Display, strings: Strings) -> String {
        var parts = [String]()
        switch card.kind {
        case .group:
            parts.append(strings.tellomiGroup)
        case .sticker:
            parts.append(strings.tellomiStickerPack)
        case .user, .call, .official:
            break
        }
        if let title = card.title.strippedOrNil {
            parts.append(title)
        }
        if card.officialBadge {
            parts.append(strings.officialBadge)
        }
        if let subtitle = card.subtitle?.strippedOrNil {
            parts.append(subtitle)
        }
        if let action = card.action.strippedOrNil {
            parts.append(strings.button(action))
        }
        return parts.joined(separator: separator)
    }
}

extension TellomiLinkCardAccessibility.Strings {
    /// 界面语言的文案（card-visual §3.6）；「官方」取卡片上画的那个字。
    public static func localized() -> TellomiLinkCardAccessibility.Strings {
        return TellomiLinkCardAccessibility.Strings(
            link: OWSLocalizedString(
                "TELLOMI_LINK_CARD_A11Y_LINK",
                comment: "Tellomi (card-visual §3.6): first word a screen reader says for a link card, before its title and domain",
            ),
            button: { action in
                String(
                    format: OWSLocalizedString(
                        "TELLOMI_LINK_CARD_A11Y_BUTTON_FORMAT",
                        comment: "Tellomi (card-visual §3.6): what a screen reader says for the action button at the bottom of a Tellomi card; %@ is the button's text",
                    ),
                    action,
                )
            },
            tellomiGroup: OWSLocalizedString(
                "TELLOMI_LINK_CARD_A11Y_TELLOMI_GROUP",
                comment: "Tellomi (card-visual §3.6): first words a screen reader says for a Tellomi group invite card, before the group name",
            ),
            tellomiStickerPack: OWSLocalizedString(
                "TELLOMI_LINK_CARD_A11Y_TELLOMI_STICKER_PACK",
                comment: "Tellomi (card-visual §3.6): first words a screen reader says for a Tellomi sticker pack card, before the pack name",
            ),
            officialBadge: TellomiFirstPartyCard.Strings.officialBadge(),
        )
    }
}
