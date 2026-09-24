//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

class CVComponentBodyMedia: CVComponentBase, CVComponent {

    var componentKey: CVComponentKey { .bodyMedia }

    private let bodyMedia: CVComponentState.BodyMedia
    private var items: [CVMediaAlbumItem] {
        bodyMedia.items
    }

    private var areAllItemsImages: Bool {
        return items.allSatisfy {
            switch $0.attachment.contentType {
            case .image: true
            case .video, .audio, .file: false
            }
        }
    }

    private let footerOverlay: CVComponent?

    /// Tellomi（tellomi/tellomi#1257，C-1）：≥ 2 个附件、而且全部是图片或视频 → 一行横滑（CVAlbumCarouselView）；
    /// 否则照上游的拼图。1 张、GIF、贴纸、一次性查看、按文件发送的都不走这里。
    var isAlbumCarousel: Bool {
        guard !isBorderless, items.count >= 2 else {
            return false
        }
        return items.allSatisfy {
            switch $0.attachment.contentType {
            case .image, .video: true
            case .audio, .file: false
            }
        }
    }

    /// 相册与气泡其它部分（上面的群昵称 / 引用，下面的说明）之间的空隙；那一侧没有东西时不留。
    static let albumCarouselBubbleSpacing: CGFloat = 4

    var albumCarouselHasContentAbove: Bool {
        itemViewState.senderNameState != nil || componentState.quotedReply != nil || componentState.linkPreview != nil
    }

    var albumCarouselHasContentBelow: Bool {
        componentState.bodyText != nil
            || (footerOverlay == nil && !itemViewState.shouldHideFooter)
            || componentState.bottomButtons != nil
            || componentState.bottomLabel != nil
    }

    /// 占位里相册上下各空多少（占位高 = 上 + 行高 + 下）。
    var albumCarouselInsets: (top: CGFloat, bottom: CGFloat) {
        (
            albumCarouselHasContentAbove ? Self.albumCarouselBubbleSpacing : 0,
            albumCarouselHasContentBelow ? Self.albumCarouselBubbleSpacing : 0,
        )
    }

    /// C-2：行高 = 屏宽 × 0.6，夹在 [220, 300]；横屏与 iPad 另外不超过屏高 × 0.4。
    static func albumCarouselRowHeight(conversationStyle: ConversationStyle) -> CGFloat {
        let screenSize = UIScreen.main.bounds.size
        let capByScreenHeight = screenSize.width > screenSize.height || UIDevice.current.userInterfaceIdiom == .pad
        return AlbumCarouselGeometry.rowHeight(
            screenWidth: conversationStyle.viewWidth,
            screenHeight: screenSize.height,
            capByScreenHeight: capByScreenHeight,
        )
    }

    init(itemModel: CVItemModel, bodyMedia: CVComponentState.BodyMedia, footerOverlay: CVComponent?) {
        self.bodyMedia = bodyMedia
        self.footerOverlay = footerOverlay

        super.init(itemModel: itemModel)
    }

    func buildComponentView(componentDelegate: CVComponentDelegate) -> CVComponentView {
        CVComponentViewBodyMedia()
    }

