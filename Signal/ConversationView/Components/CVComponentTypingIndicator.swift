//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
public import SignalUI

public class CVComponentTypingIndicator: CVComponentBase, CVRootComponent {

    public var componentKey: CVComponentKey { .typingIndicator }

    public var cellReuseIdentifier: CVCellReuseIdentifier {
        CVCellReuseIdentifier.typingIndicator
    }

    public let isDedicatedCell = true

    private let typingIndicator: CVComponentState.TypingIndicator

    init(
        itemModel: CVItemModel,
        typingIndicator: CVComponentState.TypingIndicator,
    ) {
        self.typingIndicator = typingIndicator

        super.init(itemModel: itemModel)
    }

    public func configureCellRootComponent(
        cellView: UIView,
        cellMeasurement: CVCellMeasurement,
        componentDelegate: CVComponentDelegate,
        messageSwipeActionState: CVMessageSwipeActionState,
        componentView: CVComponentView,
    ) {
        Self.configureCellRootComponent(
            rootComponent: self,
            cellView: cellView,
            cellMeasurement: cellMeasurement,
            componentDelegate: componentDelegate,
            componentView: componentView,
        )
    }

    override public func wallpaperBlurView(componentView: CVComponentView) -> CVWallpaperBlurView? {
        guard let componentView = componentView as? CVComponentViewTypingIndicator else {
            owsFailDebug("Unexpected componentView.")
            return nil
        }
        return componentView.wallpaperBlurView
    }

    public func buildComponentView(componentDelegate: CVComponentDelegate) -> CVComponentView {
        CVComponentViewTypingIndicator()
    }

    public func configureForRendering(
        componentView: CVComponentView,
        cellMeasurement: CVCellMeasurement,
        componentDelegate: CVComponentDelegate,
    ) {
        guard let componentView = componentView as? CVComponentViewTypingIndicator else {
            owsFailDebug("Unexpected componentView.")
            return
        }

        // TODO: Reuse?

        let outerStackView = componentView.outerStackView
        let innerStackView = componentView.innerStackView

        innerStackView.reset()
        outerStackView.reset()

        var outerViews = [UIView]()

        if let avatarDataSource = typingIndicator.avatarDataSource {
            let avatarView = componentView.avatarView
            avatarView.updateWithSneakyTransactionIfNecessary { config in
                config.dataSource = avatarDataSource
            }
            outerViews.append(avatarView)
        }

        let bubbleView: UIView
        let bubbleConfig = Self.tellomiBubbleConfig(hasWallpaper: conversationStyle.hasWallpaper, isDarkThemeEnabled: isDarkThemeEnabled, isRTL: CurrentAppContext().isRTL)
        if conversationStyle.hasWallpaper {
            let wallpaperBlurView = componentView.ensureWallpaperBlurView()
            configureWallpaperBlurView(
                wallpaperBlurView: wallpaperBlurView,
                componentDelegate: componentDelegate,
                bubbleConfig: bubbleConfig,
            )
            bubbleView = wallpaperBlurView
        } else {
            let chatColorView = componentView.chatColorView
            chatColorView.configure(
                value: conversationStyle.bubbleChatColorIncoming,
                referenceView: componentDelegate.view,
                bubbleConfig: bubbleConfig,
            )
            bubbleView = chatColorView
        }
        // Tellomi（#1205）：气泡视图在尾巴那一侧外扩 `Tail.extent`，尾巴画在这一条里；三个点的位置不变。
        // ManualStackView 先排子视图、再跑布局块，所以这里设的 frame 不会被排版覆盖。
        innerStackView.addSubview(bubbleView)
        let outsets = bubbleConfig.tail?.contentInsets ?? .zero
        innerStackView.addLayoutBlock { view in
            let frame = view.bounds.inset(by: UIEdgeInsets(top: -outsets.top, left: -outsets.left, bottom: -outsets.bottom, right: -outsets.right))
            ManualLayoutView.setSubviewFrame(subview: bubbleView, frame: frame)
        }

        let typingIndicatorView = componentView.typingIndicatorView
        typingIndicatorView.configureForConversationView(cellMeasurement: cellMeasurement)

        outerViews.append(innerStackView)

        // We always use a stretching spacer.
        outerViews.append(UIView.hStretchingSpacer())

        innerStackView.configure(
            config: innerStackViewConfig,
            cellMeasurement: cellMeasurement,
            measurementKey: Self.measurementKey_innerStack,
            subviews: [typingIndicatorView],
        )
        outerStackView.configure(
            config: outerStackViewConfig,
            cellMeasurement: cellMeasurement,
            measurementKey: Self.measurementKey_outerStack,
            subviews: outerViews,
        )
    }

    /// Tellomi（#1205，设计规范 `bubbles-and-motion-design.md` 第 2 节）：「正在输入」气泡和对方的消息一样带尾巴，在对方那侧的下角。
    /// 它总是单独一条，所以总是画。
    static func tellomiBubbleConfig(hasWallpaper: Bool, isDarkThemeEnabled: Bool, isRTL: Bool) -> BubbleConfiguration {
        BubbleConfiguration(
            corners: .capsule(),
            stroke: hasWallpaper ? ConversationStyle.bubbleStroke(isDarkThemeEnabled: isDarkThemeEnabled) : nil,
            tail: BubbleConfiguration.Tail(isOnRight: isRTL),
        )
    }

