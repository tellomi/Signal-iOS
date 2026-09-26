//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit

/// Tellomi（tellomi/tellomi#1133）：关联设备在二维码页开 provisioning socket——libsignal 直连服务端，
/// 不经过 `OWSChatConnection`、`OWSURLSession` 这两道跨境闸。iPad 未注册启动、`.relinking`、
/// 号码页「关联此设备」三条路都不经过注册欢迎页，最后都到这一页，所以跨境告知要在这一页出：
/// 没同意不开 socket；页面出现时先出告知；同意之后再开。
/// iPad 转移选择页「转移」推的 `BaseQuickRestoreQRCodeViewController` 也开同样的 socket（每次出现都 reset），同一条规矩。
@MainActor
final class TellomiProvisioningCrossBorderConsentTest: SignalBaseTest {

    /// 只数 `start()` / `reset()`，不连网。
    private final class SocketManagerSpy: ProvisioningSocketManager {
        private(set) var startCount = 0
        private(set) var resetCount = 0

        init() {
            super.init(linkType: .linkDevice)
        }

        override func start() {
            startCount += 1
        }

        override func reset() {
            resetCount += 1
            super.reset()
        }
    }

    /// 把 `present` 截下来：不要真窗口，也不等转场动画。
    private final class QRCodeScreen: ProvisioningQRCodeViewController {
        private(set) var presentedControllers: [UIViewController] = []

        override func present(_ viewControllerToPresent: UIViewController, animated flag: Bool, completion: (() -> Void)? = nil) {
            presentedControllers.append(viewControllerToPresent)
            completion?()
        }
    }

    /// iPad「转移」页：`ProvisioningController.transferAccount` 推的就是这个类本身。同样截下 `present`。
    private final class QuickRestoreScreen: BaseQuickRestoreQRCodeViewController {
        private(set) var presentedControllers: [UIViewController] = []

