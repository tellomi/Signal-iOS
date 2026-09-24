//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

/// Tellomi（tellomi/tellomi#1257）：聊天里 ≥ 2 张图片 / 视频的一行横滑（需求 C-1…C-13）。
///
/// 滑动区是整屏宽：`CVComponentMessage` 把它放在 cell 最外层（hOuterStack）上，竖直位置对齐气泡里给它留的占位
/// （`CVComponentBodyMedia` 横滑模式下的 rootView）；气泡本身在这一段挖空（`CVColorOrGradientView.bubbleGap`）。
///
/// - 每张是上游的 `CVMediaView`（缩略图、视频标记、上传 / 下载进度与重试照旧，C-12），四角 18、浅色主题下 1 物理像素描边（C-4）。
/// - 松手吸附到「某一张的左边对齐起点」，甩得快可以越过几张（C-6）；「减弱动态效果」时不回弹（C-13）。
/// - 能滑时相册上的横向拖动只翻图：屏幕边缘返回优先，iOS 26 的「内容区右滑返回」要等它失败（C-11）。
/// - `overlayView` 不随图片滚动，范围是相册可视区：无说明时的时间胶囊（C-7）、「下载 N 个项目」（C-12）放在这里。
final class CVAlbumCarouselView: UIView {

    /// 不随图片滚动的一层（相册可视区）。
    let overlayView = ManualLayoutView(name: "albumCarousel.overlay")

    private let scrollView = CarouselScrollView()

    private(set) var itemViews = [CVMediaView]()
    private var aspectRatios = [CGFloat]()
    private var interactionId: String?
    private var startInset: CGFloat = 0
    private var alignEndWhenFits = false
    private var showsItemStroke = false
    private var isCellVisible = false
    private var loadedItemIndexes = Set<Int>()

    private(set) var geometry: AlbumCarouselGeometry.Layout?

    /// 读屏「第几张」（上下滑切换）；滑动停下后跟着更新。
    private var accessibilityItemIndex = 0

    private var isRTL: Bool { CurrentAppContext().isRTL }

    override init(frame: CGRect) {
        super.init(frame: frame)

        clipsToBounds = false
        backgroundColor = .clear

        scrollView.carousel = self
        scrollView.delegate = scrollView
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceVertical = false
        scrollView.decelerationRate = .fast
        scrollView.clipsToBounds = true
        scrollView.scrollsToTop = false
        scrollView.contentInsetAdjustmentBehavior = .never
        addSubview(scrollView)

        overlayView.isUserInteractionEnabled = false
        // ManualLayoutView 默认关掉了 autoresizing 约束；放在普通 UIView 里、不关回来会被自动布局压成 0
        overlayView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(overlayView)

        isAccessibilityElement = true
        accessibilityTraits = .adjustable
    }

    @available(*, unavailable, message: "use other constructor instead.")
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Configuration

    func configure(
        itemViews: [CVMediaView],
        aspectRatios: [CGFloat],
        interactionId: String,
        alignEndWhenFits: Bool,
        showsItemStroke: Bool,
    ) {
        owsAssertDebug(itemViews.count == aspectRatios.count)

        reset()

        self.itemViews = itemViews
        self.aspectRatios = aspectRatios
        self.interactionId = interactionId
        self.alignEndWhenFits = alignEndWhenFits
        self.showsItemStroke = showsItemStroke

        for itemView in itemViews {
            itemView.layer.cornerRadius = AlbumCarouselGeometry.itemCornerRadius
            itemView.layer.cornerCurve = .continuous
            itemView.clipsToBounds = true
            if showsItemStroke {
                itemView.layer.borderWidth = 1 / UIScreen.main.scale
                itemView.layer.borderColor = UIColor(white: 0, alpha: 0.15).cgColor
            }
            if isRTL {
                // 整条滑动区左右翻转（见 layoutSubviews），每张再翻回来
                itemView.transform = CGAffineTransform(scaleX: -1, y: 1)
            }
            // CVMediaView 是 ManualLayoutView（默认关掉 autoresizing 约束），在 UIScrollView 里要关回来，否则被自动布局压成 0
            itemView.translatesAutoresizingMaskIntoConstraints = true
            scrollView.addSubview(itemView)
        }

        accessibilityLabel = String.nonPluralLocalizedStringWithFormat(
            OWSLocalizedString(
                "ACCESSIBILITY_LABEL_MEDIA_TELLOMI_ALBUM_FORMAT",
                comment: "Accessibility label for a horizontally scrolling album in a chat. Embeds {{ the number of items }}.",
            ),
            OWSFormat.formatInt(itemViews.count),
        )

        setNeedsLayout()
    }