    func configureForRendering(
        componentView componentViewParam: CVComponentView,
        cellMeasurement: CVCellMeasurement,
        componentDelegate: CVComponentDelegate,
    ) {
        guard let componentView = componentViewParam as? CVComponentViewBodyMedia else {
            owsFailDebug("Unexpected componentView.")
            componentViewParam.reset()
            return
        }

        let conversationStyle = self.conversationStyle

        if isAlbumCarousel {
            configureAlbumCarousel(
                componentView: componentView,
                cellMeasurement: cellMeasurement,
                componentDelegate: componentDelegate,
            )
            return
        }

        let albumView = componentView.albumView
        albumView.configure(
            mediaCache: mediaCache,
            items: items,
            interaction: interaction,
            isBorderless: isBorderless,
            cellMeasurement: cellMeasurement,
            conversationStyle: conversationStyle,
        )

        let stackView = componentView.stackView

        stackView.reset()
        stackView.configure(
            config: stackConfig,
            cellMeasurement: cellMeasurement,
            measurementKey: Self.measurementKey_stackView,
            subviews: [albumView],
        )

        if let footerOverlay {
            let footerView: CVComponentView
            if let footerOverlayView = componentView.footerOverlayView {
                footerView = footerOverlayView
            } else {
                let footerOverlayView = CVComponentFooter.CVComponentViewFooter()
                componentView.footerOverlayView = footerOverlayView
                footerView = footerOverlayView
            }
            footerOverlay.configureForRendering(
                componentView: footerView,
                cellMeasurement: cellMeasurement,
                componentDelegate: componentDelegate,
            )
            let footerRootView = footerView.rootView
            stackView.addSubview(footerRootView)
            let footerSize = cellMeasurement.size(key: Self.measurementKey_footerSize) ?? .zero
            stackView.addLayoutBlock { view in
                var footerFrame = view.bounds
                // Apply h-insets.
                footerFrame.x += conversationStyle.textInsetHorizontal
                footerFrame.width -= conversationStyle.textInsetHorizontal * 2
                // Ensure footer height fits within text insets.
                let maxFooterHeight = (
                    view.bounds.height -
                        (conversationStyle.textInsetTop + conversationStyle.textInsetBottom),
                )
                footerFrame.height = min(maxFooterHeight, footerSize.height)
                // Bottom align.
                footerFrame.y = (
                    view.bounds.height -
                        (
                            footerFrame.height +
                                conversationStyle.textInsetBottom
                        ),
                )
                footerRootView.frame = footerFrame
            }

            let maxGradientHeight: CGFloat = 40
            let gradientLayer = CAGradientLayer()
            gradientLayer.colors = [
                UIColor(white: 0, alpha: 0.0).cgColor,
                UIColor(white: 0, alpha: 0.4).cgColor,
            ]
            let gradientView = OWSLayerView(frame: .zero) { layerView in
                var layerFrame = layerView.bounds
                layerFrame.height = min(maxGradientHeight, layerView.height)
                layerFrame.y = layerView.height - layerFrame.height
                gradientLayer.frame = layerFrame
            }
            componentView.bodyMediaGradientView = gradientView
            gradientView.layer.addSublayer(gradientLayer)
            albumView.addSubview(gradientView)
            stackView.layoutSubviewToFillSuperviewEdges(gradientView)
        }

        // Only apply "inner shadow" for single media, not albums.
        if
            !isBorderless,
            albumView.itemViews.count == 1,
            let firstMediaView = albumView.itemViews.first
        {
            let shadowColor: UIColor = isDarkThemeEnabled ? .white : .black
            let innerShadowView = OWSBubbleShapeView(mode: .innerShadow(
                color: shadowColor,
                radius: 0.5,
                opacity: 0.15,
            ))
            componentView.innerShadowView = innerShadowView
            firstMediaView.addSubview(innerShadowView)
            stackView.layoutSubviewToFillSuperviewEdges(innerShadowView)
        }

        configureSkippedDownloadsOverlay(overlayHost: stackView, displayedItemCount: albumView.itemViews.count)
    }

