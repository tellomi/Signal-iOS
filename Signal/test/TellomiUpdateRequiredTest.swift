//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// Tellomi（tellomi/tellomi#1139）：「必须更新」阻断页，按 owner 2026-09-24 的三条规则盖或不盖。
@MainActor
final class TellomiUpdateRequiredTest: SignalBaseTest {

    // MARK: - When to block

    private let ourAppStoreListing = URL(string: "https://apps.apple.com/app/tellomi/id1234567890")!

    private func shouldBlock(
        _ appExpiry: AppExpiry,
        isTellomiDeployment: Bool = true,
        hasUpdateChannel: Bool = true,
        viewChatsOnlyChosen: Bool = false,
    ) -> Bool {
        TellomiUpdateRequiredMonitoringManager.shouldBlock(
            appExpiry: appExpiry,
            now: Date(),
            isTellomiDeployment: isTellomiDeployment,
            hasUpdateChannel: hasUpdateChannel,
            viewChatsOnlyChosen: viewChatsOnlyChosen,
        )
    }

    private func serverRejectedAppExpiry() async -> AppExpiry {
        let appExpiry = AppExpiry.forUnitTests(buildDate: Date())
        // 服务端回 499 时走的就是这一步（AppExpiry.appExpiredStatusCode）。
        await appExpiry.setHasAppExpiredAtCurrentVersion(db: InMemoryDB())
        return appExpiry
    }

    func testACurrentVersionIsNotBlocked() {
        XCTAssertFalse(shouldBlock(AppExpiry.forUnitTests(buildDate: Date())))
    }

    func testAVersionTheServerTurnedAwayIsBlocked() async {
        let appExpiry = await serverRejectedAppExpiry()
        XCTAssertTrue(shouldBlock(appExpiry))
    }

    func testABuildPastItsLifespanOnlyBecomesReadOnly() {
        // 规则 2：本机构建到期不盖，留给上游的只读（会话列表提示 + 输入框换成「更新」）。
        let buildDate = Date().addingTimeInterval(-AppExpiry.defaultExpirationInterval - .day)
        let appExpiry = AppExpiry.forUnitTests(buildDate: buildDate)
        XCTAssertTrue(appExpiry.isExpired(now: Date()))
        XCTAssertFalse(shouldBlock(appExpiry))
    }

    func testWithoutAnUpdateChannelTheAppGoesStraightToReadOnly() async {
        // 规则 3：没有可用的更新渠道时不盖，按钮无处可去。
        let appExpiry = await serverRejectedAppExpiry()
        XCTAssertFalse(shouldBlock(appExpiry, hasUpdateChannel: false))
    }

    func testChoosingToOnlyViewChatsStopsTheBlock() async {
        // 规则 1。
        let appExpiry = await serverRejectedAppExpiry()
        XCTAssertFalse(shouldBlock(appExpiry, viewChatsOnlyChosen: true))
    }

    func testTheSignalDeploymentKeepsTheUpstreamBehavior() async {
        let appExpiry = await serverRejectedAppExpiry()
        XCTAssertFalse(shouldBlock(appExpiry, isTellomiDeployment: false))
    }

    // MARK: - Update channel

