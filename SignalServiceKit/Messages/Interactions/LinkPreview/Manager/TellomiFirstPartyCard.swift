//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
public import LibSignalClient

/// card-visual §5.2（tellomi/tellomi#1423）：Tellomi 自己对象的卡片——头像或封面、标题、一行副行、底部一个动作按钮，
/// 学 Telegram 展示自家对象的方式。文字来自 URL 和本机已有的东西；发送端写的只用群名和贴纸包名（预览带着，ADR-0063 §4.8）。
/// 渲染卡片不联网（§5.3）：群解散了、用户注销了，点开以后再说。与 Android `TellomiFirstPartyCard.kt`、Desktop `firstPartyCard.std.ts` 同一套规则。
public enum TellomiFirstPartyCard {

    public enum Kind: Equatable, Sendable {
        case user
        case group
        case call
        case sticker
        case official
    }

    /// 本机已经有的：只读本地库得来（``TellomiFirstPartyLocalLookup``）。
    public struct Local: Equatable, Sendable {
        /// tellomi.user：对方已被接受（或就是自己）时，本机显示的名字。
        public var knownUserName: String?
        /// tellomi.user：同一个人的 ACI——卡片用它从本地库取头像（联系人照片 / 对方的资料头像 / 默认头像），只读本地库，不联网。
        public var knownUserAci: Aci?
        /// tellomi.group：本账号是这个群的正式成员。
        public var isGroupMember: Bool
        /// 是成员时，本地的群名（比发送端写的可信）。
        public var groupName: String?
        /// tellomi.sticker：这个贴纸包已安装。
        public var isStickerPackInstalled: Bool

        public init(
            knownUserName: String? = nil,
            isGroupMember: Bool = false,
            groupName: String? = nil,
            isStickerPackInstalled: Bool = false,
            knownUserAci: Aci? = nil,
        ) {
            self.knownUserName = knownUserName
            self.isGroupMember = isGroupMember
            self.groupName = groupName
            self.isStickerPackInstalled = isStickerPackInstalled
            self.knownUserAci = knownUserAci
        }
    }

    public struct Display: Equatable, Sendable {
        public var kind: Kind
        public var title: String
        public var subtitle: String?
        /// 底部按钮的文字（card-visual §3.10）。
        public var action: String
        public var officialBadge: Bool
        /// 用户卡：本机认识这个人时，头像从本地库按这个 ACI 取（真头像）；不认识是 nil（默认头像）。别的卡一律 nil。
        public var avatarAci: Aci?

        public init(kind: Kind, title: String, subtitle: String?, action: String, officialBadge: Bool, avatarAci: Aci? = nil) {
            self.kind = kind
            self.title = title
            self.subtitle = subtitle
            self.action = action
            self.officialBadge = officialBadge
            self.avatarAci = avatarAci
        }
    }

    /// 要用到资源的都从这里进来，`display` 才是纯函数。
    public struct Strings {
        public var officialTitle: String
        public var tellomiUser: String
        public var callTitle: String
        public var actionMessage: String
        public var actionJoinGroup: String
        public var actionOpen: String
        public var actionJoinCall: String
        public var actionAddStickers: String
        public var actionViewStickers: String
        public var groupJoined: String
        public var stickersAdded: String
        public var memberCount: (Int) -> String
        public var stickerCount: (Int) -> String

        public init(
            officialTitle: String,
            tellomiUser: String,
            callTitle: String,
            actionMessage: String,
            actionJoinGroup: String,
            actionOpen: String,
            actionJoinCall: String,
            actionAddStickers: String,
            actionViewStickers: String,
            groupJoined: String,
            stickersAdded: String,
            memberCount: @escaping (Int) -> String,
            stickerCount: @escaping (Int) -> String,
        ) {
            self.officialTitle = officialTitle
            self.tellomiUser = tellomiUser
            self.callTitle = callTitle
            self.actionMessage = actionMessage
            self.actionJoinGroup = actionJoinGroup
            self.actionOpen = actionOpen
            self.actionJoinCall = actionJoinCall
            self.actionAddStickers = actionAddStickers
            self.actionViewStickers = actionViewStickers
            self.groupJoined = groupJoined
            self.stickersAdded = stickersAdded
            self.memberCount = memberCount
            self.stickerCount = stickerCount
        }
    }

    /// nil：不是第一方卡，或是本版不认识的类型（照 Signal 原样显示）。
    public static func display(card: TellomiLinkCard, local: Local?, strings: Strings) -> Display? {
        guard card.level == .firstParty, let firstParty = card.firstParty else {
            return nil
        }
        switch firstParty.type {
        case "user":
            let name = local?.knownUserName.nonEmpty ?? firstParty.display.nonEmpty
            return Display(
                kind: .user,
                title: name ?? strings.tellomiUser,
                subtitle: name != nil ? strings.tellomiUser : nil,
                action: strings.actionMessage,
                officialBadge: false,
                avatarAci: local?.knownUserAci,
            )
        case "group":
            let isMember = local?.isGroupMember == true
            return Display(
                kind: .group,
                // 是成员时用本地的群名（比发送端写的可信）。
                title: (isMember ? local?.groupName.nonEmpty : nil) ?? firstParty.title ?? "",
                subtitle: isMember ? strings.groupJoined : count(firstParty.memberCount).map(strings.memberCount),
                action: isMember ? strings.actionOpen : strings.actionJoinGroup,
                officialBadge: false,
            )
        case "call":
            return Display(
                kind: .call,
                title: firstParty.title.nonEmpty ?? strings.callTitle,
                subtitle: nil,
                action: strings.actionJoinCall,
                officialBadge: false,
            )
        case "sticker":
            let isInstalled = local?.isStickerPackInstalled == true
            return Display(
                kind: .sticker,
                title: firstParty.title ?? "",
                subtitle: isInstalled ? strings.stickersAdded : count(firstParty.stickerCount).map(strings.stickerCount),
                action: isInstalled ? strings.actionViewStickers : strings.actionAddStickers,
                officialBadge: false,
            )
        case "official":
            return Display(
                kind: .official,
                title: strings.officialTitle,
                subtitle: firstParty.path,
                action: strings.actionOpen,
                officialBadge: card.officialBadge,
            )
        default:
            return nil
        }
    }

    /// 值得显示的数量：大于 0 的整数（card-visual §3.9）。
    private static func count(_ value: Int64?) -> Int? {
        guard let value, value >= 1, value <= Int64(Int.max) else {
            return nil
        }
        return Int(value)
    }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}