    /// 「下载 N 个项目」与未下载的总大小（C-12）。拼图时盖在拼图上；横滑时盖在相册可视区上（不随图片滚动）。
    private func configureSkippedDownloadsOverlay(overlayHost stackView: ManualLayoutView, displayedItemCount: Int) {
        if bodyMedia.mediaAlbumHasSkippedAttachment {
            // Media size label and download icon should both use the same color that CVAttachmentProgressView uses.
            let backgroundCircleConfiguration = CVAttachmentProgressView.Configuration.forMediaOverlay()

            let iconViewSize = CGSize.square(24)
            let iconView = CVImageView(image: Theme.iconImage(.arrowDown))
            iconView.tintColor = backgroundCircleConfiguration.foregroundColor

            if displayedItemCount > 1 {
                // Download icon and number of media displayed over pill-shaped blur background.

                let downloadStackConfig = ManualStackView.Config(
                    axis: .horizontal,
                    alignment: .center,
                    spacing: 6,
                    layoutMargins: UIEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 14),
                )
                let downloadStack = ManualStackView(name: "downloadStack")
                downloadStack.apply(config: downloadStackConfig)
                var subviewInfos = [ManualStackSubviewInfo]()

                let pillBackgroundView = CVAttachmentProgressView.circularBackgroundView(configuration: backgroundCircleConfiguration)
                downloadStack.addSubviewToFillSuperviewEdges(pillBackgroundView)

                downloadStack.addArrangedSubview(iconView)
                subviewInfos.append(iconViewSize.asManualSubviewInfo(hasFixedSize: true))

                let downloadLabel = CVLabel()
                let downloadFormat = (
                    areAllItemsImages
                        ? OWSLocalizedString(
                            "MEDIA_GALLERY_ITEM_IMAGE_COUNT_%d",
                            tableName: "PluralAware",
                            comment: "Format for an indicator of the number of image items in a media gallery. Embeds {{ the number of items in the media gallery }}.",
                        )
                        : OWSLocalizedString(
                            "MEDIA_GALLERY_ITEM_MIXED_COUNT_%d",
                            tableName: "PluralAware",
                            comment: "Format for an indicator of the number of image or video items in a media gallery. Embeds {{ the number of items in the media gallery }}.",
                        ),
                )
                downloadStack.addArrangedSubview(downloadLabel)
                let downloadLabelConfig = CVLabelConfig(
                    text: .text(String.localizedStringWithFormat(downloadFormat, items.count)),
                    displayConfig: .forUnstyledText(
                        font: .dynamicTypeSubheadline,
                        textColor: backgroundCircleConfiguration.foregroundColor,
                    ),
                    font: .dynamicTypeSubheadline,
                    textColor: backgroundCircleConfiguration.foregroundColor,
                )
                downloadLabelConfig.applyForRendering(label: downloadLabel)
                let downloadLabelSize = CVText.measureLabel(
                    config: downloadLabelConfig,
                    maxWidth: CGFloat.greatestFiniteMagnitude,
                )
                subviewInfos.append(downloadLabelSize.asManualSubviewInfo)

                let downloadStackMeasurement = ManualStackView.measure(
                    config: downloadStackConfig,
                    subviewInfos: subviewInfos,
                )
                downloadStack.measurement = downloadStackMeasurement
                stackView.addSubviewToCenterOnSuperview(
                    downloadStack,
                    size: downloadStackMeasurement.measuredSize,
                )
            } else {
                // Just an icon over circular blur background.
                let circleSize = CGSize.square(44)
                let circleView = CVAttachmentProgressView.circularBackgroundView(configuration: backgroundCircleConfiguration)
                stackView.addSubviewToCenterOnSuperview(circleView, size: circleSize)
                stackView.addSubviewToCenterOnSuperview(iconView, size: iconViewSize)
            }

            if bodyMedia.mediaAlbumHasSkippedAttachment {
                let pendingManualDownloadAttachments = items
                    .lazy
                    .compactMap { (item: CVMediaAlbumItem) -> ReferencedAttachment? in
                        switch item.attachment {
                        case .stream:
                            return nil
                        case .backupThumbnail:
                            // TODO:[Backups]: Check for media tier download state
                            return nil
                        case .pointer(let attachment, let downloadState):
                            if item.threadHasPendingMessageRequest {
                                // Doesn't count.
                                return nil
                            }
                            switch downloadState {
                            case .none:
                                return attachment
                            case .enqueuedOrDownloading, .failed:
                                return nil
                            }
                        case .undownloadable:
                            return nil
                        }
                    }
                let totalSize = pendingManualDownloadAttachments.map {
                    $0.attachment.asAnyPointer()?.unencryptedByteCount ?? 0
                }.reduce(0, +)

                // Total size of undownloaded media displayed over the blur pill-shaped background.
                if totalSize > 0 {
                    var downloadSizeText = [OWSFormat.localizedFileSizeString(from: UInt64(safeCast: totalSize))]
                    if
                        pendingManualDownloadAttachments.count == 1,
                        let firstAttachmentPointer = pendingManualDownloadAttachments.first
                    {
                        let mimeType = firstAttachmentPointer.attachment.mimeType
                        if
                            MimeTypeUtil.isSupportedDefinitelyAnimatedMimeType(mimeType)
                            || firstAttachmentPointer.reference.renderingFlag == .shouldLoop
                        {
                            // Do nothing.
                        } else if MimeTypeUtil.isSupportedImageMimeType(mimeType) {
                            downloadSizeText.append(CommonStrings.attachmentTypePhoto)
                        } else if MimeTypeUtil.isSupportedVideoMimeType(mimeType) {
                            downloadSizeText.append(CommonStrings.attachmentTypeVideo)
                        }
                    }

                    let downloadSizeView = ManualLayoutViewWithLayer.pillView(name: "downloadSizeView")
                    downloadSizeView.layoutMargins = UIEdgeInsets(hMargin: 8, vMargin: 4)

                    let pillBackgroundView = CVAttachmentProgressView.circularBackgroundView(configuration: backgroundCircleConfiguration)
                    downloadSizeView.addSubviewToFillSuperviewEdges(pillBackgroundView)

                    let downloadSizeLabelConfig = CVLabelConfig(
                        text: .text(downloadSizeText.joined(separator: " • ")),
                        displayConfig: .forUnstyledText(
                            font: .dynamicTypeCaption1,
                            textColor: backgroundCircleConfiguration.foregroundColor,
                        ),
                        font: .dynamicTypeCaption1,
                        textColor: backgroundCircleConfiguration.foregroundColor,
                    )
                    let downloadSizeLabel = CVLabel()
                    downloadSizeLabelConfig.applyForRendering(label: downloadSizeLabel)
                    let downloadSizeLabelSize = CVText.measureLabel(
                        config: downloadSizeLabelConfig,
                        maxWidth: .greatestFiniteMagnitude,
                    )
                    downloadSizeView.addSubviewToFillSuperviewMargins(downloadSizeLabel)

                    let downloadSizeViewSize = downloadSizeLabelSize + downloadSizeView.layoutMargins.asSize
                    stackView.addSubview(downloadSizeView)
                    stackView.addLayoutBlock { view in
                        let inset: CGFloat = 6
                        let x = (
                            CurrentAppContext().isRTL
                                ? view.width - (downloadSizeViewSize.width - inset)
                                : inset,
                        )
                        downloadSizeView.frame = CGRect(
                            x: x,
                            y: inset,
                            width: downloadSizeViewSize.width,
                            height: downloadSizeViewSize.height,
                        )
                    }
                }
            }
        }
    }

    // MARK: - Album carousel（Tellomi，tellomi/tellomi#1257）

    private static let measurementKey_albumCarouselRowHeight = "CVComponentBodyMedia.measurementKey_albumCarouselRowHeight"

    /// 横滑模式：气泡里只放一段和相册一样高的占位（本组件的 rootView），相册本身由 CVComponentMessage 放在 cell 最外层。
    private func configureAlbumCarousel(
        componentView: CVComponentViewBodyMedia,
        cellMeasurement: CVCellMeasurement,
        componentDelegate: CVComponentDelegate,
    ) {
        let stackView = componentView.stackView
        stackView.reset()
        stackView.configure(
            config: stackConfig,
            cellMeasurement: cellMeasurement,
            measurementKey: Self.measurementKey_stackView,
            subviews: [componentView.albumCarouselPlaceholder],
        )

        let rowHeight = cellMeasurement.value(key: Self.measurementKey_albumCarouselRowHeight)
            ?? Self.albumCarouselRowHeight(conversationStyle: conversationStyle)
        let itemViews = items.map { item in
            let aspectRatio = AlbumCarouselGeometry.aspectRatio(item.mediaSize)
            let thumbnailQuality: AttachmentThumbnailQuality = item.mediaSize.isNonEmpty
                ? CVMediaAlbumView.thumbnailQuality(
                    mediaSizePoints: item.mediaSize,
                    viewSizePoints: CGSize(width: rowHeight * aspectRatio, height: rowHeight),
                )
                : .medium
            return CVMediaView(
                mediaCache: mediaCache,
                attachment: item.attachment,
                interaction: interaction,
                maxMessageWidth: conversationStyle.maxMediaMessageWidth,
                isBorderless: false,
                isLoopingVideo: item.renderingFlag == .shouldLoop,
                isBroken: item.isBroken,
                thumbnailQuality: thumbnailQuality,
                conversationStyle: conversationStyle,
            )
        }

        let carousel = componentView.ensureAlbumCarouselView()
        carousel.configure(
            itemViews: itemViews,
            aspectRatios: items.map { AlbumCarouselGeometry.aspectRatio($0.mediaSize) },
            interactionId: interaction.uniqueId,
            alignEndWhenFits: interaction is TSOutgoingMessage,
            showsItemStroke: !isDarkThemeEnabled,
        )
        componentView.stackView.albumCarouselOverlayView = carousel.overlayView

        // C-7：无说明时时间和勾在相册可视区右下角的半透明深色胶囊里，不随图片滚动
        if let footerOverlay {
            let footerView: CVComponentView
            if let footerOverlayView = componentView.footerOverlayView {
                footerView = footerOverlayView
            } else {
                let footerOverlayView = CVComponentFooter.CVComponentViewFooter()
                componentView.footerOverlayView = footerOverlayView
                footerView = footerOverlayView
            }
            footerOverlay.configureForRendering(
                componentView: footerView,
                cellMeasurement: cellMeasurement,
                componentDelegate: componentDelegate,
            )
            let footerSize = cellMeasurement.size(key: Self.measurementKey_footerSize) ?? .zero
            let pillInsets = UIEdgeInsets(hMargin: 8, vMargin: 3)
            let pillSize = CGSize(width: footerSize.width + pillInsets.totalWidth, height: footerSize.height + pillInsets.totalHeight)
            let pill = ManualLayoutViewWithLayer(name: "albumCarousel.footerPill")
            pill.backgroundColor = UIColor(white: 0, alpha: 0.45)
            pill.layer.cornerRadius = pillSize.height / 2
            pill.clipsToBounds = true
            let footerRootView = footerView.rootView
            // 胶囊与页脚都是 ManualLayoutView（关掉了 autoresizing 约束）：位置要在布局块里设，否则下一轮自动布局把它压成 0
            pill.addSubview(footerRootView) { _ in
                footerRootView.frame = CGRect(origin: CGPoint(x: pillInsets.left, y: pillInsets.top), size: footerSize)
            }
            carousel.overlayView.addSubview(pill)
            carousel.overlayView.addLayoutBlock { view in
                let inset: CGFloat = 8
                let x = CurrentAppContext().isRTL ? inset : view.bounds.width - (pillSize.width + inset)
                pill.frame = CGRect(origin: CGPoint(x: x, y: view.bounds.height - (pillSize.height + inset)), size: pillSize)
            }
        }

        configureSkippedDownloadsOverlay(overlayHost: carousel.overlayView, displayedItemCount: items.count)
    }

    /// 横滑模式下由 CVComponentMessage 挂到 cell 最外层的相册视图。
    func albumCarouselView(componentView: CVComponentView) -> CVAlbumCarouselView? {
        guard isAlbumCarousel, let componentView = componentView as? CVComponentViewBodyMedia else {
            return nil
        }
        return componentView.albumCarouselView
    }

    func bubbleViewPartner(componentView: CVComponentView) -> OWSBubbleViewPartner? {
        guard let componentView = componentView as? CVComponentViewBodyMedia else {
            owsFailDebug("Unexpected componentView.")
            return nil
        }
        return componentView.innerShadowView
    }

    private var stackConfig: CVStackViewConfig {
        CVStackViewConfig(
            axis: .vertical,
            alignment: .fill,
            spacing: 0,
            layoutMargins: .zero,
        )
    }

    private var maxMediaMessageWidth: CGFloat {
        let maxMediaMessageWidth = conversationStyle.maxMediaMessageWidth
        if self.isBorderless {
            return min(175, maxMediaMessageWidth)
        }
        return maxMediaMessageWidth
    }

    private static let measurementKey_stackView = "CVComponentBodyMedia.measurementKey_stackView"
    private static let measurementKey_footerSize = "CVComponentBodyMedia.measurementKey_footerSize"

    func measure(maxWidth: CGFloat, measurementBuilder: CVCellMeasurement.Builder) -> CGSize {
        owsAssertDebug(maxWidth > 0)
        owsAssertDebug(items.count > 0)

        // We may need to reserve space for a footer overlay.
        var minWidth: CGFloat = 0
        if let footerOverlay = self.footerOverlay {
            let maxFooterWidth = max(0, maxWidth - conversationStyle.textInsets.totalWidth)
            let footerSize = footerOverlay.measure(
                maxWidth: maxFooterWidth,
                measurementBuilder: measurementBuilder,
            )
            minWidth = min(maxWidth, footerSize.width + conversationStyle.textInsets.totalWidth)
            measurementBuilder.setSize(key: Self.measurementKey_footerSize, size: footerSize)
        }

        if isAlbumCarousel {
            // 气泡里只占一段相册的高度；宽度不撑气泡（说明气泡照普通文字消息的宽度，C-8）
            let rowHeight = Self.albumCarouselRowHeight(conversationStyle: conversationStyle)
            measurementBuilder.setValue(key: Self.measurementKey_albumCarouselRowHeight, value: rowHeight)
            let insets = albumCarouselInsets
            let stackMeasurement = ManualStackView.measure(
                config: stackConfig,
                measurementBuilder: measurementBuilder,
                measurementKey: Self.measurementKey_stackView,
                subviewInfos: [CGSize(width: 0, height: insets.top + rowHeight + insets.bottom).asManualSubviewInfo],
                maxWidth: maxWidth,
            )
            return stackMeasurement.measuredSize
        }

        let maxWidth = min(maxWidth, maxMediaMessageWidth)

        let albumSize = CVMediaAlbumView.measure(
            maxWidth: maxWidth,
            minWidth: minWidth,
            items: self.items,
            measurementBuilder: measurementBuilder,
        )
        let albumInfo = albumSize.asManualSubviewInfo
        let stackMeasurement = ManualStackView.measure(
            config: stackConfig,
            measurementBuilder: measurementBuilder,
            measurementKey: Self.measurementKey_stackView,
            subviewInfos: [albumInfo],
            maxWidth: maxWidth,
        )
        return stackMeasurement.measuredSize
    }

    // MARK: - Events

    override func cellWillBecomeVisible(
        componentDelegate: CVComponentDelegate,
    ) {
        AssertIsOnMainThread()

        if
            let message = interaction as? TSMessage,
            bodyMedia.mediaAlbumHasFailedAttachment || bodyMedia.mediaAlbumHasSkippedAttachment
        {
            componentDelegate.willBecomeVisibleWithSkippedDownloads(message)
        }
    }

    override func handleTap(
        sender: UIGestureRecognizer,
        componentDelegate: CVComponentDelegate,
        componentView: CVComponentView,
        renderItem: CVRenderItem,
    ) -> Bool {
        AssertIsOnMainThread()

        guard let componentView = componentView as? CVComponentViewBodyMedia else {
            owsFailDebug("Unexpected componentView.")
            return false
        }
        guard let message = interaction as? TSMessage else {
            owsFailDebug("Invalid interaction.")
            return false
        }

        if bodyMedia.mediaAlbumHasSkippedAttachment {
            componentDelegate.didTapSkippedDownloads(message)
            return true
        }

        let albumView = componentView.albumView
        let mediaView: CVMediaView
        if isAlbumCarousel, let carousel = componentView.albumCarouselView {
            guard let carouselMediaView = carousel.mediaView(at: sender.location(in: carousel)) else {
                Logger.warn("Missing mediaView.")
                return false
            }
            mediaView = carouselMediaView
        } else {
            let location = sender.location(in: albumView)
            guard let albumMediaView = albumView.mediaView(forLocation: location) else {
                Logger.warn("Missing mediaView.")
                return false
            }
            mediaView = albumMediaView
        }

        if
            !isAlbumCarousel,
            albumView.isMoreItemsView(mediaView: mediaView),
            bodyMedia.mediaAlbumHasFailedAttachment
        {
            componentDelegate.didTapSkippedDownloads(message)
            return true
        }

        switch mediaView.attachment {
        case .pointer(let pointer, let downloadState):
            switch downloadState {
            case .failed, .none:
                componentDelegate.didTapSkippedDownloads(message)
                return true
            case .enqueuedOrDownloading:
                componentDelegate.didCancelDownload(message, attachmentId: pointer.attachment.id)
                return true
            }
        case .stream(let referencedAttachmentStream, isUploading: _, imageMetadata: _):
            let itemViewModel = CVItemViewModelImpl(renderItem: renderItem)
            if let item = items.first(where: { $0.attachment.attachment.attachment.id == referencedAttachmentStream.attachment.id }), item.isBroken {
                componentDelegate.didTapBrokenVideo()
                return true
            }
            componentDelegate.didTapBodyMedia(
                itemViewModel: itemViewModel,
                attachment: referencedAttachmentStream,
                imageView: mediaView,
            )
            return true
        case .backupThumbnail(let thumbnail):
            let itemViewModel = CVItemViewModelImpl(renderItem: renderItem)
            componentDelegate.didTapBodyMedia(
                itemViewModel: itemViewModel,
                attachment: thumbnail,
                imageView: mediaView,
            )
            return true
        case .undownloadable:
            componentDelegate.didTapUndownloadableMedia()
            return true
        }
    }

    func albumItemView(
        forAttachment attachment: ReferencedAttachment,
        componentView: CVComponentView,
    ) -> UIView? {
        guard let componentView = componentView as? CVComponentViewBodyMedia else {
            owsFailDebug("Unexpected componentView.")
            return nil
        }
        if isAlbumCarousel, let carousel = componentView.albumCarouselView {
            // C-9：查看器缩回之前先把这一张滚到完整露出
            guard
                let index = carousel.itemViews.firstIndex(where: {
                    $0.attachment.attachment.attachment.id == attachment.attachment.id
                        && $0.attachment.attachment.reference.hasSameOwner(as: attachment.reference)
                })
            else {
                return nil
            }
            carousel.revealItem(index, animated: false)
            carousel.layoutIfNeeded()
            return carousel.itemViews[index]
        }

        let albumView = componentView.albumView
        guard
            let albumItemView = (albumView.itemViews.first {
                $0.attachment.attachment.attachment.id == attachment.attachment.id
                    && $0.attachment.attachment.reference.hasSameOwner(as: attachment.reference)
            })
        else {
            assert(albumView.moreItemsView != nil)
            return albumView.moreItemsView
        }
        return albumItemView
    }

    // MARK: -

    // We use this view to implement BodyMediaPresentationContext below.
    class CVComponentViewBodyMediaRootView: ManualStackView {

        fileprivate var bodyMediaGradientView: UIView?

        fileprivate var footerOverlayView: CVComponentView?

        /// 横滑模式：时间胶囊等不随图片滚动的一层，打开 / 关闭查看器时跟着隐藏。
        fileprivate weak var albumCarouselOverlayView: UIView?

        override open func reset() {
            bodyMediaGradientView = nil
            footerOverlayView = nil
            albumCarouselOverlayView = nil

            super.reset()
        }
    }

    // MARK: -

    // Used for rendering some portion of an Conversation View item.
    // It could be the entire item or some part thereof.
    class CVComponentViewBodyMedia: NSObject, CVComponentView {

        fileprivate let stackView = CVComponentViewBodyMediaRootView(name: "stackView")

        fileprivate let albumView = CVMediaAlbumView()

        fileprivate var bodyMediaGradientView: UIView? {
            get { stackView.bodyMediaGradientView }
            set { stackView.bodyMediaGradientView = newValue }
        }

        fileprivate var innerShadowView: OWSBubbleShapeView?

        /// 横滑模式（Tellomi #1257）：气泡里的占位与整屏宽的相册。
        fileprivate let albumCarouselPlaceholder = UIView()
        fileprivate private(set) var albumCarouselView: CVAlbumCarouselView?

        fileprivate func ensureAlbumCarouselView() -> CVAlbumCarouselView {
            if let albumCarouselView {
                return albumCarouselView
            }
            let albumCarouselView = CVAlbumCarouselView()
            self.albumCarouselView = albumCarouselView
            return albumCarouselView
        }

        var isDedicatedCellView = false

        var rootView: UIView {
            stackView
        }

        // MARK: - Subcomponents

        fileprivate var footerOverlayView: CVComponentView? {
            get { stackView.footerOverlayView }
            set { stackView.footerOverlayView = newValue }
        }

        // MARK: -

        func setIsCellVisible(_ isCellVisible: Bool) {
            if isCellVisible {
                albumView.loadMedia()
            } else {
                albumView.unloadMedia()
            }
            albumCarouselView?.setIsCellVisible(isCellVisible)
        }

        func reset() {
            albumView.reset()
            stackView.reset()
            footerOverlayView?.reset()
            albumCarouselView?.reset()

            bodyMediaGradientView?.removeFromSuperview()
            bodyMediaGradientView = nil

            innerShadowView?.removeFromSuperview()
            innerShadowView = nil
        }

    }
}