    /// Tellomi（规范 #1204 第 2 节，owner 2026-09-26）：和对方的消息一样，在尾巴那一侧多留 `Tail.sideMargin`——
    /// 群里加在头像和气泡之间（8 → 14），单聊加在最前面（16 → 22）。间距也落在气泡和后面的弹性空白之间，那段本来就会被拉伸，不影响。
    private var outerStackViewConfig: CVStackViewConfig {
        let tailMargin = BubbleConfiguration.Tail.sideMargin
        let hasAvatar = typingIndicator.avatarDataSource != nil
        return CVStackViewConfig(
            axis: .horizontal,
            alignment: .center,
            spacing: ConversationStyle.messageStackSpacing + (hasAvatar ? tailMargin : 0),
            layoutMargins: UIEdgeInsets(
                top: 0,
                leading: conversationStyle.gutterLeading + (hasAvatar ? 0 : tailMargin),
                bottom: 0,
                trailing: conversationStyle.gutterTrailing,
            ),
        )
    }

    private var innerStackViewConfig: CVStackViewConfig {
        CVStackViewConfig(
            axis: .horizontal,
            alignment: .center,
            spacing: 0,
            layoutMargins: conversationStyle.textInsets,
        )
    }

    private let minBubbleHeight: CGFloat = 36

    private static let measurementKey_outerStack = "CVComponentTypingIndicator.measurementKey_outerStack"
    private static let measurementKey_innerStack = "CVComponentTypingIndicator.measurementKey_innerStack"

    public func measure(maxWidth: CGFloat, measurementBuilder: CVCellMeasurement.Builder) -> CGSize {
        owsAssertDebug(maxWidth > 0)

        var outerSubviewInfos = [ManualStackSubviewInfo]()
        var innerSubviewInfos = [ManualStackSubviewInfo]()

        if typingIndicator.avatarDataSource != nil {
            let avatarSize: CGSize = ConversationStyle.groupMessageAvatarSizeClass.size
            outerSubviewInfos.append(avatarSize.asManualSubviewInfo(hasFixedSize: true))
        }

        let typingIndicatorSize = TypingIndicatorView.measure(measurementBuilder: measurementBuilder)
        innerSubviewInfos.append(typingIndicatorSize.asManualSubviewInfo(hasFixedSize: true))

        let innerStackMeasurement = ManualStackView.measure(
            config: innerStackViewConfig,
            measurementBuilder: measurementBuilder,
            measurementKey: Self.measurementKey_innerStack,
            subviewInfos: innerSubviewInfos,
        )
        var innerStackSize = innerStackMeasurement.measuredSize
        innerStackSize.height = max(minBubbleHeight, innerStackSize.height)
        outerSubviewInfos.append(innerStackSize.asManualSubviewInfo(hasFixedWidth: true))

        // We always use a stretching spacer.
        outerSubviewInfos.append(ManualStackSubviewInfo.empty)

        let outerStackMeasurement = ManualStackView.measure(
            config: outerStackViewConfig,
            measurementBuilder: measurementBuilder,
            measurementKey: Self.measurementKey_outerStack,
            subviewInfos: outerSubviewInfos,
            maxWidth: maxWidth,
        )
        return outerStackMeasurement.measuredSize
    }

    // MARK: -

    // Used for rendering some portion of an Conversation View item.
    // It could be the entire item or some part thereof.
    public class CVComponentViewTypingIndicator: NSObject, CVComponentView {

        fileprivate let outerStackView = ManualStackView(name: "Typing indicator outer")
        fileprivate let innerStackView = ManualStackView(name: "Typing indicator inner")

        fileprivate let avatarView = ConversationAvatarView(
            sizeClass: ConversationStyle.groupMessageAvatarSizeClass,
            localUserDisplayMode: .asUser,
            useAutolayout: false,
        )
        // Bubble view when there is no chat wallpaper.
        fileprivate let chatColorView = CVColorOrGradientView()
        // Bubble view when there is a chat wallpaper.
        fileprivate var wallpaperBlurView: CVWallpaperBlurView?
        fileprivate func ensureWallpaperBlurView() -> CVWallpaperBlurView {
            if let wallpaperBlurView {
                return wallpaperBlurView
            }
            let wallpaperBlurView = CVWallpaperBlurView()
            self.wallpaperBlurView = wallpaperBlurView
            return wallpaperBlurView
        }

        fileprivate let typingIndicatorView = TypingIndicatorView()

        public var isDedicatedCellView = false

        public var rootView: UIView {
            outerStackView
        }

        // MARK: -

        public func setIsCellVisible(_ isCellVisible: Bool) {
            if isCellVisible {
                typingIndicatorView.startAnimation()
            } else {
                typingIndicatorView.stopAnimation()
            }
        }

        public func reset() {
            owsAssertDebug(isDedicatedCellView)

            outerStackView.reset()
            innerStackView.reset()
            avatarView.reset()

            chatColorView.reset()
            chatColorView.removeFromSuperview()

            wallpaperBlurView?.removeFromSuperview()

            typingIndicatorView.reset()
            typingIndicatorView.removeFromSuperview()
        }
    }
}

// MARK: - Tellomi 用例钩子

extension CVComponentTypingIndicator.CVComponentViewTypingIndicator {
    /// 气泡本体（不含尾巴外扩）在 `view` 里的排版位置
    func tellomiBubbleFrameForTesting(in view: UIView) -> CGRect {
        innerStackView.convert(innerStackView.bounds, to: view)
    }

    /// 头像在 `view` 里的位置；单聊不带头像时为 nil
    func tellomiAvatarFrameForTesting(in view: UIView) -> CGRect? {
        guard avatarView.superview != nil else { return nil }
        return avatarView.convert(avatarView.bounds, to: view)
    }
}