    func testOnlyTheChannelWeConfiguredCountsAsAnUpdateChannel() {
        // taishi 审查 b15 启用前置 4：只认我们配的那一条（owner 2026-09-25：TestFlight 外部测试的公开链接），
        // 不再「App Store / TestFlight 的地址、只要不是 Signal 的都算」。
        let ourTestFlight = URL(string: "https://testflight.apple.com/join/AbCdEfGh")!
        func hasUpdateChannel(_ url: String, ourChannel: URL?) -> Bool {
            TellomiUpdateRequiredMonitoringManager.hasUpdateChannel(appStoreUrl: URL(string: url)!, ourChannel: ourChannel)
        }

        // 还没配渠道：什么都不算，iOS 不盖阻断页，只降成只读。
        XCTAssertFalse(hasUpdateChannel("https://testflight.apple.com/join/AbCdEfGh", ourChannel: nil))
        XCTAssertFalse(hasUpdateChannel(ourAppStoreListing.absoluteString, ourChannel: nil))

        // 配了：只有那一条算。
        XCTAssertTrue(hasUpdateChannel("https://testflight.apple.com/join/AbCdEfGh", ourChannel: ourTestFlight))
        XCTAssertFalse(hasUpdateChannel("https://testflight.apple.com/join/SomeoneElse", ourChannel: ourTestFlight))
        XCTAssertFalse(hasUpdateChannel("https://apps.apple.com/app/some-other-app/id1111111111", ourChannel: ourTestFlight))
        XCTAssertFalse(hasUpdateChannel("https://itunes.apple.com/us/app/signal-private-messenger/id874139669?mt=8", ourChannel: ourTestFlight))
        XCTAssertFalse(hasUpdateChannel("https://tellomi.app/download/", ourChannel: ourTestFlight))

        // 以后上架：App Store 条目同样照这个规则配。
        XCTAssertTrue(hasUpdateChannel(ourAppStoreListing.absoluteString, ourChannel: ourAppStoreListing))
    }

    func testViewChatsOnlyFromThePageUnblocksThisVersion() async throws {
        // taishi 审查 b15 启用前置 2：「暂不更新，只看聊天记录」从页面的确认一路接到「不再盖」、记下这个版本。
        // 走的是 WindowManager 里真的接线（makeUpdateRequiredBlockingViewController）和真的 MonitoringManager，只把窗口换成假的。
        let suiteName = "TellomiUpdateRequiredTest-\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let ourTestFlight = URL(string: "https://testflight.apple.com/join/AbCdEfGh")!
        let host = FakeUpdateRequiredBlockHost()
        let manager = TellomiUpdateRequiredMonitoringManager(
            appExpiry: await serverRejectedAppExpiry(),
            windowManager: host,
            userDefaults: userDefaults,
            isTellomiDeployment: true,
            appStoreUrl: ourTestFlight,
            updateChannelUrl: ourTestFlight,
            currentAppVersion: "0.1.2.3",
        )
        manager.start()
        XCTAssertTrue(host.isUpdateRequiredBlockActive, "the server turned this version away and there is a channel: the page covers the app")

        let page = WindowManager.makeUpdateRequiredBlockingViewController(host: host)
        page.confirmViewChatsOnly()

        XCTAssertFalse(host.isUpdateRequiredBlockActive)
        XCTAssertTrue(TellomiUpdateRequiredMonitoringManager.viewChatsOnlyChosen(userDefaults: userDefaults, currentAppVersion: "0.1.2.3"))
        withExtendedLifetime(manager) {}
    }

    func testTheAppLockDoesNotPromptOverTheUpdatePage() {
        // taishi 审查 b15 启用前置 3：阻断页盖着时不自动弹 Face ID / 密码框；收起后照常弹。
        XCTAssertTrue(ScreenLockUI.shouldPresentAuthUI(desiredUIState: .screenLock, didLastUnlockAttemptFail: false, isUpdateRequiredBlockActive: false))
        XCTAssertFalse(ScreenLockUI.shouldPresentAuthUI(desiredUIState: .screenLock, didLastUnlockAttemptFail: false, isUpdateRequiredBlockActive: true))
        XCTAssertFalse(ScreenLockUI.shouldPresentAuthUI(desiredUIState: .screenLock, didLastUnlockAttemptFail: true, isUpdateRequiredBlockActive: false))
        XCTAssertFalse(ScreenLockUI.shouldPresentAuthUI(desiredUIState: .none, didLastUnlockAttemptFail: false, isUpdateRequiredBlockActive: false))
    }

    // MARK: - "Not now, just view my chats"

    func testTheChoiceIsRememberedForThisVersionOnly() {
        let suiteName = "TellomiUpdateRequiredTest-\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(TellomiUpdateRequiredMonitoringManager.viewChatsOnlyChosen(userDefaults: userDefaults, currentAppVersion: "0.1.2.3"))

        TellomiUpdateRequiredMonitoringManager.recordViewChatsOnly(userDefaults: userDefaults, currentAppVersion: "0.1.2.3")

        XCTAssertTrue(TellomiUpdateRequiredMonitoringManager.viewChatsOnlyChosen(userDefaults: userDefaults, currentAppVersion: "0.1.2.3"))
        // 装上新版本，这个选择作废。
        XCTAssertFalse(TellomiUpdateRequiredMonitoringManager.viewChatsOnlyChosen(userDefaults: userDefaults, currentAppVersion: "0.1.3.0"))
    }

