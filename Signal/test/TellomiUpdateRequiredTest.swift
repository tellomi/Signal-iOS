//
// Copyright 2026 Tellomi
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// Tellomi（tellomi/tellomi#1139）：App 被判定过期（服务端 499 / 构建过期）时整页盖住，只留一个「立即更新」。
@MainActor
final class TellomiUpdateRequiredTest: SignalBaseTest {

    // MARK: - When to block

    private func blockReason(_ appExpiry: AppExpiry, isTellomiDeployment: Bool = true) -> TellomiUpdateRequiredAppBlockingViewController.Reason? {
        TellomiUpdateRequiredMonitoringManager.blockReason(appExpiry: appExpiry, now: Date(), isTellomiDeployment: isTellomiDeployment)
    }

    func testACurrentVersionIsNotBlocked() {
        XCTAssertNil(blockReason(AppExpiry.forUnitTests(buildDate: Date())))
    }

    func testABuildPastItsLifespanIsBlockedAsTooOld() {
        let buildDate = Date().addingTimeInterval(-AppExpiry.defaultExpirationInterval - .day)
        XCTAssertEqual(blockReason(AppExpiry.forUnitTests(buildDate: buildDate)), .buildTooOld)
    }

    func testAVersionTheServerTurnedAwayIsBlockedAsServerRejected() async {
        let appExpiry = AppExpiry.forUnitTests(buildDate: Date())
        // 服务端回 499 时走的就是这一步（AppExpiry.appExpiredStatusCode）。
        await appExpiry.setHasAppExpiredAtCurrentVersion(db: InMemoryDB())
        XCTAssertEqual(blockReason(appExpiry), .serverRejected)
    }

    func testTheSignalDeploymentKeepsTheUpstreamBehavior() async {
        let appExpiry = AppExpiry.forUnitTests(buildDate: Date())
        await appExpiry.setHasAppExpiredAtCurrentVersion(db: InMemoryDB())
        XCTAssertNil(blockReason(appExpiry, isTellomiDeployment: false))
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

    func testThePageHasOnlyOneButtonAndItOpensTheUpdatePage() {
        var opened = 0
        let viewController = TellomiUpdateRequiredAppBlockingViewController(reason: .serverRejected, openUpdatePage: { opened += 1 })
        viewController.loadViewIfNeeded()

        let shown = labelTexts(in: viewController.view).joined(separator: "\n")
        XCTAssertTrue(shown.contains(OWSLocalizedString("APP_EXPIRED_TELLOMI_BLOCKING_TITLE", comment: "")), shown)
        XCTAssertTrue(shown.contains(OWSLocalizedString("APP_EXPIRED_TELLOMI_BLOCKING_REASON_SERVER_REJECTED", comment: "")), shown)
        XCTAssertTrue(shown.contains(OWSLocalizedString("APP_EXPIRED_TELLOMI_BLOCKING_CHATS_KEPT", comment: "")), shown)

        // 没有关闭、没有「以后再说」。
        XCTAssertEqual(buttons(in: viewController.view), [viewController.updateButton])

        viewController.updateButton.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(opened, 1)
    }

    func testTheReasonFollowsWhyTheVersionWasBlocked() {
        let viewController = TellomiUpdateRequiredAppBlockingViewController(reason: .serverRejected, openUpdatePage: {})
        viewController.loadViewIfNeeded()

        viewController.reason = .buildTooOld

        let shown = labelTexts(in: viewController.view).joined(separator: "\n")
        XCTAssertTrue(shown.contains(OWSLocalizedString("APP_EXPIRED_TELLOMI_BLOCKING_REASON_BUILD_TOO_OLD", comment: "")), shown)
        XCTAssertFalse(shown.contains(OWSLocalizedString("APP_EXPIRED_TELLOMI_BLOCKING_REASON_SERVER_REJECTED", comment: "")), shown)
    }
}
