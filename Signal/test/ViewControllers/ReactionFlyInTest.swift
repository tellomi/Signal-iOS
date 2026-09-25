//
// Copyright 2026 Tellomi
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalUI
import XCTest

@testable import Signal

@MainActor
final class ReactionFlyInTest: XCTestCase {

    // MARK: - 缩放

    /// 回应条上 32 pt 的表情飞到胶囊里 14 pt 的表情：先缩到 14 / 32，再多留 1.25 倍给落定的回弹。
    func testLandingScaleShrinksToThePillAndLeavesRoomForTheBounce() {
        XCTAssertEqual(ReactionFlyIn.landingScale(sourceFontSize: 32, targetFontSize: 14), 14.0 / 32.0 * 1.25, accuracy: 1e-9)
        XCTAssertEqual(ReactionFlyIn.landingScale(sourceFontSize: 0, targetFontSize: 14), 1)
    }

    // MARK: - 纵向初速

    /// 目标在下方且足够远：向上抛（相对速度为负）。
    func testTossesUpwardWhenTheTargetIsBelow() {
        let velocity = ReactionFlyIn.verticalInitialVelocity(verticalDistance: 200)
        XCTAssertEqual(velocity.dx, 0)
        XCTAssertEqual(velocity.dy, -ReactionFlyIn.tossSpeed / 200, accuracy: 1e-9)
    }

    /// 目标在上方或几乎平齐：不抛，免得冲过头或原地上下抖。
    func testDoesNotTossWhenTheTargetIsAboveOrLevel() {
        XCTAssertEqual(ReactionFlyIn.verticalInitialVelocity(verticalDistance: -150), .zero)
        XCTAssertEqual(ReactionFlyIn.verticalInitialVelocity(verticalDistance: 10), .zero)
    }

    // MARK: - 路线形状（用真实的 Token 数值做弹簧积分）

    /// 横向偏开的落点：路线要明显弯（离直线最远处 ≥ 12 pt），最后落在目标上。
    func testPathArcsAndEndsOnTheTarget() {
        let path = simulatePath(dx: 160, dy: 120)
        XCTAssertGreaterThanOrEqual(path.maxDeviationFromStraightLine, 12)
        XCTAssertLessThan(hypot(path.end.x - 160, path.end.y - 120), 0.5)
    }

    /// 正下方的落点：先轻轻抬起一点（2–20 pt），不是原地一跳。
    func testStraightDropLiftsGentlyFirst() {
        let path = simulatePath(dx: 0, dy: 150)
        XCTAssertGreaterThanOrEqual(path.lift, 2)
        XCTAssertLessThanOrEqual(path.lift, 20)
    }

    // MARK: -

    private struct Path {
        var maxDeviationFromStraightLine: CGFloat = 0
        var lift: CGFloat = 0
        var end: CGPoint = .zero
    }

    /// 起点在原点、目标在 (dx, dy)（y 向下）。弹簧和初速都取 [ReactionFlyIn] 里 land 用的那一份。
    private func simulatePath(dx: CGFloat, dy: CGFloat) -> Path {
        let horizontalSpring = ReactionFlyIn.horizontalSpring
        let verticalSpring = ReactionFlyIn.verticalSpring
        // UIKit 的相对初速 × 距离 = 点 / 秒。
        let verticalSpeed = ReactionFlyIn.verticalInitialVelocity(verticalDistance: dy).dy * dy

        var x = Axis(position: 0, velocity: 0, target: dx, spring: horizontalSpring)
        var y = Axis(position: 0, velocity: verticalSpeed, target: dy, spring: verticalSpring)
        var path = Path()
        let length = hypot(dx, dy)
        let step = 1.0 / 2000
        for _ in 0..<(2000 * 2) {
            x.advance(by: step)
            y.advance(by: step)
            if length > 0 {
                let deviation = abs(x.position * dy - y.position * dx) / length
                path.maxDeviationFromStraightLine = max(path.maxDeviationFromStraightLine, deviation)
            }
            path.lift = max(path.lift, -y.position)
        }
        path.end = CGPoint(x: x.position, y: y.position)
        return path
    }

    /// 质量 1 的阻尼弹簧，半隐式欧拉积分。
    private struct Axis {
        var position: CGFloat
        var velocity: CGFloat
        let target: CGFloat
        let spring: TellomiMotion.Spring

        mutating func advance(by dt: CGFloat) {
            let acceleration = -spring.stiffness * (position - target) - spring.damping * velocity
            velocity += acceleration * dt
            position += velocity * dt
        }
    }
}
