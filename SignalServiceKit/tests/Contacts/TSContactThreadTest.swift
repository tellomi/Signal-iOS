//
// Copyright 2022 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import SignalServiceKit

class TSContactThreadTest: SSKBaseTest {
    private func contactThread() -> TSContactThread {
        TSContactThread.getOrCreateThread(contactAddress: SignalServiceAddress.randomForTesting())
    }

    override func setUp() {
        super.setUp()
        SSKEnvironment.shared.databaseStorageRef.write { tx in
            (DependenciesBridge.shared.registrationStateChangeManager as! RegistrationStateChangeManagerImpl).registerForTests(
                localIdentifiers: .forUnitTests,
                tx: tx,
            )
        }
    }

    func testHasSafetyNumbersWithoutRemoteIdentity() {
        XCTAssertFalse(contactThread().hasSafetyNumbers())
    }

    func testHasSafetyNumbersWithRemoteIdentity() {
        let contactThread = self.contactThread()

        let identityManager = DependenciesBridge.shared.identityManager
        SSKEnvironment.shared.databaseStorageRef.write { tx in
            _ = identityManager.saveIdentityKey(Data(count: 32), for: contactThread.contactAddress.serviceId!, shouldUpdateStorageService: false, tx: tx)
        }

        XCTAssert(contactThread.hasSafetyNumbers())
    }

    func testCanSendChatMessagesToThread() {
        XCTAssertTrue(contactThread().canSendChatMessagesToThread())
    }
}

// MARK: - Tellomi（tellomi/tellomi#1174）

/// 「我的收藏」（自己的会话）默认在聊天列表里（需求 official-account-and-saved §3.2）。
class TellomiSavedMessagesTest: SSKBaseTest {

    private func register() {
        SSKEnvironment.shared.databaseStorageRef.write { tx in
            (DependenciesBridge.shared.registrationStateChangeManager as! RegistrationStateChangeManagerImpl).registerForTests(
                localIdentifiers: .forUnitTests,
                tx: tx,
            )
        }
    }

    private func savedMessagesIsVisible() -> Bool {
        SSKEnvironment.shared.databaseStorageRef.read { tx in
            let localAddress = LocalIdentifiers.forUnitTests.aciAddress
            return TSContactThread.getWithContactAddress(localAddress, transaction: tx)?.shouldThreadBeVisible ?? false
        }
    }

    func testNothingIsCreatedBeforeRegistrationAndTheOneTimeListingStillHappensAfterwards() {
        SSKEnvironment.shared.databaseStorageRef.write { tx in TellomiSavedMessages.ensureListedOnce(tx: tx) }
        XCTAssertFalse(savedMessagesIsVisible())

        register()
        SSKEnvironment.shared.databaseStorageRef.write { tx in TellomiSavedMessages.ensureListedOnce(tx: tx) }
        XCTAssertTrue(savedMessagesIsVisible())
    }

    func testItIsListedOnceStaysOutAfterTheUserDeletesItAndTheSettingsEntryBringsItBack() {
        register()
        let thread = SSKEnvironment.shared.databaseStorageRef.write { tx in
            TellomiSavedMessages.ensureListedOnce(tx: tx)
            return TSContactThread.getWithContactAddress(LocalIdentifiers.forUnitTests.aciAddress, transaction: tx)!
        }
        XCTAssertTrue(savedMessagesIsVisible())

        SSKEnvironment.shared.databaseStorageRef.write { tx in
            thread.updateWithShouldThreadBeVisible(false, transaction: tx)
            TellomiSavedMessages.ensureListedOnce(tx: tx)
        }
        XCTAssertFalse(savedMessagesIsVisible())

        SSKEnvironment.shared.databaseStorageRef.write { tx in _ = TellomiSavedMessages.list(tx: tx) }
        XCTAssertTrue(savedMessagesIsVisible())
    }
}
