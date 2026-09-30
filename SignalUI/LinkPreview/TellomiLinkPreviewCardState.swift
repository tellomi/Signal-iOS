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

    /// 消息除了这条链接什么都没有（card-visual §3.5）：气泡只画卡片，不画链接文字；完整链接在长按菜单里能复制。
    public let isCardOnly: Bool

    /// 数据层按 rust/links 定的版式，以及从卡片自己的图取的颜色（card-visual §3.2 / §3.3）；没有决定时是 `.none`，照 Signal 原样。
    public let visual: TellomiLinkVisual.Visual

    /// Tellomi 自己对象的卡片（用户 / 群 / 贴纸包 / 官网，card-visual §5.2）：头像或封面 + 标题 + 副行 + 底部一个动作按钮。不是就是 nil。
    public let firstParty: TellomiFirstPartyCard.Display?

    public init(
        base: LinkPreviewState,
        display: TellomiLinkDisplay,
        showsImage: Bool,
        isCardOnly: Bool = false,
        visual: TellomiLinkVisual.Visual = .none,
        firstParty: TellomiFirstPartyCard.Display? = nil,
    ) {
        self.base = base
        self.display = display
        self.showsImage = showsImage
        self.isCardOnly = isCardOnly
        self.visual = visual
        self.firstParty = firstParty
    }

    /// 版式；图片没有显示（品牌壳、用户卡……）或没有决定时是 nil。
    public var layout: TellomiLinkVisual.Layout? { visual.layout }

    /// 染色卡的底色和字色（浅 / 深两套，跟着系统外观走）；不染色是 nil。
    public var tintColors: (background: UIColor, text: UIColor)? {
        guard
            let tint = visual.tint,
            tint.tinted,
            let light = tint.light,
            let dark = tint.dark
        else {
            return nil
        }
        func color(_ rgb: TellomiLinkVisual.RGB) -> UIColor {
            UIColor(red: CGFloat(rgb.red) / 255, green: CGFloat(rgb.green) / 255, blue: CGFloat(rgb.blue) / 255, alpha: 1)
        }
        func dynamic(light: TellomiLinkVisual.RGB, dark: TellomiLinkVisual.RGB) -> UIColor {
            UIColor { $0.userInterfaceStyle == .dark ? color(dark) : color(light) }
        }
        return (
            background: dynamic(light: light.background, dark: dark.background),
            text: dynamic(light: light.text, dark: dark.text),
        )
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
