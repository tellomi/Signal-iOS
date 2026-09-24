//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

/// tellomi/tellomi#1257：横滑相册几何（需求 C-2…C-6、C-9 与判据 1–3）。单位是 pt，数字可以直接对需求原文。
/// 与 Android `AlbumCarouselGeometryTest.kt` 一一对应；iOS 自己发的气泡列起点是 16 + 32 + 12 = 60（Android 是 48）。
final class AlbumCarouselGeometryTest: XCTestCase {

    func testRowHeightIsScreenWidthTimes0_6ForTheThreeReferencePhones() {
        XCTAssertEqual(AlbumCarouselGeometry.rowHeight(screenWidth: 402, screenHeight: 874, capByScreenHeight: false), 241)
        XCTAssertEqual(AlbumCarouselGeometry.rowHeight(screenWidth: 440, screenHeight: 956, capByScreenHeight: false), 264)
        XCTAssertEqual(AlbumCarouselGeometry.rowHeight(screenWidth: 375, screenHeight: 667, capByScreenHeight: false), 225)
    }

    func testRowHeightIsClampedTo220And300() {
        XCTAssertEqual(AlbumCarouselGeometry.rowHeight(screenWidth: 320, screenHeight: 568, capByScreenHeight: false), 220)
        XCTAssertEqual(AlbumCarouselGeometry.rowHeight(screenWidth: 800, screenHeight: 1280, capByScreenHeight: false), 300)
    }

    func testLandscapeAndIPadAlsoStayUnder40PercentOfScreenHeight() {
        XCTAssertEqual(AlbumCarouselGeometry.rowHeight(screenWidth: 874, screenHeight: 402, capByScreenHeight: true), 160)
        XCTAssertEqual(AlbumCarouselGeometry.rowHeight(screenWidth: 1024, screenHeight: 1366, capByScreenHeight: true), 300)
    }

    func testEachItemKeepsItsAspectRatioWithin9By16AndThePeekLimit() {
        let layout = incoming402([3.0 / 4.0, 16.0 / 9.0, 1.0 / 3.0, 1])

        // 3:4 → 241 × 0.75；16:9 夹到 402 − 16 − 8 − 48 = 330；1:3 夹到 241 × 9/16；1:1 原样
        XCTAssertEqual(layout.itemWidths, [181, 330, 136, 241])
    }

    func testUnknownDimensionsAreLaidOutAsSquares() {
        XCTAssertEqual(AlbumCarouselGeometry.aspectRatio(.zero), 1)
        XCTAssertEqual(AlbumCarouselGeometry.aspectRatio(CGSize(width: 3, height: 4)), 0.75)
    }

    func testAScrollableAlbumStartsAtTheStartInsetAndEnds16FromTheEdge() {
        let layout = incoming402(Array(repeating: 3.0 / 4.0, count: 5))

        XCTAssertTrue(layout.isScrollable)
        XCTAssertEqual(layout.itemLefts, [16, 205, 394, 583, 772])
        XCTAssertEqual(layout.contentWidth, 16 + 5 * 181 + 4 * 8 + 16)
        XCTAssertEqual(layout.maxScroll, layout.contentWidth - 402)

        let lastRightAtEnd = layout.itemLefts.last! + layout.itemWidths.last! - layout.maxScroll
        XCTAssertEqual(lastRightAtEnd, 402 - 16)
    }

    func testSnapOffsetsAlignAnItemsLeftEdgeWithTheStartInsetAndEndAtMaxScroll() {
        let layout = incoming402(Array(repeating: 3.0 / 4.0, count: 5))

        XCTAssertEqual(layout.snapOffsets, [0, 189, 378, 567])
        XCTAssertEqual(layout.maxScroll, 567)
    }

    func testAtEverySnapPositionTheNextItemPeeksAtLeast48() {
        for count in [2, 5, 12, 32] {
            let layout = incoming402((0..<count).map { $0 % 3 == 0 ? 16.0 / 9.0 : 3.0 / 4.0 })
            for index in 0..<(count - 1) {
                let offset = layout.snapOffset(forItem: index)
                let nextLeftOnScreen = layout.itemLefts[index + 1] - offset
                XCTAssertLessThanOrEqual(nextLeftOnScreen, 402 - 48, "count=\(count) item=\(index)")
            }
        }
    }

    func testEveryItemOfA32ItemAlbumCanBeScrolledFullyOnScreen() {
        let layout = incoming402(Array(repeating: 3.0 / 4.0, count: 32))
        for index in 0..<32 {
            let offset = layout.snapOffset(forItem: index)
            let left = layout.itemLefts[index] - offset
            XCTAssertGreaterThanOrEqual(left, 0)
            XCTAssertLessThanOrEqual(left + layout.itemWidths[index], 402)
        }
    }

