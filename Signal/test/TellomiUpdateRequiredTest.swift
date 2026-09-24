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

    func testOnlyOurOwnAppStoreOrTestFlightListingCountsAsAnUpdateChannel() {
        // 上游的 Signal 条目、Signal-iOS#23 之后的官网下载页（还没上架）都不算，所以现在 iOS 不会盖。
        XCTAssertFalse(TellomiUpdateRequiredMonitoringManager.hasUpdateChannel(appStoreUrl: URL(string: "https://itunes.apple.com/us/app/signal-private-messenger/id874139669?mt=8")!))
        XCTAssertFalse(TellomiUpdateRequiredMonitoringManager.hasUpdateChannel(appStoreUrl: URL(string: "https://apps.apple.com/app/signal-private-messenger/id874139669")!))
        XCTAssertFalse(TellomiUpdateRequiredMonitoringManager.hasUpdateChannel(appStoreUrl: URL(string: "https://tellomi.app/download/")!))

        XCTAssertTrue(TellomiUpdateRequiredMonitoringManager.hasUpdateChannel(appStoreUrl: ourAppStoreListing))
        XCTAssertTrue(TellomiUpdateRequiredMonitoringManager.hasUpdateChannel(appStoreUrl: URL(string: "https://testflight.apple.com/join/AbCdEfGh")!))
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
