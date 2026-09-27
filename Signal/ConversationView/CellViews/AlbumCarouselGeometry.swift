//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import CoreGraphics

/// Tellomi：多图横滑相册的几何（tellomi/tellomi#1257，需求 docs/product/specs/media-album-forward-picker.md C-2…C-6）。
///
/// owner 2026-09-25：聊天里的横滑撤回（会挡住右滑返回），聊天仍是 Signal 原来的宫格；这套几何现在给选图面板
/// 「只看已选」的排序行用（#1261），以后做动态（微博 / Threads / X 式）时的横滑图片也用它。
///
/// 一行横滑、整组同一个高度、每张按原比例；滑动区是整屏宽，静止时第一张的左边对齐「起点」，
/// 松手停在「某一张的左边对齐起点」，滑到底最后一张右边对齐右边距。与 Android 的 `AlbumCarouselGeometry.kt` 同一套规则。
///
/// 纯计算、没有 UIKit 依赖：单位是 pt，「内容坐标」的 0 是滑动区的起始边（LTR 为左边）。
enum AlbumCarouselGeometry {

    /// C-2：行高 = 屏宽 × 0.6，夹在 [220, 300] pt；横屏与 iPad 另外不超过屏高 × 0.4。
    static let rowHeightOfScreenWidth: CGFloat = 0.6
    static let minRowHeight: CGFloat = 220
    static let maxRowHeight: CGFloat = 300
    static let maxRowHeightOfScreenHeight: CGFloat = 0.4

    /// C-3：每张最窄 = 行高 × 9/16（更竖的图居中裁切）。
    static let minItemAspectRatio: CGFloat = 9 / 16

    /// 原图没带宽高时按正方形排。
    static let unknownAspectRatio: CGFloat = 1

    /// C-4：卡片间距与圆角。
    static let itemSpacing: CGFloat = 8
    static let itemCornerRadius: CGFloat = 18

    /// C-3：最宽的一张也给下一张留出的宽度。
    static let nextItemMinPeek: CGFloat = 48

    /// C-5：滑到底时最后一张右边与屏幕边的距离。
    static let endMargin: CGFloat = 16

    static func rowHeight(screenWidth: CGFloat, screenHeight: CGFloat, capByScreenHeight: Bool) -> CGFloat {
        let byWidth = min(max(screenWidth * rowHeightOfScreenWidth, minRowHeight), maxRowHeight)
        let height = capByScreenHeight ? min(byWidth, screenHeight * maxRowHeightOfScreenHeight) : byWidth
        return height.rounded(.down)
    }

    /// 宽 / 高；拿不到尺寸时返回 `unknownAspectRatio`。
    static func aspectRatio(_ size: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else {
            return unknownAspectRatio
        }
        return size.width / size.height
    }

    /// - Parameters:
    ///   - viewportWidth: 滑动区宽度（整屏宽）
    ///   - startInset: 起点：静止时第一张左边到滑动区起始边的距离
    ///   - endMargin: 滑到底时最后一张右边到滑动区末端的距离
    ///   - spacing: 卡片间距
    ///   - minNextPeek: 最宽的一张也要给下一张留出的宽度
    ///   - rowHeight: 行高
    ///   - aspectRatios: 每张的宽 / 高
    ///   - alignEndWhenFits: 放得下、不用滑时整组贴末端（自己发的相册靠右，C-5）
    static func layout(
        viewportWidth: CGFloat,
        startInset: CGFloat,
        endMargin: CGFloat,
        spacing: CGFloat,
        minNextPeek: CGFloat,
        rowHeight: CGFloat,
        aspectRatios: [CGFloat],
        alignEndWhenFits: Bool,
    ) -> Layout {
        precondition(!aspectRatios.isEmpty, "Album needs at least one item.")

        let minItemWidth = max(1, (rowHeight * minItemAspectRatio).rounded())
        let maxItemWidth = max(minItemWidth, viewportWidth - startInset - spacing - minNextPeek)

        let widths = aspectRatios.map { ratio in
            min(max((rowHeight * ratio).rounded(), minItemWidth), maxItemWidth)
        }

        let itemsSpan = widths.reduce(0, +) + spacing * CGFloat(widths.count - 1)
        let isScrollable = startInset + itemsSpan + endMargin > viewportWidth

        let firstLeft: CGFloat
        if isScrollable {
            firstLeft = startInset
        } else if alignEndWhenFits {
            firstLeft = viewportWidth - endMargin - itemsSpan
        } else {
            firstLeft = startInset
        }

        var lefts = [CGFloat]()
        var x = firstLeft
        for width in widths {
            lefts.append(x)
            x += width + spacing
        }

        let contentWidth = isScrollable ? startInset + itemsSpan + endMargin : viewportWidth
        let maxScroll = max(0, contentWidth - viewportWidth)

        let snapOffsets: [CGFloat]
        if isScrollable {
            snapOffsets = Array(Set(lefts.map { min($0 - startInset, maxScroll) })).sorted()
        } else {
            snapOffsets = [0]
        }

        return Layout(
            viewportWidth: viewportWidth,
            startInset: startInset,
            rowHeight: rowHeight,
            itemLefts: lefts,
            itemWidths: widths,
            contentWidth: contentWidth,
            isScrollable: isScrollable,
            snapOffsets: snapOffsets,
        )
    }

