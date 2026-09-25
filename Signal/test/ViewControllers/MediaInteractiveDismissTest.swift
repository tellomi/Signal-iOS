//
// Copyright 2026 Tellomi
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

/// 查看器拖拽关闭的松手判据（tellomi/tellomi 交互审计 A-20）：按「位置 + 速度投射」判断，不再「拖过就关」。
final class MediaInteractiveDismissTest: XCTestCase {

    private func shouldFinish(_ offset: CGPoint, _ velocity: CGPoint) -> Bool {
        MediaInteractiveDismiss.shouldFinishDismissal(offset: offset, velocity: velocity)
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
