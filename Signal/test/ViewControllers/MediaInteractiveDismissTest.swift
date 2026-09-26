//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import XCTest

@testable import Signal

/// 查看器拖拽关闭的松手判据（tellomi/tellomi 交互审计 A-20）：按「位置 + 速度投射」判断，不再「拖过就关」。
final class MediaInteractiveDismissTest: XCTestCase {

    private func shouldFinish(_ offset: CGPoint, _ velocity: CGPoint, peak: CGPoint? = nil) -> Bool {
        MediaInteractiveDismiss.shouldFinishDismissal(offset: offset, velocity: velocity, peakOffset: peak)
    }

    func testNoMovementNeverDismisses() {
        XCTAssertFalse(shouldFinish(.zero, .zero))
        XCTAssertFalse(shouldFinish(.zero, CGPoint(x: 0, y: 2000)))
    }

    /// 原来的毛病：拖下去再拖回来，只要偏离过起点就关。现在拖回原处附近就弹回。
    func testDraggingBackNearTheStartCancels() {
        XCTAssertFalse(shouldFinish(CGPoint(x: 0, y: 10), CGPoint(x: 0, y: -50)))
        XCTAssertFalse(shouldFinish(CGPoint(x: 3, y: 4), .zero))
    }

    func testDraggingFarEnoughDismisses() {
        XCTAssertTrue(shouldFinish(CGPoint(x: 0, y: 100), .zero))
        XCTAssertTrue(shouldFinish(CGPoint(x: 0, y: -60), .zero))
        XCTAssertTrue(shouldFinish(CGPoint(x: 50, y: 0), .zero))
    }

    /// 快速一甩也算数：距离很短，但沿拖动方向往外甩得够快。
    func testAFastFlickDismissesEvenAfterAShortDrag() {
        XCTAssertTrue(shouldFinish(CGPoint(x: 0, y: 10), CGPoint(x: 0, y: 1200)))
    }

    /// 走查模拟器实测抓到的：往下拖出去 80 pt 再拖回来，越过起点 12 pt 时手指还带着约 330 pt/s 的向上速度。
    /// 「往外」要按这次拖动最远的那一侧（向下）算，这股回拉是往回，不能被当成「往上甩」而关掉。
    func testReturningPastTheStartWithUpwardSpeedCancels() {
        XCTAssertFalse(shouldFinish(CGPoint(x: 0, y: -12), CGPoint(x: 0, y: -330), peak: CGPoint(x: 0, y: 80)))
        XCTAssertFalse(shouldFinish(CGPoint(x: 0, y: -12), CGPoint(x: 0, y: -250), peak: CGPoint(x: 0, y: 80)))
    }

    /// 真往上拖得够远（最远的一侧就是上方）照样能关。
    func testDraggingUpAsTheFarthestSideStillDismisses() {
        XCTAssertTrue(shouldFinish(CGPoint(x: 0, y: -100), .zero, peak: CGPoint(x: 0, y: -100)))
    }

    /// 往回甩就弹回，哪怕已经拖得挺远。
    func testFlingingBackCancelsEvenAfterALongDrag() {
        XCTAssertFalse(shouldFinish(CGPoint(x: 0, y: 60), CGPoint(x: 0, y: -400)))
    }

    /// 中间地带看投射落点：30 pt + 200 pt/s × 0.099 s ≈ 50 pt ≥ 44 pt → 关；20 pt + 100 pt/s → 约 30 pt → 弹回。
    func testTheProjectedLandingPointDecidesTheMiddleGround() {
        XCTAssertTrue(shouldFinish(CGPoint(x: 0, y: 30), CGPoint(x: 0, y: 200)))
        XCTAssertFalse(shouldFinish(CGPoint(x: 0, y: 20), CGPoint(x: 0, y: 100)))
    }
}

/// 查看器关掉时的收尾（tellomi/tellomi 交互审计 A-20）：落点、裁剪区域、拖动时的阴影。
final class MediaDismissAnimationControllerTest: XCTestCase {

    private let container = CGRect(x: 0, y: 0, width: 390, height: 844)

    /// 从查看器（没有裁剪）回到会话页（上面让出状态栏 + 导航栏）：图要落在缩略图上，不能低一个导航栏的高度。
    func testLandingIsMeasuredInTheDestinationClippingArea() {
        let thumbnail = CGRect(x: 200, y: 300, width: 100, height: 100)
        let target = MediaDismissAnimationController.targetClippingFrame(
            containerBounds: container,
            currentClippingFrame: container,
            isFinishing: true,
            toClippingAreaInsets: UIEdgeInsets(top: 100, left: 0, bottom: 80, right: 0),
        )
        XCTAssertEqual(target, CGRect(x: 0, y: 100, width: 390, height: 664))

        let landing = MediaDismissAnimationController.landingFrame(destinationFrame: thumbnail, targetClippingFrame: target)
        XCTAssertEqual(landing, CGRect(x: 200, y: 200, width: 100, height: 100))
        // 屏幕上的位置 = 裁剪区域的位置 + 在裁剪区域里的位置 = 缩略图
        XCTAssertEqual(landing.offsetBy(dx: target.minX, dy: target.minY), thumbnail)
    }

    /// 弹回时裁剪区域不动；关掉但目标页没有裁剪时，裁剪区域是整个容器。
    func testClippingAreaStaysWhenCancellingAndFillsTheContainerWithoutInsets() {
        let current = CGRect(x: 0, y: 50, width: 390, height: 744)
        XCTAssertEqual(
            MediaDismissAnimationController.targetClippingFrame(
                containerBounds: container,
                currentClippingFrame: current,
                isFinishing: false,
                toClippingAreaInsets: UIEdgeInsets(top: 100, left: 0, bottom: 0, right: 0),
            ),
            current,
        )
        XCTAssertEqual(
            MediaDismissAnimationController.targetClippingFrame(
                containerBounds: container,
                currentClippingFrame: current,
                isFinishing: true,
                toClippingAreaInsets: nil,
            ),
            container,
        )
    }

    /// 拖动时的阴影跟媒体一个形状：头像是圆的，阴影的四个角是空的；矩形照圆角；各角不一样圆的不给路径。
    func testDragShadowFollowsTheMediaShape() throws {
        let square = CGRect(x: 0, y: 0, width: 200, height: 200)

        let circle = try XCTUnwrap(MediaDismissAnimationController.dragShadowPath(for: .circle, in: square))
        XCTAssertFalse(circle.contains(CGPoint(x: 5, y: 5)))
        XCTAssertTrue(circle.contains(CGPoint(x: 100, y: 3)))
        XCTAssertTrue(circle.contains(CGPoint(x: 100, y: 100)))

        let sharp = try XCTUnwrap(MediaDismissAnimationController.dragShadowPath(for: .rectangle(0), in: square))
        XCTAssertTrue(sharp.contains(CGPoint(x: 1, y: 1)))

        let rounded = try XCTUnwrap(MediaDismissAnimationController.dragShadowPath(for: .rectangle(20), in: square))
        XCTAssertFalse(rounded.contains(CGPoint(x: 1, y: 1)))
        XCTAssertTrue(rounded.contains(CGPoint(x: 20, y: 20)))

        XCTAssertNil(MediaDismissAnimationController.dragShadowPath(for: .variableRoundedCorners(.all(12)), in: square))
    }
}