    struct Layout: Equatable {
        let viewportWidth: CGFloat
        let startInset: CGFloat
        let rowHeight: CGFloat
        /// 每张在内容坐标里的左边。
        let itemLefts: [CGFloat]
        let itemWidths: [CGFloat]
        /// 内容总宽（含起点与末端边距）；放得下时等于 `viewportWidth`。
        let contentWidth: CGFloat
        let isScrollable: Bool
        /// 升序的吸附位置（滚动偏移）：某一张的左边对齐起点，最后一个是滑到底。
        let snapOffsets: [CGFloat]

        var itemCount: Int { itemWidths.count }

        var maxScroll: CGFloat { max(0, contentWidth - viewportWidth) }

        func itemFrame(_ index: Int) -> CGRect {
            CGRect(x: itemLefts[index], y: 0, width: itemWidths[index], height: rowHeight)
        }

        /// 让第 `index` 张静止时左边对齐起点的偏移（滑到底为止）。
        func snapOffset(forItem index: Int) -> CGFloat {
            isScrollable ? min(itemLefts[index] - startInset, maxScroll) : 0
        }

        /// C-9：关查看器前先把这一张滚到完整露出。已经整张在屏幕里就不动，否则停到它的吸附位
        /// （吸附位上每一张都整张可见：最宽也只到「屏宽 − 起点 − 间距 − 48」）。
        func offsetRevealingItem(_ index: Int, currentOffset: CGFloat) -> CGFloat {
            guard isScrollable else {
                return 0
            }
            let left = itemLefts[index] - currentOffset
            let right = left + itemWidths[index]
            if left >= 0, right <= viewportWidth {
                return min(max(currentOffset, 0), maxScroll)
            }
            return snapOffset(forItem: index)
        }

        /// C-6：松手后停在哪。慢慢松手（`velocitySign` 为 0）停在离 `projectedOffset` 最近的吸附位；
        /// 甩的时候按甩出去的落点找最近的吸附位（可以一次越过几张），但至少朝甩的方向走一格。
        func targetSnapOffset(currentOffset: CGFloat, projectedOffset: CGFloat, velocitySign: Int) -> CGFloat {
            guard isScrollable, let first = snapOffsets.first, let last = snapOffsets.last else {
                return 0
            }

            let clamped = min(max(projectedOffset, 0), maxScroll)
            var best = first
            for snap in snapOffsets where abs(snap - clamped) < abs(best - clamped) {
                best = snap
            }

            if velocitySign > 0, best <= currentOffset {
                best = snapOffsets.first { $0 > currentOffset } ?? last
            } else if velocitySign < 0, best >= currentOffset {
                best = snapOffsets.last { $0 < currentOffset } ?? first
            }
            return best
        }

        /// 当前偏移下左边最靠近起点的那一张（读屏「第几张」与上下滑切换用）。
        func itemIndex(atOffset offset: CGFloat) -> Int {
            var bestIndex = 0
            var bestDistance = CGFloat.greatestFiniteMagnitude
            for index in itemLefts.indices {
                let distance = abs(snapOffset(forItem: index) - offset)
                if distance < bestDistance {
                    bestDistance = distance
                    bestIndex = index
                }
            }
            return bestIndex
        }
    }
}
