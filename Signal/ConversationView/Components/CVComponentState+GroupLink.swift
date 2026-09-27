//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

// Tellomi（ADR-0063 §4.1 第 2 条、§5.1 铁律 3、§5.3；tellomi/tellomi#1423）：群邀请卡片**只用本地数据**渲染。
//
// 上游在渲染时会向服务端取群信息和头像（缓存里没有就调 `fetchGroupInviteLinkPreview` / `fetchGroupInviteLinkAvatar`），
// 链接失效时整张卡不显示。这违反「接收端渲染卡片不为补全额外请求 Tellomi 服务端」：滚动会话就把「谁收到了哪个群的邀请」
// 告诉服务端，也让卡片跟着网络跳来跳去。现在：
//   - 群名、图来自发送端写进消息的 snapshot（`Preview.title` + 随消息的加密预览图附件，走现有的附件通道）；
//   - 本机已经在这个群里时（用邀请里的 master key 推出群 id 查本地库），群名和人数用本地的；
//   - 链接是否失效渲染时不知道也不去查：点开以后在入群流程里说明（Signal 现有流程），卡片本身不变；
//   - snapshot 没有标题、本地也不认识这个群 → 不出卡（纯链接，§5.3：群名只能来自 snapshot 标题）。
extension CVComponentState {

    static func localGroupInviteLinkPreviewState(
        linkPreview: OWSLinkPreview,
        messageRowId: Int64?,
        groupInviteLink: GroupInviteLink,
        linkType: LinkPreviewLinkType,
        conversationStyle: ConversationStyle,
        transaction: DBReadTransaction,
    ) -> LinkPreviewGroupLink? {
        let localGroup = localGroup(for: groupInviteLink, transaction: transaction)
        guard
            let content = GroupInviteLinkCardContent.resolve(
                snapshotTitle: linkPreview.title,
                localGroup: localGroup,
            )
        else {
            return nil
        }
        let (imageAttachment, isFailedImageAttachmentDownload) = snapshotImageAttachment(messageRowId: messageRowId, transaction: transaction)
        let snapshot = LinkPreviewSent(
            linkPreview: linkPreview,
            imageAttachment: imageAttachment,
            isFailedImageAttachmentDownload: isFailedImageAttachmentDownload,
            conversationStyle: conversationStyle,
        )
        return LinkPreviewGroupLink(
            linkType: linkType,
            snapshot: snapshot,
            content: content,
            conversationStyle: conversationStyle,
        )
    }

    /// 本机已经是这个群的正式成员时，本地的群名和人数。只读本地库。
    private static func localGroup(
        for groupInviteLink: GroupInviteLink,
        transaction: DBReadTransaction,
    ) -> GroupInviteLinkCardContent.LocalGroup? {
        let groupId = GroupV2ContextInfo.deriveFrom(masterKey: groupInviteLink.masterKey).groupId
        guard
            let localAci = DependenciesBridge.shared.tsAccountManager.localIdentifiers(tx: transaction)?.aci,
            let groupThread = TSGroupThread.fetchThread(forGroupId: groupId, tx: transaction),
            groupThread.groupModel.groupMembership.isFullMember(localAci)
        else {
            return nil
        }
        return GroupInviteLinkCardContent.LocalGroup(
            title: groupThread.groupModel.groupName,
            memberCount: groupThread.groupModel.groupMembership.fullMembers.count,
        )
    }

    /// 与 `buildLinkPreview` 里普通链接那一支取预览图附件的做法相同（随消息的加密附件，走现有附件通道）。
    private static func snapshotImageAttachment(
        messageRowId: Int64?,
        transaction: DBReadTransaction,
    ) -> (ReferencedAttachment?, isFailedDownload: Bool) {
        guard
            let rowId = messageRowId,
            let attachment = DependenciesBridge.shared.attachmentStore.fetchAnyReferencedAttachment(
                for: .messageLinkPreview(messageRowId: rowId),
                tx: transaction,
            ),
            MimeTypeUtil.isSupportedImageMimeType(attachment.attachment.mimeType)
        else {
            return (nil, false)
        }
        if let attachmentStream = attachment.asReferencedStream {
            guard attachmentStream.attachmentStream.contentType.isImage else {
                return (nil, false)
            }
            return (attachmentStream, false)
        }
        guard let blurHash = attachment.attachment.blurHash, BlurHash.isValidBlurHash(blurHash) else {
            return (nil, false)
        }
        let isFailedDownload: Bool
        switch attachment.attachment.asAnyPointer()?.downloadState(tx: transaction) ?? .none {
        case .none, .enqueuedOrDownloading:
            isFailedDownload = false
        case .failed:
            isFailedDownload = true
        }
        return (attachment, isFailedDownload)
    }
}
