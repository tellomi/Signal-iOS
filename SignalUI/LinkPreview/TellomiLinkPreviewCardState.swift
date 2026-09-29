//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

public import SignalServiceKit

/// 按 rust/links 定的级别改写一条已收到预览的显示（ADR-0063 §5.1，card-visual §3.7）：标题、副行、域名行都取
/// `TellomiLinkDisplay`（发送端写的描述从不显示），品牌壳、用户卡、官网卡、纯链接不显示发送端的图。
/// 包一层而不是改 `LinkPreviewSent`：群邀请卡、通话卡、抓取前的状态都不受影响。
///
/// 域名行里已经带了发布日期时（视频），`date` 返回 nil，气泡不会再加一遍。
public final class TellomiLinkPreviewCardState: LinkPreviewState {

    private let base: LinkPreviewState
    private let display: TellomiLinkDisplay
    private let showsImage: Bool

    public init(base: LinkPreviewState, display: TellomiLinkDisplay, showsImage: Bool) {
        self.base = base
        self.display = display
        self.showsImage = showsImage
    }

    /// 无图卡（card-visual §3.5 / §3.7）：域名当标题，行尾一个链接图标，没有别的行。
    public var isPlainLink: Bool { display.isPlainLink }

    /// 域名冒充知名域名（ADR-0063 §6.1）：标题用危险色。
    public var isLookalike: Bool { display.isLookalike }

    // MARK: LinkPreviewState

    public var isLoaded: Bool { base.isLoaded }

    public var urlString: String? { base.urlString }

    public var displayDomain: String? { display.domain?.filterForDisplay.nilIfEmpty }

    public var title: String? { display.title?.filterForDisplay.nilIfEmpty }

    public var previewDescription: String? { display.description?.filterForDisplay.nilIfEmpty }

    public var date: Date? { nil }

    public var imageState: LinkPreviewImageState { showsImage ? base.imageState : .none }

    public func imageAsync(thumbnailQuality: AttachmentThumbnailQuality, completion: @escaping (UIImage) -> Void) {
        guard showsImage else {
            owsFailDebug("Should not be called.")
            return
        }
        base.imageAsync(thumbnailQuality: thumbnailQuality, completion: completion)
    }

    public func imageCacheKey(thumbnailQuality: AttachmentThumbnailQuality) -> LinkPreviewImageCacheKey? {
        showsImage ? base.imageCacheKey(thumbnailQuality: thumbnailQuality) : nil
    }

    public var imagePixelSize: CGSize { showsImage ? base.imagePixelSize : .zero }

    public var isGroupInviteLink: Bool { base.isGroupInviteLink }

    public var isCallLink: Bool { base.isCallLink }

    public var conversationStyle: ConversationStyle? { base.conversationStyle }
}