    func reset() {
        for itemView in itemViews {
            itemView.unloadMedia()
            itemView.removeFromSuperview()
        }
        itemViews = []
        aspectRatios = []
        interactionId = nil
        geometry = nil
        loadedItemIndexes = []
        accessibilityItemIndex = 0
        scrollView.setContentOffset(.zero, animated: false)
        scrollView.contentSize = .zero
        overlayView.reset()
    }

    /// 起点：静止时第一张的左边到屏幕起始边的距离（对方 = 对方气泡起点，自己 = 自己气泡列起点，C-5）。
    func setStartInset(_ startInset: CGFloat) {
        guard self.startInset != startInset else {
            return
        }
        self.startInset = startInset
        setNeedsLayout()
    }

    var isScrollable: Bool { geometry?.isScrollable ?? false }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()

        // RTL 时整条滑动区左右翻转（每张在 configure 里翻回来）；transform 不是恒等时不能设 frame
        scrollView.transform = isRTL ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        scrollView.bounds.size = bounds.size
        scrollView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        scrollView.bounces = !UIAccessibility.isReduceMotionEnabled
        scrollView.alwaysBounceHorizontal = false

        guard !aspectRatios.isEmpty, bounds.width > 0 else {
            return
        }

        let layout = AlbumCarouselGeometry.layout(
            viewportWidth: bounds.width,
            startInset: startInset,
            endMargin: AlbumCarouselGeometry.endMargin,
            spacing: AlbumCarouselGeometry.itemSpacing,
            minNextPeek: AlbumCarouselGeometry.nextItemMinPeek,
            rowHeight: bounds.height,
            aspectRatios: aspectRatios,
            alignEndWhenFits: alignEndWhenFits,
        )
        let previousLayout = geometry
        geometry = layout

        for (index, itemView) in itemViews.enumerated() {
            // transform 不是恒等时不能设 frame
            let frame = layout.itemFrame(index)
            itemView.bounds = CGRect(origin: .zero, size: frame.size)
            itemView.center = CGPoint(x: frame.midX, y: frame.midY)
        }
        scrollView.contentSize = CGSize(width: layout.contentWidth, height: bounds.height)

        if previousLayout != layout {
            // 重新配置（新消息进来、屏幕旋转）后回到上次停的那一张，而不是跳回第一张
            let savedOffset = interactionId.flatMap { Self.savedOffsets[$0] } ?? 0
            let offset = layout.isScrollable ? min(max(savedOffset, 0), layout.maxScroll) : 0
            scrollView.setContentOffset(CGPoint(x: offset, y: 0), animated: false)
            accessibilityItemIndex = layout.itemIndex(atOffset: offset)
        }