// MARK: -

protocol BodyMediaPresentationContext {
    var mediaOverlayViews: [UIView] { get }
}

// MARK: -

extension CVComponentBodyMedia.CVComponentViewBodyMediaRootView: BodyMediaPresentationContext {
    var mediaOverlayViews: [UIView] {
        var result = [UIView]()
        if let albumCarouselOverlayView {
            result.append(albumCarouselOverlayView)
        }
        if let footerOverlayView {
            result.append(footerOverlayView.rootView)
        }
        if let bodyMediaGradientView {
            result.append(bodyMediaGradientView)
        }
        return result
    }
}

// MARK: -

extension CVComponentBodyMedia: CVAccessibilityComponent {
    var accessibilityDescription: String {
        let genericMediaString = OWSLocalizedString(
            "ACCESSIBILITY_LABEL_MEDIA",
            comment: "Accessibility label for media.",
        )

        if bodyMedia.items.count > 1 {
            return String.localizedStringWithFormat(
                OWSLocalizedString(
                    "ACCESSIBILITY_LABEL_MULTIPLE_ATTACHMENTS_%d",
                    tableName: "PluralAware",
                    comment: "Accessibility label for multiple attachment items. Embeds {{ number of attachments }}.",
                ),
                bodyMedia.items.count,
            )
        }

        guard let mediaItem = bodyMedia.items.first else {
            return genericMediaString
        }

        let contentType: Attachment.ContentType
        let imageMetadata: ImageMetadata?
        switch mediaItem.attachment {
        case .stream(let referencedAttachmentStream, isUploading: _, let _imageMetadata):
            contentType = referencedAttachmentStream.attachment.contentType
            imageMetadata = _imageMetadata
        case .pointer(let referencedAttachmentPointer, downloadState: _):
            contentType = referencedAttachmentPointer.attachment.contentType
            imageMetadata = nil
        case .backupThumbnail(let referencedAttachmentBackupThumbnail):
            contentType = referencedAttachmentBackupThumbnail.attachment.contentType
            imageMetadata = nil
        case .undownloadable(let referencedAttachment):
            contentType = referencedAttachment.attachment.contentType
            imageMetadata = nil
        }

        switch contentType {
        case .file:
            return CommonStrings.attachmentTypeFile
        case .image:
            if let imageMetadata, imageMetadata.isAnimated {
                return CommonStrings.attachmentTypeAnimated
            } else {
                return CommonStrings.attachmentTypePhoto
            }
        case .video:
            if mediaItem.renderingFlag == .shouldLoop {
                return CommonStrings.attachmentTypeAnimated
            } else {
                return CommonStrings.attachmentTypeVideo
            }
        case .audio:
            return CommonStrings.attachmentTypeAudio
        }
    }
}
