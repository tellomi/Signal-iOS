//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
public import LibSignalClient

/// card-visual §5.2：Tellomi 卡片说的那个对象，本机已经有什么（认识的用户、已经在的群、已装的贴纸包）——**只读本地库，从不联网**（§5.3）。
/// 在数据层（工作线程）判。与 Android `TellomiFirstPartyLocalLookup.kt`、Desktop `firstPartyLocal.node.ts` 同样的查法。
public enum TellomiFirstPartyLocalLookup {

    /// 这条链接的卡片是第一方卡时本机已有的东西；不是、或什么都没有时 nil。
    public static func local(url: URL, card: TellomiLinkCard, tx: DBReadTransaction) -> TellomiFirstPartyCard.Local? {
        guard card.level == .firstParty, let firstParty = card.firstParty else {
            return nil
        }
        switch firstParty.type {
        case "user":
            return firstParty.username.flatMap { knownUser(username: $0, tx: tx) }
        case "group":
            return group(url: url, tx: tx)
        case "sticker":
            return sticker(url: url, tx: tx)
        default:
            return nil
        }
    }

    /// 用户名按小写比（存的是小写，比较不分大小写）。对方已被接受（在资料白名单里）或就是自己，才算「认识」，和 Desktop、Android 一样。
    static func knownUser(username: String, tx: DBReadTransaction) -> TellomiFirstPartyCard.Local? {
        guard
            let record = UsernameLookupRecordStore().fetchOne(forUsernameCaseInsensitive: username.lowercased(), tx: tx),
            let localAci = DependenciesBridge.shared.tsAccountManager.localIdentifiers(tx: tx)?.aci
        else {
            return nil
        }
        let aci = Aci(fromUUID: record.aci)
        let address = SignalServiceAddress(aci)
        let isSelf = aci == localAci
        guard isSelf || SSKEnvironment.shared.profileManagerRef.isUser(inProfileWhitelist: address, transaction: tx) else {
            return nil
        }
        let name = SSKEnvironment.shared.contactManagerRef.displayName(for: address, tx: tx).resolvedValue()
        return TellomiFirstPartyCard.Local(knownUserName: name, knownUserAci: aci)
    }

    /// 本账号是这个群的正式成员时：本地的群名。
    static func group(url: URL, tx: DBReadTransaction) -> TellomiFirstPartyCard.Local? {
        guard
            let possible = PossibleGroupInviteLinkUrl.parseFrom(url),
            let link = try? GroupInviteLink.parseFrom(possible),
            let localAci = DependenciesBridge.shared.tsAccountManager.localIdentifiers(tx: tx)?.aci
        else {
            return nil
        }
        let groupId = GroupV2ContextInfo.deriveFrom(masterKey: link.masterKey).groupId
        guard
            let groupThread = TSGroupThread.fetchThread(forGroupId: groupId, tx: tx),
            groupThread.groupModel.groupMembership.isFullMember(localAci)
        else {
            return nil
        }
        return TellomiFirstPartyCard.Local(isGroupMember: true, groupName: groupThread.groupModel.groupName)
    }

    /// 这个贴纸包已经装了。tell.cc 的写法先换算成上游认得的形状再解析。
    static func sticker(url: URL, tx: DBReadTransaction) -> TellomiFirstPartyCard.Local? {
        let legacy = TellomiLinks.legacyEquivalent(of: url)
        guard
            StickerPackInfo.isStickerPackShare(legacy),
            let info = StickerPackInfo.parseStickerPackShare(legacy)
        else {
            return nil
        }
        return TellomiFirstPartyCard.Local(isStickerPackInstalled: StickerManager.isStickerPackInstalled(stickerPackInfo: info, transaction: tx))
    }
}