        overlayView.frame = albumAreaFrame
        updateLoadedItems()
        updateAccessibility()
    }

    /// 相册可视区（本视图坐标）：能滑时是「起点 … 屏宽 − 16」，放得下时是整组实际占的那一段。
    var albumAreaFrame: CGRect {
        guard let layout = geometry, let firstLeft = layout.itemLefts.first, let lastLeft = layout.itemLefts.last, let lastWidth = layout.itemWidths.last else {
            return bounds
        }
        let start = layout.isScrollable ? layout.startInset : firstLeft
        let end = layout.isScrollable ? layout.viewportWidth - AlbumCarouselGeometry.endMargin : lastLeft + lastWidth
        let x = isRTL ? bounds.width - end : start
        return CGRect(x: x, y: 0, width: end - start, height: bounds.height)
    }

    // MARK: - Scrolling

    fileprivate func scrollViewDidScroll() {
        updateLoadedItems()
    }

    fileprivate func targetOffset(forReleaseAt currentOffset: CGFloat, projectedOffset: CGFloat, velocity: CGFloat) -> CGFloat {
        guard let layout = geometry else {
            return currentOffset
        }
        let velocitySign = velocity > 0.2 ? 1 : (velocity < -0.2 ? -1 : 0)
        return layout.targetSnapOffset(currentOffset: currentOffset, projectedOffset: projectedOffset, velocitySign: velocitySign)
    }

    fileprivate func scrollViewDidSettle() {
        guard let layout = geometry else {
            return
        }
        let offset = scrollView.contentOffset.x
        if let interactionId {
            Self.saveOffset(offset, for: interactionId)
        }
        accessibilityItemIndex = layout.itemIndex(atOffset: offset)
        updateAccessibility()
    }

    /// C-9：关查看器前把这一张滚到完整露出（已经整张可见就不动）。
    func revealItem(_ index: Int, animated: Bool) {
        guard let layout = geometry, layout.itemWidths.indices.contains(index) else {
            return
        }
        let target = layout.offsetRevealingItem(index, currentOffset: scrollView.contentOffset.x)
        let shouldAnimate = animated && !UIAccessibility.isReduceMotionEnabled
        scrollView.setContentOffset(CGPoint(x: target, y: 0), animated: shouldAnimate)
        if let interactionId {
            Self.saveOffset(target, for: interactionId)
        }
        accessibilityItemIndex = index
        updateLoadedItems()
        updateAccessibility()
    }

    /// 能滑、且落点在滑动区里：这次横向拖动归相册，不做滑动回复 / 左滑看详情（C-11）。
    func claimsHorizontalPan(at location: CGPoint) -> Bool {
        isScrollable && bounds.contains(location)
    }

    /// 落点下的那一张（本视图坐标）；落在两张之间或空白处取最近的一张。
    func mediaView(at location: CGPoint) -> CVMediaView? {
        var best: CVMediaView?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for itemView in itemViews {
            let frame = convert(itemView.bounds, from: itemView)
            if frame.contains(location) {
                return itemView
            }
            let distance = abs(frame.midX - location.x)
            if distance < bestDistance {
                bestDistance = distance
                best = itemView
            }
        }
        return best
    }

    func index(of itemView: CVMediaView) -> Int? {
        itemViews.firstIndex(of: itemView)
    }

    // MARK: - Loading

    func setIsCellVisible(_ isCellVisible: Bool) {
        self.isCellVisible = isCellVisible
        updateLoadedItems()
    }

    /// 只加载可视区左右各一屏以内的缩略图（32 张不一次全解码）。
    private func updateLoadedItems() {
        guard isCellVisible, let layout = geometry else {
            for index in loadedItemIndexes where itemViews.indices.contains(index) {
                itemViews[index].unloadMedia()
            }
            loadedItemIndexes = []
            return
        }
        let offset = scrollView.contentOffset.x
        let window = (offset - layout.viewportWidth)...(offset + layout.viewportWidth * 2)
        var wanted = Set<Int>()
        for index in itemViews.indices {
            let left = layout.itemLefts[index]
            let right = left + layout.itemWidths[index]
            if right >= window.lowerBound, left <= window.upperBound {
                wanted.insert(index)
            }
        }
        for index in wanted.subtracting(loadedItemIndexes) {
            itemViews[index].loadMedia()
        }
        for index in loadedItemIndexes.subtracting(wanted) {
            itemViews[index].unloadMedia()
        }
        loadedItemIndexes = wanted
    }

    // MARK: - Accessibility（C-13：整组读作「相册，共 N 项」，上下滑逐张切换）

    private func updateAccessibility() {
        guard !itemViews.isEmpty else {
            accessibilityValue = nil
            return
        }
        let index = min(max(accessibilityItemIndex, 0), itemViews.count - 1)
        accessibilityValue = String.nonPluralLocalizedStringWithFormat(
            OWSLocalizedString(
                "ACCESSIBILITY_LABEL_MEDIA_TELLOMI_ALBUM_ITEM_FORMAT",
                comment: "Accessibility value for the current item of a horizontally scrolling album in a chat. Embeds {{ %1$@ the position of the item, %2$@ the number of items }}.",
            ),
            OWSFormat.formatInt(index + 1),
            OWSFormat.formatInt(itemViews.count),
        )
    }

    /// 双击打开的是当前这一张（每次读的时候算：cell 会跟着会话上下滚动）。
    override var accessibilityActivationPoint: CGPoint {
        get {
            guard itemViews.indices.contains(accessibilityItemIndex) else {
                return super.accessibilityActivationPoint
            }
            let itemView = itemViews[accessibilityItemIndex]
            let frame = UIAccessibility.convertToScreenCoordinates(itemView.bounds, in: itemView)
            return CGPoint(x: frame.midX, y: frame.midY)
        }
        set {
            super.accessibilityActivationPoint = newValue
        }
    }

    override func accessibilityIncrement() {
        revealItem(min(accessibilityItemIndex + 1, itemViews.count - 1), animated: true)
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
    }

    override func accessibilityDecrement() {
        revealItem(max(accessibilityItemIndex - 1, 0), animated: true)
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
    }

    // MARK: - Saved offsets

    /// 同一条消息滑到哪一张：cell 复用、重新配置后恢复（最多记 64 条）。
    private static var savedOffsets = [String: CGFloat]()
    private static var savedOffsetOrder = [String]()

    private static func saveOffset(_ offset: CGFloat, for interactionId: String) {
        AssertIsOnMainThread()
        if savedOffsets[interactionId] == nil {
            savedOffsetOrder.append(interactionId)
            if savedOffsetOrder.count > 64 {
                savedOffsets[savedOffsetOrder.removeFirst()] = nil
            }
        }
        savedOffsets[interactionId] = offset
    }

    // MARK: - Testing

    var contentOffsetForTesting: CGFloat { scrollView.contentOffset.x }

    func setContentOffsetForTesting(_ offset: CGFloat) {
        scrollView.setContentOffset(CGPoint(x: offset, y: 0), animated: false)
        scrollViewDidSettle()
    }

    var accessibilityItemIndexForTesting: Int { accessibilityItemIndex }

    var layoutDescriptionForTesting: String {
        var lines = [String]()
        lines.append("carousel frame=\(NSCoder.string(for: frame)) startInset=\(startInset) isRTL=\(isRTL)")
        lines.append("scroll frame=\(NSCoder.string(for: scrollView.frame)) bounds=\(NSCoder.string(for: scrollView.bounds)) contentSize=\(NSCoder.string(for: scrollView.contentSize)) transform=\(scrollView.transform)")
        if let geometry {
            lines.append("geometry lefts=\(geometry.itemLefts) widths=\(geometry.itemWidths) content=\(geometry.contentWidth) row=\(geometry.rowHeight)")
        }
        for (index, itemView) in itemViews.enumerated() {
            lines.append("item\(index) frame=\(NSCoder.string(for: itemView.frame)) superview=\(itemView.superview === scrollView)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Scroll view

    /// 相册自己的滚动：松手吸附；手势上让屏幕边缘返回优先、让 iOS 26 的内容区返回等它失败（C-11）。
    private final class CarouselScrollView: UIScrollView, UIScrollViewDelegate {
        weak var carousel: CVAlbumCarouselView?

        private var navigationController: UINavigationController? {
            var responder: UIResponder? = self
            while let current = responder {
                if let navigationController = current as? UINavigationController {
                    return navigationController
                }
                responder = current.next
            }
            return nil
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer,
        ) -> Bool {
            guard gestureRecognizer === panGestureRecognizer else {
                return false
            }
            // 屏幕左边缘右滑永远是返回
            return otherGestureRecognizer === navigationController?.interactivePopGestureRecognizer
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer,
        ) -> Bool {
            guard gestureRecognizer === panGestureRecognizer else {
                return false
            }
            if #available(iOS 26, *) {
                // 相册上的横向拖动只翻图：内容区右滑返回要等这次拖动失败
                return otherGestureRecognizer === navigationController?.interactiveContentPopGestureRecognizer
            }
            return false
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            carousel?.scrollViewDidScroll()
        }

        func scrollViewWillEndDragging(
            _ scrollView: UIScrollView,
            withVelocity velocity: CGPoint,
            targetContentOffset: UnsafeMutablePointer<CGPoint>,
        ) {
            guard let carousel else {
                return
            }
            targetContentOffset.pointee.x = carousel.targetOffset(
                forReleaseAt: scrollView.contentOffset.x,
                projectedOffset: targetContentOffset.pointee.x,
                velocity: velocity.x,
            )
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                carousel?.scrollViewDidSettle()
            }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            carousel?.scrollViewDidSettle()
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            carousel?.scrollViewDidSettle()
        }
    }
}