    // MARK: - The page

    private func labelTexts(in view: UIView) -> [String] {
        var result: [String] = []
        if let label = view as? UILabel, let text = label.text {
            result.append(text)
        }
        for subview in view.subviews {
            result += labelTexts(in: subview)
        }
        return result
    }

    private func buttons(in view: UIView) -> [UIButton] {
        var result: [UIButton] = []
        if let button = view as? UIButton {
            result.append(button)
        }
        for subview in view.subviews {
            result += buttons(in: subview)
        }
        return result
    }

    func testThePageOffersUpdatingOrOnlyViewingTheChats() {
        // 期望文案带上和页面代码一样的 value:。不带的话，模拟器语言不是四种之一时，期望值会变成键名，
        // 而页面显示的是英文，用例假红（taishi 审查 b15 包 8 不阻塞 5）。
        var opened = 0
        let viewController = TellomiUpdateRequiredAppBlockingViewController(openUpdatePage: { opened += 1 }, viewChatsOnly: {})
        viewController.loadViewIfNeeded()

        let shown = labelTexts(in: viewController.view).joined(separator: "\n")
        XCTAssertTrue(shown.contains(OWSLocalizedString("APP_EXPIRED_TELLOMI_BLOCKING_TITLE", value: "Update Tellomi to continue", comment: "")), shown)
        XCTAssertTrue(shown.contains(OWSLocalizedString("APP_EXPIRED_TELLOMI_BLOCKING_REASON_SERVER_REJECTED", value: "This version can no longer communicate with the server. Update to keep sending and receiving messages.", comment: "")), shown)
        XCTAssertTrue(shown.contains(OWSLocalizedString("APP_EXPIRED_TELLOMI_BLOCKING_CHATS_KEPT", value: "Updating keeps all the chats on this phone.", comment: "")), shown)

        // 规则 1：主按钮「立即更新」，另有「暂不更新，只看聊天记录」；没有别的。
        XCTAssertEqual(buttons(in: viewController.view), [viewController.updateButton, viewController.viewChatsOnlyButton])
        XCTAssertEqual(viewController.viewChatsOnlyButton.configuration?.title, OWSLocalizedString("APP_EXPIRED_TELLOMI_BLOCKING_VIEW_CHATS_ONLY_BUTTON", value: "Not now, just view my chats", comment: ""))

        viewController.updateButton.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(opened, 1)
    }

    // MARK: - 最大字号（taishi 审查 b15 不阻塞 4）

    private func subviews<T: UIView>(of type: T.Type, in view: UIView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { subviews(of: type, in: $0) }
    }

