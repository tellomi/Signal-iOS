//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

// MARK: -

// Tellomi（ADR-0063 §4.1 第 2 条、§5.3；tellomi/tellomi#1423）：群邀请卡片的数据只来自本地——发送端写进消息的 snapshot
// （标题 + 随消息的预览图附件）和本地库。上游这里拿的是渲染时向服务端取来的 `GroupInviteLinkPreview` 和头像缓存。
class LinkPreviewGroupLink: LinkPreviewState {
    let linkType: LinkPreviewLinkType
    /// 发送端的 snapshot：图、域名、日期都用它
    private let snapshot: LinkPreviewSent
    private let content: GroupInviteLinkCardContent

    let conversationStyle: ConversationStyle?

    init(
        linkType: LinkPreviewLinkType,
        snapshot: LinkPreviewSent,
        content: GroupInviteLinkCardContent,
        conversationStyle: ConversationStyle,
    ) {
        self.linkType = linkType
        self.snapshot = snapshot
        self.content = content
        self.conversationStyle = conversationStyle
    }

    var isLoaded: Bool { true }

    var urlString: String? { snapshot.urlString }

    var displayDomain: String? { snapshot.displayDomain }

    var title: String? { content.title }

    var imageState: LinkPreviewImageState { snapshot.imageState }

    func imageAsync(thumbnailQuality: AttachmentThumbnailQuality, completion: @escaping (UIImage) -> Void) {
        snapshot.imageAsync(thumbnailQuality: thumbnailQuality, completion: completion)
    }

    func imageCacheKey(thumbnailQuality: AttachmentThumbnailQuality) -> LinkPreviewImageCacheKey? {
        snapshot.imageCacheKey(thumbnailQuality: thumbnailQuality)
    }

    var imagePixelSize: CGSize { snapshot.imagePixelSize }

    /// 「群组」；本机已在群里时加上本地的人数。发送端写的描述不显示（上游这里也从不显示发送端的描述）。
    var previewDescription: String? {
        let groupIndicator = OWSLocalizedString(
            "GROUP_LINK_ACTION_SHEET_VIEW_GROUP_INDICATOR",
            comment: "Indicator for group conversations in the 'group invite link' action sheet.",
        )
        guard let memberCount = content.localMemberCount else {
            return groupIndicator
        }
        return groupIndicator + " | " + GroupViewUtils.formatGroupMembersLabel(memberCount: memberCount, isTerminated: false)
    }

    var date: Date? { snapshot.date }

    var isGroupInviteLink: Bool { true }

    var isCallLink: Bool { false }
}

// MARK: -

/// 群邀请卡上显示什么：纯函数，只看 snapshot 标题和本地库（ADR-0063 §4.8「/g#<invite>」一行、§5.3）。
struct GroupInviteLinkCardContent: Equatable {
    struct LocalGroup: Equatable {
        let title: String?
        let memberCount: Int
    }

    let title: String
    /// 只有本机已在群里时才有（来自本地库，不是发送端）
    let localMemberCount: Int?

    /// 本机在群里 → 本地群名 + 人数；否则 → 发送端 snapshot 的标题；两者都没有 → nil（不出卡，纯链接）。
    static func resolve(snapshotTitle: String?, localGroup: LocalGroup?) -> GroupInviteLinkCardContent? {
        if let localGroup {
            let localTitle = localGroup.title?.filterForDisplay.nilIfEmpty
            let title = localTitle ?? snapshotTitle?.filterForDisplay.nilIfEmpty ?? TSGroupThread.defaultGroupName
            return GroupInviteLinkCardContent(title: title, localMemberCount: localGroup.memberCount)
        }
        guard let title = snapshotTitle?.filterForDisplay.nilIfEmpty else {
            return nil
        }
        return GroupInviteLinkCardContent(title: title, localMemberCount: nil)
    }
}
