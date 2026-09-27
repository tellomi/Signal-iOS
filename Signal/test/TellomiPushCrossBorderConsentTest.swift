//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit

/// Tellomi（tellomi/tellomi#1338）：已注册的人升级到带跨境告知的版本以后，同意之前不向 Apple 要 APNs / PushKit 令牌
/// （需求 `privacy-compliance-hk-cross-border.md` 2.1：「推送注册……都等同意之后」）。
/// 启动、回前台的 `SyncPushTokensJob` 都走 `PushRegistrationManager.requestPushTokens`，闸就在它的开头。
@MainActor
final class TellomiPushCrossBorderConsentTest: SignalBaseTest {

    /// `requestPushTokens` 过了跨境闸，第一件事是看通知授权（`needsNotificationAuthorization`），然后才去 Apple 要令牌。
    /// 走到这一步就记一笔、停在这里：测试不真的去 Apple 要令牌。
    private final class PushRegistrationManagerSpy: PushRegistrationManager {
        let wentOnToRequestTokens = XCTestExpectation(description: "went on to request tokens from Apple")
        private(set) var tokenRequestCount = 0
        private var parked: [CheckedContinuation<Void, Never>] = []

        override func needsNotificationAuthorization() async -> Bool {
            tokenRequestCount += 1
            wentOnToRequestTokens.fulfill()
            await withCheckedContinuation { parked.append($0) }
            return false
        }

        /// 同意之后补的那一次同步：只数次数（真的 `SyncPushTokensJob` 要 `AppEnvironment`）。
        private(set) var syncAfterConsentCount = 0

        override func syncPushTokensAfterCrossBorderConsent() {
            syncAfterConsentCount += 1
        }
    }

    override func setUp() {
        super.setUp()
        forgetCrossBorderConsent()
    }

    override func tearDown() {
        forgetCrossBorderConsent()
        super.tearDown()
    }

    /// `TellomiCrossBorderConsent` 记在 `appUserDefaults()` 里的两个键（`AppExpiry.swift` 末尾）。
    private func forgetCrossBorderConsent() {
        let defaults = CurrentAppContext().appUserDefaults()
        defaults.removeObject(forKey: "TellomiCrossBorderConsent.version")
        defaults.removeObject(forKey: "TellomiCrossBorderConsent.date")
    }

    /// `recordAgreement()` 的通知是 `DispatchQueue.main.async` 发的；等主队列把它之前的活干完。
    private func drainMainQueue() async {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 5)
    }

    // MARK: - Tests

    func testTokensAreNotRequestedFromAppleBeforeCrossBorderConsent() async {
        XCTAssertFalse(TellomiCrossBorderConsent.hasAgreed, "前提：还没同意跨境")
        let manager = PushRegistrationManagerSpy(appReadiness: AppReadinessMock())

        let returned = expectation(description: "requestPushTokens returned")
        Task {
            do {
                _ = try await manager.requestPushTokens(forceRotation: false)
                XCTFail("没同意跨境，不该拿到推送令牌")
            } catch {
                // 预期：直接失败，不去 Apple 要令牌。
            }
            returned.fulfill()
        }
        await fulfillment(of: [returned], timeout: 5)

        XCTAssertEqual(manager.tokenRequestCount, 0, "没同意跨境：不该往下走到向 Apple 要 APNs / PushKit 令牌")
    }

    func testTokensAreRequestedAsBeforeOnceCrossBorderConsentIsGiven() async {
        // 新用户注册、关联设备都是先同意再要令牌，这条路不能被闸挡住。
        TellomiCrossBorderConsent.recordAgreement()
        XCTAssertTrue(TellomiCrossBorderConsent.hasAgreed, "前提：已经同意跨境")
        let manager = PushRegistrationManagerSpy(appReadiness: AppReadinessMock())

        Task { _ = try? await manager.requestPushTokens(forceRotation: false) }
        await fulfillment(of: [manager.wentOnToRequestTokens], timeout: 5)

        XCTAssertEqual(manager.tokenRequestCount, 1)
    }

    func testHeldBackTokensAreSyncedOnceRightAfterCrossBorderConsent() async {
        let manager = PushRegistrationManagerSpy(appReadiness: AppReadinessMock())
        // 启动时的 `SyncPushTokensJob`：被闸挡下。
        _ = try? await manager.requestPushTokens(forceRotation: false)
        XCTAssertEqual(manager.syncAfterConsentCount, 0, "还没同意，不补")

        TellomiCrossBorderConsent.recordAgreement()
        await drainMainQueue()
        XCTAssertEqual(manager.syncAfterConsentCount, 1, "同意之后要补一次：拿令牌并报给服务端")

        // 再收到一次同意的通知（比如重复点），不再补。
        TellomiCrossBorderConsent.recordAgreement()
        await drainMainQueue()
        XCTAssertEqual(manager.syncAfterConsentCount, 1)
        XCTAssertEqual(manager.tokenRequestCount, 0, "补的那次走 `SyncPushTokensJob`，这里不会自己去要令牌")
    }

    func testNewUserConsentDoesNotTriggerAnExtraSync() async {
        // 新用户在号码页同意时，还没有谁要过令牌；注册流程自己会去要，这里不插手。
        let manager = PushRegistrationManagerSpy(appReadiness: AppReadinessMock())

        TellomiCrossBorderConsent.recordAgreement()
        await drainMainQueue()

        XCTAssertEqual(manager.syncAfterConsentCount, 0)
    }
}
