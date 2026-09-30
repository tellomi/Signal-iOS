//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// card-visual §3.6：读屏怎么读一张链接卡片。拼法和用词三端同一份（`a11y-strings.md`）。整条消息是一个无障碍元素，
/// 卡片的这一段拼进它的标签，只用卡片上已经有的可见文字，不另造信息：
/// - 第三方卡、纯链接、Signal 原来的预览卡：`[链接, 标题, 域名]`，缺哪段跳哪段；**不读副行、不读描述**（文档的公式只有标题和域名）；
/// - 第一方卡：`[类型, 标题, 副标题, 按钮：动作]`：类型是「Tellomi 用户 / 群组 / 通话 / 贴纸包 / 官网」；
///   标题或副标题和类型那一段一模一样时不再拼（用户卡的副标题就是「Tellomi 用户」，官网卡的标题就是「Tellomi 官网」）；官网卡不读「官方」徽标。
/// 段与段之间按本语言的分隔符连（简体 / 繁体「，」，英文「, 」）。
/// 「只显示卡片」时正文组件被拿掉（card-visual §3.5），没有这一段 VoiceOver 读不到链接的任何内容。
/// 第一方卡底部的动作按钮另外是一个独立的无障碍按钮（见 `CVComponentMessage`），这里只管整句。
public enum TellomiLinkCardAccessibility {

    /// 要用到资源的都从这里进来，拼接才是纯函数。
    public struct Strings {
        /// 段与段之间的连接（中文「，」，英文「, 」，带空格）。
        public var separator: String
        /// 「链接」：第三方卡读的第一个词。
        public var link: String
        /// 「按钮：%@」：第一方卡读的最后一段，参数是卡上按钮的字。
        public var button: (String) -> String
        /// 「Tellomi 群组」「Tellomi 贴纸包」：这一版新增的两条。
        public var kindGroup: String
        public var kindStickerPack: String
        /// 用户、通话、官网的第一段**沿用卡片上已有的串**（`TELLOMI_LINK_CARD_TELLOMI_USER` / `…CALL_TITLE` / `…OFFICIAL_TITLE`），不新建同义串。
        public var kindUser: String
        public var kindCall: String
        public var kindOfficial: String

        public init(
            separator: String,
            link: String,
            button: @escaping (String) -> String,
            kindGroup: String,
            kindStickerPack: String,
            kindUser: String,
            kindCall: String,
            kindOfficial: String,
        ) {
            self.separator = separator
            self.link = link
            self.button = button
            self.kindGroup = kindGroup
            self.kindStickerPack = kindStickerPack
            self.kindUser = kindUser
            self.kindCall = kindCall
            self.kindOfficial = kindOfficial
        }
    }

    /// 第三方卡、纯链接、Signal 原来的预览卡：「链接，标题，域名」，缺哪段跳哪段。全都没有就是空串（不是孤零零一个「链接」）。
    /// 纯链接卡没有标题，标题位写的就是域名，读「链接，bilibili.com」。
    public static func description(title: String?, domain: String?, strings: Strings) -> String {
        let parts = [title, domain].compactMap { $0?.strippedOrNil }
        guard !parts.isEmpty else {
            return ""
        }
        return ([strings.link] + parts).joined(separator: strings.separator)
    }

    /// 第一方卡：「类型，标题，副标题，按钮：动作」。和前面已经读过的一模一样的段不重复。
    public static func description(firstParty card: TellomiFirstPartyCard.Display, strings: Strings) -> String {
        let kind: String
        switch card.kind {
        case .user: kind = strings.kindUser
        case .group: kind = strings.kindGroup
        case .call: kind = strings.kindCall
        case .sticker: kind = strings.kindStickerPack
        case .official: kind = strings.kindOfficial
        }
        var parts = [kind]
        for text in [card.title, card.subtitle] {
            if let text = text?.strippedOrNil, !parts.contains(text) {
                parts.append(text)
            }
        }
        if let action = card.action.strippedOrNil {
            parts.append(strings.button(action))
        }
        return parts.joined(separator: strings.separator)
    }
}

extension TellomiLinkCardAccessibility.Strings {
    /// 界面语言的文案（card-visual §3.6）；用户 / 通话 / 官网的类型取卡片上画的那几个字。
    public static func localized() -> TellomiLinkCardAccessibility.Strings {
        let card = TellomiFirstPartyCard.Strings.localized()
        return TellomiLinkCardAccessibility.Strings(
            separator: OWSLocalizedString(
                "TELLOMI_LINK_CARD_A11Y_SEPARATOR",
                comment: "Tellomi (card-visual §3.6): what a screen reader puts between the parts of a link card's description (kind, title, subtitle, button); the English one includes the space after the comma",
            ),
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
            kindGroup: OWSLocalizedString(
                "TELLOMI_LINK_CARD_A11Y_TELLOMI_GROUP",
                comment: "Tellomi (card-visual §3.6): first words a screen reader says for a Tellomi group invite card, before the group name",
            ),
            kindStickerPack: OWSLocalizedString(
                "TELLOMI_LINK_CARD_A11Y_TELLOMI_STICKER_PACK",
                comment: "Tellomi (card-visual §3.6): first words a screen reader says for a Tellomi sticker pack card, before the pack name",
            ),
            kindUser: card.tellomiUser,
            kindCall: card.callTitle,
            kindOfficial: card.officialTitle,
        )
    }
}
