//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// 交互审计 A-19（iOS 半边）：点会话顶栏进设置时，小头像沿着推入动画飞到设置页的大头像上。
final class TellomiAvatarHeroTests: SignalBaseTest {

    private final class Page: UIViewController {
        let avatar: ConversationAvatarView
        private let diameter: UInt
        private let origin: CGPoint

        init(diameter: UInt, origin: CGPoint) {
            self.diameter = diameter
            self.origin = origin
            self.avatar = ConversationAvatarView(sizeClass: .customDiameter(diameter), localUserDisplayMode: .asUser)
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .systemBackground
            view.addSubview(avatar)
            avatar.autoPinEdge(toSuperviewEdge: .leading, withInset: origin.x)
            avatar.autoPinEdge(toSuperviewEdge: .top, withInset: origin.y)
        }
    }

    private struct Host {
        let window: UIWindow
        let navigation: UINavigationController
        let chat: Page
    }

    @MainActor
    private func makeHost() throws -> Host {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let chat = Page(diameter: 36, origin: CGPoint(x: 60, y: 70))
        let navigation = UINavigationController(rootViewController: chat)
        window.rootViewController = navigation
        window.isHidden = false
        window.layoutIfNeeded()
        return Host(window: window, navigation: navigation, chat: chat)
    }

    @MainActor
    func testTheSmallAvatarFliesOntoTheBigOneAndHandsOver() throws {
        let host = try makeHost()
        defer { host.window.isHidden = true }
        let settings = Page(diameter: 112, origin: CGPoint(x: 145, y: 160))

        host.navigation.pushViewController(settings, animated: true)
        let coordinator = try XCTUnwrap(host.navigation.transitionCoordinator)
        let flyer = try XCTUnwrap(TellomiAvatarHero.flyAlongPush(from: host.chat.avatar, coordinator: coordinator, reduceMotion: false) { settings.avatar })

        XCTAssertTrue(flyer.superview === host.window, "飞的那张在窗口上")
        XCTAssertEqual(host.chat.avatar.alpha, 0, "顶栏原来的小头像先藏起来")
        XCTAssertEqual(flyer.frame.size.width, 36, accuracy: 0.5, "从小头像的大小起飞")

        let landed = expectation(description: "推完")
        coordinator.animate(alongsideTransition: nil) { _ in
            let target = settings.avatar.convert(settings.avatar.bounds, to: host.window)
            XCTAssertEqual(flyer.frame.origin.x, target.origin.x, accuracy: 0.5, "落在设置页大头像的位置")
            XCTAssertEqual(flyer.frame.origin.y, target.origin.y, accuracy: 0.5)
            XCTAssertEqual(flyer.frame.size.width, 112, accuracy: 0.5, "放大到大头像的大小")
            XCTAssertEqual(settings.avatar.alpha, 1, "推完真头像显出来")
            XCTAssertEqual(host.chat.avatar.alpha, 1, "小头像放回去（返回时照常在）")
            landed.fulfill()
        }
        wait(for: [landed], timeout: 3)

        let removed = expectation(description: "淡掉后拿掉")
        DispatchQueue.main.asyncAfter(deadline: .now() + TellomiAvatarHero.revealDuration + 0.3) {
            XCTAssertNil(flyer.superview)
            removed.fulfill()
        }
        wait(for: [removed], timeout: 3)
    }

    @MainActor
    func testNothingFliesWithReduceMotionOrWithoutAnAnimatedPush() throws {
        let host = try makeHost()
        defer { host.window.isHidden = true }
        let settings = Page(diameter: 112, origin: CGPoint(x: 145, y: 160))

        let windowSubviews = host.window.subviews.count
        XCTAssertNil(TellomiAvatarHero.flyAlongPush(from: host.chat.avatar, coordinator: nil, reduceMotion: false) { settings.avatar }, "没有推入动画")

        host.navigation.pushViewController(settings, animated: true)
        let coordinator = try XCTUnwrap(host.navigation.transitionCoordinator)
        XCTAssertNil(TellomiAvatarHero.flyAlongPush(from: host.chat.avatar, coordinator: coordinator, reduceMotion: true) { settings.avatar }, "减弱动态效果")
        XCTAssertEqual(host.chat.avatar.alpha, 1, "什么都不改")
        XCTAssertEqual(host.window.subviews.count, windowSubviews, "窗口上没加东西")

        let done = expectation(description: "推完")
        coordinator.animate(alongsideTransition: nil) { _ in done.fulfill() }
        wait(for: [done], timeout: 3)
    }

    @MainActor
    func testWithoutABigAvatarTheFlyerFadesAway() throws {
        let host = try makeHost()
        defer { host.window.isHidden = true }
        let settings = UIViewController()

        host.navigation.pushViewController(settings, animated: true)
        let coordinator = try XCTUnwrap(host.navigation.transitionCoordinator)
        let flyer = try XCTUnwrap(TellomiAvatarHero.flyAlongPush(from: host.chat.avatar, coordinator: coordinator, reduceMotion: false) { nil })

        let done = expectation(description: "推完")
        coordinator.animate(alongsideTransition: nil) { _ in
            XCTAssertEqual(flyer.alpha, 0, "找不到大头像：跟着推入淡掉")
            XCTAssertEqual(host.chat.avatar.alpha, 1)
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
    }
}
