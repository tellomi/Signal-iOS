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
/// Tellomi（tellomi/tellomi#1338）：这一页出的是**只读版**（需求第六节 ④：同一份 9 项、一个「知道了」，点了在本机记下 `cb-1`、放开网络）。
/// iPad 转移选择页「转移」推的 `BaseQuickRestoreQRCodeViewController` 也开同样的 socket（每次出现都 reset），同一条规矩（完整同意）。
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

    /// 注册流程续跑到扫码那一步推的就是这个类。截下 `present`，`waitForMessage` 只记次数、一直等（不连网）。
    private final class RegistrationQuickRestoreScreen: RegistrationQuickRestoreQRCodeViewController {
        private(set) var presentedControllers: [UIViewController] = []
        private(set) var waitForMessageCount = 0

        override func present(_ viewControllerToPresent: UIViewController, animated flag: Bool, completion: (() -> Void)? = nil) {
            presentedControllers.append(viewControllerToPresent)
            completion?()
        }

        override func waitForMessage() async throws -> RegistrationProvisioningMessage {
            waitForMessageCount += 1
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
            throw CancellationError()
        }
    }

    private final class RestorePresenterSpy: RegistrationQuickRestoreQRCodePresenter {
        func didReceiveRegistrationMessage(_ message: RegistrationProvisioningMessage) {}
        func cancelChosenRestoreMethod() {}
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
        defaults.removeObject(forKey: "TellomiCrossBorderConsent.linkedDeviceAcknowledgementOnly")
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

    func testQRCodeScreenShowsReadOnlyCrossBorderNoticeAndOpensSocketOnlyAfterAcknowledging() throws {
        XCTAssertFalse(TellomiCrossBorderConsent.hasAgreed, "前提：还没同意跨境")
        let socketManager = SocketManagerSpy()
        let screen = makeQRCodeScreen(socketManager: socketManager)

        screen.loadViewIfNeeded()
        appear(screen)

        XCTAssertEqual(screen.presentedControllers.count, 1, "二维码页出现时要先出跨境告知")
        let notice = try XCTUnwrap(screen.presentedControllers.first as? TellomiCrossBorderNoticeViewController)
        XCTAssertEqual(notice.mode, .linkedDevice, "关联设备出只读版（第六节 ④）")
        disappear(screen)
        XCTAssertEqual(socketManager.startCount, 0, "告知还没点「知道了」，socket 不许开")

        notice.loadViewIfNeeded()
        XCTAssertNil(button(identifier: "tellomi.crossBorder.agree", in: notice.view), "只读版没有「同意并继续」")
        let ackButton = try XCTUnwrap(button(identifier: "tellomi.crossBorder.linkedAck", in: notice.view))
        ackButton.sendActions(for: .primaryActionTriggered)

        XCTAssertTrue(TellomiCrossBorderConsent.hasAgreed, "「知道了」和同意一样记下 cb-1、放开网络")
        XCTAssertEqual(socketManager.startCount, 1, "点了「知道了」之后要开 socket、出二维码")

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
        let notice = screen.presentedControllers.first as? TellomiCrossBorderNoticeViewController
        XCTAssertEqual(notice?.mode, .consent, "「转移」不是「关联设备」这条路，保留完整同意")
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

    // MARK: - 注册流程续跑到扫码那一步（RegistrationQuickRestoreQRCodeViewController）

    /// Tellomi（tellomi/tellomi#1338，需求 6.6）：告知改成 overFullScreen 的小弹窗以后，关掉弹窗时本页不再走 viewDidAppear
    /// （整页 fullScreen 的时候会再走一次，原来就靠那一次开始等消息）。同意之后要直接开始等主设备的消息，不然二维码出来了却永远等不到。
    func testRegistrationQuickRestoreStartsWaitingRightAfterAgreeing() throws {
        XCTAssertFalse(TellomiCrossBorderConsent.hasAgreed, "前提：还没同意跨境")
        let socketManager = SocketManagerSpy()
        let presenter = RestorePresenterSpy()
        let screen = RegistrationQuickRestoreScreen(presenter: presenter, provisioningSocketManager: socketManager)

        screen.loadViewIfNeeded()
        appear(screen)
        XCTAssertEqual(screen.waitForMessageCount, 0, "没同意跨境，不等消息")
        let notice = try XCTUnwrap(screen.presentedControllers.first as? TellomiCrossBorderNoticeViewController)
        XCTAssertEqual(notice.mode, .consent, "恢复 / 转移是主设备，完整同意")

        notice.loadViewIfNeeded()
        let agreeButton = try XCTUnwrap(button(identifier: "tellomi.crossBorder.agree", in: notice.view))
        agreeButton.sendActions(for: .primaryActionTriggered)
        // 不模拟「关掉告知后本页再出现一次」：弹窗是 overFullScreen，真机上也不会有那一次。
        let deadline = Date().addingTimeInterval(3)
        while screen.waitForMessageCount == 0, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        XCTAssertEqual(socketManager.resetCount, 1, "同意之后 reset() 一次：开 socket、出二维码")
        XCTAssertEqual(screen.waitForMessageCount, 1, "同意之后要开始等主设备的消息")
    }

    func testRegistrationQuickRestoreWaitsOnAppearOnceConsented() {
        TellomiCrossBorderConsent.recordAgreement()
        let socketManager = SocketManagerSpy()
        let screen = RegistrationQuickRestoreScreen(presenter: RestorePresenterSpy(), provisioningSocketManager: socketManager)

        screen.loadViewIfNeeded()
        appear(screen)
        let deadline = Date().addingTimeInterval(3)
        while screen.waitForMessageCount == 0, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        XCTAssertTrue(screen.presentedControllers.isEmpty, "同意过就不再出告知")
        XCTAssertEqual(screen.waitForMessageCount, 1, "同意过就照上游：页面一出现就等消息")
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