        override func present(_ viewControllerToPresent: UIViewController, animated flag: Bool, completion: (() -> Void)? = nil) {
            presentedControllers.append(viewControllerToPresent)
            completion?()
        }
    }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        forgetCrossBorderConsent()
    }

    override func tearDown() {
        forgetCrossBorderConsent()
        super.tearDown()
    }

    // MARK: - Helpers

    /// `TellomiCrossBorderConsent` 记在 `appUserDefaults()` 里的两个键（`AppExpiry.swift` 末尾）。
    private func forgetCrossBorderConsent() {
        let defaults = CurrentAppContext().appUserDefaults()
        defaults.removeObject(forKey: "TellomiCrossBorderConsent.version")
        defaults.removeObject(forKey: "TellomiCrossBorderConsent.date")
    }

    private func makeQRCodeScreen(socketManager: SocketManagerSpy) -> QRCodeScreen {
        return QRCodeScreen(
            provisioningController: .preview(),
            provisioningSocketManager: socketManager,
        )
    }

    private func appear(_ viewController: UIViewController) {
        viewController.beginAppearanceTransition(true, animated: false)
        viewController.endAppearanceTransition()
    }

    /// 全屏告知盖住二维码页时，二维码页会走一遍消失。
    private func disappear(_ viewController: UIViewController) {
        viewController.beginAppearanceTransition(false, animated: false)
        viewController.endAppearanceTransition()
    }

    private func button(identifier: String, in view: UIView) -> UIButton? {
        if let button = view as? UIButton, button.accessibilityIdentifier == identifier {
            return button
        }
        for subview in view.subviews {
            if let found = button(identifier: identifier, in: subview) {
                return found
            }
        }
        return nil
    }

    // MARK: - Tests

    func testQRCodeScreenDoesNotOpenProvisioningSocketBeforeCrossBorderConsent() {
        XCTAssertFalse(TellomiCrossBorderConsent.hasAgreed, "前提：还没同意跨境")
        let socketManager = SocketManagerSpy()
        let screen = makeQRCodeScreen(socketManager: socketManager)

        screen.loadViewIfNeeded()
        appear(screen)

        XCTAssertEqual(
            socketManager.startCount,
            0,
            "没同意跨境就开了 provisioning socket：libsignal 直连服务端，两道闸都不经过",
        )
    }

    func testQRCodeScreenShowsCrossBorderNoticeAndOpensSocketOnlyAfterAgreeing() throws {
        XCTAssertFalse(TellomiCrossBorderConsent.hasAgreed, "前提：还没同意跨境")
        let socketManager = SocketManagerSpy()
        let screen = makeQRCodeScreen(socketManager: socketManager)

        screen.loadViewIfNeeded()
        appear(screen)

        XCTAssertEqual(screen.presentedControllers.count, 1, "二维码页出现时要先出跨境告知")
        let notice = try XCTUnwrap(screen.presentedControllers.first as? TellomiCrossBorderNoticeViewController)
        disappear(screen)
        XCTAssertEqual(socketManager.startCount, 0, "告知还没同意，socket 不许开")

        notice.loadViewIfNeeded()
        let agreeButton = try XCTUnwrap(button(identifier: "tellomi.crossBorder.agree", in: notice.view))
        agreeButton.sendActions(for: .primaryActionTriggered)

        XCTAssertTrue(TellomiCrossBorderConsent.hasAgreed)
        XCTAssertEqual(socketManager.startCount, 1, "同意之后要开 socket、出二维码")

        // 告知关掉后二维码页再出现一次：不许再弹告知，也不多开 socket。
        appear(screen)
        XCTAssertEqual(screen.presentedControllers.count, 1)
        XCTAssertEqual(socketManager.startCount, 1)
    }

    func testQRCodeScreenOpensProvisioningSocketRightAwayOnceConsented() {
        TellomiCrossBorderConsent.recordAgreement()
        XCTAssertTrue(TellomiCrossBorderConsent.hasAgreed, "前提：已经同意跨境")
        let socketManager = SocketManagerSpy()
        let screen = makeQRCodeScreen(socketManager: socketManager)

        screen.loadViewIfNeeded()
        appear(screen)

        XCTAssertEqual(socketManager.startCount, 1, "同意过就照上游直接开 socket")
        XCTAssertTrue(screen.presentedControllers.isEmpty, "同意过就不再出告知")
    }

    // MARK: - iPad「转移」页（BaseQuickRestoreQRCodeViewController）

    func testQuickRestoreScreenShowsCrossBorderNoticeInsteadOfResettingSocketBeforeConsent() {
        XCTAssertFalse(TellomiCrossBorderConsent.hasAgreed, "前提：还没同意跨境")
        let socketManager = SocketManagerSpy()
        let screen = QuickRestoreScreen(provisioningSocketManager: socketManager)

        screen.loadViewIfNeeded()
        appear(screen)

        XCTAssertEqual(socketManager.resetCount, 0, "没同意跨境，iPad「转移」页一出现就 reset() 了")
        XCTAssertEqual(socketManager.startCount, 0, "没同意跨境就开了 provisioning socket")
        XCTAssertEqual(screen.presentedControllers.count, 1, "iPad「转移」页出现时要先出跨境告知")
        XCTAssertTrue(screen.presentedControllers.first is TellomiCrossBorderNoticeViewController)
    }

    /// 真机上告知是全屏的，关掉时本页还会再走一次 viewDidAppear（照上游每次出现都 reset）；这里截了 present，只看 onAgree 这一次。
    func testQuickRestoreScreenResetsSocketOnceAfterAgreeing() throws {
        XCTAssertFalse(TellomiCrossBorderConsent.hasAgreed, "前提：还没同意跨境")
        let socketManager = SocketManagerSpy()
        let screen = QuickRestoreScreen(provisioningSocketManager: socketManager)

        screen.loadViewIfNeeded()
        appear(screen)
        let notice = try XCTUnwrap(
            screen.presentedControllers.first as? TellomiCrossBorderNoticeViewController,
            "iPad「转移」页出现时要先出跨境告知",
        )
        disappear(screen)
        XCTAssertEqual(socketManager.resetCount, 0, "告知还没同意，不许 reset()")

        notice.loadViewIfNeeded()
        let agreeButton = try XCTUnwrap(button(identifier: "tellomi.crossBorder.agree", in: notice.view))
        agreeButton.sendActions(for: .primaryActionTriggered)

        XCTAssertTrue(TellomiCrossBorderConsent.hasAgreed)
        XCTAssertEqual(socketManager.resetCount, 1, "同意之后 reset() 一次：开 socket、出二维码")
        XCTAssertEqual(socketManager.startCount, 1)
        XCTAssertEqual(screen.presentedControllers.count, 1, "同意之后不再弹告知")
    }

    func testQuickRestoreScreenResetsSocketOnAppearOnceConsented() {
        TellomiCrossBorderConsent.recordAgreement()
        XCTAssertTrue(TellomiCrossBorderConsent.hasAgreed, "前提：已经同意跨境")
        let socketManager = SocketManagerSpy()
        let screen = QuickRestoreScreen(provisioningSocketManager: socketManager)

        screen.loadViewIfNeeded()
        appear(screen)

        XCTAssertEqual(socketManager.resetCount, 1, "同意过就照上游：页面一出现就 reset()")
        XCTAssertTrue(screen.presentedControllers.isEmpty, "同意过就不再出告知")
    }
}