    func testOutgoingAlbumThatFitsIsRightAlignedAndNotScrollable() {
        // 两张 9:16 竖图：136 + 8 + 136 = 280，自己气泡列起点 60 + 280 + 16 ≤ 402
        let layout = AlbumCarouselGeometry.layout(
            viewportWidth: 402,
            startInset: 60,
            endMargin: 16,
            spacing: 8,
            minNextPeek: 48,
            rowHeight: 241,
            aspectRatios: [9.0 / 16.0, 9.0 / 16.0],
            alignEndWhenFits: true,
        )

        XCTAssertFalse(layout.isScrollable)
        XCTAssertEqual(layout.itemLefts[0], 402 - 16 - 280)
        XCTAssertEqual(layout.itemLefts[1] + layout.itemWidths[1], 402 - 16)
        XCTAssertEqual(layout.snapOffsets, [0])
    }

    func testIncomingAlbumThatFitsStaysAtTheStartInset() {
        let layout = AlbumCarouselGeometry.layout(
            viewportWidth: 402,
            startInset: 16,
            endMargin: 16,
            spacing: 8,
            minNextPeek: 48,
            rowHeight: 241,
            aspectRatios: [9.0 / 16.0, 9.0 / 16.0],
            alignEndWhenFits: false,
        )

        XCTAssertFalse(layout.isScrollable)
        XCTAssertEqual(layout.itemLefts[0], 16)
    }

    func testOutgoingAlbumThatDoesNotFitStartsAtTheOwnBubbleColumn() {
        let layout = AlbumCarouselGeometry.layout(
            viewportWidth: 402,
            startInset: 60,
            endMargin: 16,
            spacing: 8,
            minNextPeek: 48,
            rowHeight: 241,
            aspectRatios: [3.0 / 4.0, 3.0 / 4.0],
            alignEndWhenFits: true,
        )

        XCTAssertTrue(layout.isScrollable)
        XCTAssertEqual(layout.itemLefts[0], 60)
    }

    func testSlowReleaseStopsAtTheNearestSnap() {
        let layout = incoming402(Array(repeating: 3.0 / 4.0, count: 5))

        XCTAssertEqual(layout.targetSnapOffset(currentOffset: 100, projectedOffset: 150, velocitySign: 0), 189)
        XCTAssertEqual(layout.targetSnapOffset(currentOffset: 80, projectedOffset: 80, velocitySign: 0), 0)
    }

    func testAFlingAlwaysMovesAtLeastOneSnapInItsDirection() {
        let layout = incoming402(Array(repeating: 3.0 / 4.0, count: 5))

        XCTAssertEqual(layout.targetSnapOffset(currentOffset: 190, projectedOffset: 195, velocitySign: 1), 378)
        XCTAssertEqual(layout.targetSnapOffset(currentOffset: 200, projectedOffset: 198, velocitySign: -1), 189)
    }

    func testAFastFlingCanPassSeveralItems() {
        let layout = incoming402(Array(repeating: 3.0 / 4.0, count: 5))

        XCTAssertEqual(layout.targetSnapOffset(currentOffset: 10, projectedOffset: 700, velocitySign: 1), 567)
        XCTAssertEqual(layout.targetSnapOffset(currentOffset: 560, projectedOffset: -300, velocitySign: -1), 0)
    }

    func testClosingTheViewerOnAnOffScreenItemScrollsToItsSnap() {
        let layout = incoming402(Array(repeating: 3.0 / 4.0, count: 5))

        XCTAssertEqual(layout.offsetRevealingItem(3, currentOffset: 0), 567)
        XCTAssertEqual(layout.offsetRevealingItem(0, currentOffset: 378), 0)
    }

    func testClosingTheViewerOnAFullyVisibleItemDoesNotMoveTheAlbum() {
        let layout = incoming402(Array(repeating: 3.0 / 4.0, count: 5))

        // 偏移 189 时第 2 张（下标 1）左边在 16、右边在 197：整张在屏幕里
        XCTAssertEqual(layout.offsetRevealingItem(1, currentOffset: 189), 189)
        XCTAssertEqual(layout.offsetRevealingItem(1, currentOffset: 0), 0)
    }

    func testItemIndexAtOffsetFollowsTheSnaps() {
        let layout = incoming402(Array(repeating: 3.0 / 4.0, count: 5))

        XCTAssertEqual(layout.itemIndex(atOffset: 0), 0)
        XCTAssertEqual(layout.itemIndex(atOffset: 189), 1)
        XCTAssertEqual(layout.itemIndex(atOffset: 370), 2)
    }

    private func incoming402(_ aspects: [CGFloat]) -> AlbumCarouselGeometry.Layout {
        AlbumCarouselGeometry.layout(
            viewportWidth: 402,
            startInset: 16,
            endMargin: 16,
            spacing: 8,
            minNextPeek: 48,
            rowHeight: 241,
            aspectRatios: aspects,
            alignEndWhenFits: false,
        )
    }
}