    /// 放进还在支持的最小屏幕之一（iPhone SE 第二、三代，375×667）排好版。
    private func laidOutPage(at category: UIContentSizeCategory) throws -> (TellomiUpdateRequiredAppBlockingViewController, UIWindow) {
        guard #available(iOS 17.0, *) else {
            throw XCTSkip("traitOverrides needs iOS 17")
        }
        let viewController = TellomiUpdateRequiredAppBlockingViewController(openUpdatePage: {}, viewChatsOnly: {})
        viewController.traitOverrides.preferredContentSizeCategory = category
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 667))
        window.rootViewController = viewController
        window.isHidden = false
        viewController.view.layoutIfNeeded()
        return (viewController, window)
    }

    func testWithTheLargestTextTheExplanationIsNotCutOffAndThePageScrolls() throws {
        // 改之前：上游的内容栈不在滚动视图里，两段说明被压到 94pt，「更新不会影响聊天记录」被裁掉。
        let (viewController, window) = try laidOutPage(at: .accessibilityExtraExtraExtraLarge)
        defer { window.isHidden = true }

        let explanation = try XCTUnwrap(subviews(of: UILabel.self, in: viewController.view).first { $0.text == TellomiUpdateRequiredAppBlockingViewController.subtitle })
        let needed = explanation.sizeThatFits(CGSize(width: explanation.bounds.size.width, height: .greatestFiniteMagnitude)).height
        XCTAssertGreaterThanOrEqual(explanation.bounds.size.height + 1, needed, "the explanation is cut off")

        let scrollView = try XCTUnwrap(subviews(of: UIScrollView.self, in: viewController.view).first)
        XCTAssertGreaterThan(scrollView.contentSize.height, scrollView.bounds.size.height, "at this size the page has to scroll")
        let update = viewController.updateButton.convert(viewController.updateButton.bounds, to: scrollView)
        let exit = viewController.viewChatsOnlyButton.convert(viewController.viewChatsOnlyButton.bounds, to: scrollView)
        XCTAssertLessThanOrEqual(explanation.convert(explanation.bounds, to: scrollView).maxY, update.minY)
        XCTAssertLessThanOrEqual(exit.maxY, scrollView.contentSize.height, "the way to the chats can be scrolled to")
    }

    func testWhenEverythingFitsTheButtonsStayAtTheBottom() throws {
        let (viewController, window) = try laidOutPage(at: .large)
        defer { window.isHidden = true }

        let scrollView = try XCTUnwrap(subviews(of: UIScrollView.self, in: viewController.view).first)
        XCTAssertLessThanOrEqual(scrollView.contentSize.height, scrollView.bounds.size.height + 0.5, "at the default size nothing scrolls")
        let exit = viewController.viewChatsOnlyButton.convert(viewController.viewChatsOnlyButton.bounds, to: viewController.view)
        XCTAssertEqual(exit.maxY, viewController.view.bounds.maxY - viewController.view.safeAreaInsets.bottom - 16, accuracy: 0.5)
    }

    func testVoiceOverStaysOnThePage() {
        // 没上锁时下面是会话列表，旁白不能读到、点到它（taishi 审查 b15 要改 2）。
        let viewController = TellomiUpdateRequiredAppBlockingViewController(openUpdatePage: {}, viewChatsOnly: {})
        viewController.loadViewIfNeeded()
        XCTAssertTrue(viewController.view.accessibilityViewIsModal)
    }

    // MARK: - 只读模式的说法（#1143 需求 3.4，taishi 审查包 11）

    /// 服务端判定（499）时并没有过期：会话列表横幅说「需要更新才能继续收发消息」，不说「已过期」。
    func testReadOnlyBannerSaysAnUpdateIsNeededInsteadOfExpired() {
        let text = ExpirationNagView.ExpirationMessage.appExpired.text
        XCTAssertEqual(text, OWSLocalizedString("EXPIRATION_ERROR_TELLOMI", value: "Update Tellomi to keep sending and receiving messages.", comment: ""))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("expired"), text)
    }

    /// 会话输入框同理：「此版本需要更新才能收发消息。立即更新」，「立即更新」照旧是可点的链接。
    func testReadOnlyInputSaysAnUpdateIsNeededAndKeepsTheUpdateLink() {
        let text = ConversationViewController.appExpiredErrorText()
        let updateNow = OWSLocalizedString("APP_EXPIRED_BOTTOM_UPDATE", comment: "")
        XCTAssertFalse(text.string.localizedCaseInsensitiveContains("expired"), text.string)
        XCTAssertTrue(text.string.hasSuffix(updateNow), text.string)

        let linkRange = (text.string as NSString).range(of: updateNow)
        // UIColor.Signal.link 每次取都是新的动态颜色对象，要按同一种外观解析后再比
        let light = UITraitCollection(userInterfaceStyle: .light)
        let color = text.attribute(.foregroundColor, at: linkRange.location, effectiveRange: nil) as? UIColor
        XCTAssertEqual(color?.resolvedColor(with: light), UIColor.Signal.link.resolvedColor(with: light))
    }
}

private final class FakeUpdateRequiredBlockHost: TellomiUpdateRequiredBlockHost {
    var isUpdateRequiredBlockActive = false
    var updateRequiredViewChatsOnlyHandler: (@MainActor () -> Void)?
}
