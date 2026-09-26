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

/// 「我的收藏」不套「新聊天默认限时」（owner 2026-09-26）：收藏的东西不该到时自己消失；别的一对一新会话照上游套。
class TellomiSavedMessagesDefaultTimerTest: SSKBaseTest {

    override func setUp() {
        super.setUp()
        SSKEnvironment.shared.databaseStorageRef.write { tx in
            (DependenciesBridge.shared.registrationStateChangeManager as! RegistrationStateChangeManagerImpl).registerForTests(
                localIdentifiers: .forUnitTests,
                tx: tx,
            )
            DependenciesBridge.shared.disappearingMessagesConfigurationStore.setUniversalTimer(
                token: DisappearingMessageToken(isEnabled: true, durationSeconds: 60 * 60),
                tx: tx,
            )
        }
    }

    func testSavedMessagesDoesNotGetTheDefaultTimer() {
        let (savedMessages, otherChat) = SSKEnvironment.shared.databaseStorageRef.write { tx in
            (
                TSContactThread.getOrCreateThread(withContactAddress: LocalIdentifiers.forUnitTests.aciAddress, transaction: tx),
                TSContactThread.getOrCreateThread(withContactAddress: SignalServiceAddress.randomForTesting(), transaction: tx),
            )
        }
        XCTAssertTrue(savedMessages.isNoteToSelf)

        SSKEnvironment.shared.databaseStorageRef.read { tx in
            XCTAssertFalse(
                ThreadFinder().shouldSetDefaultDisappearingMessageTimer(contactThread: savedMessages, transaction: tx),
                "「我的收藏」不套默认限时",
            )
            XCTAssertTrue(
                ThreadFinder().shouldSetDefaultDisappearingMessageTimer(contactThread: otherChat, transaction: tx),
                "别的一对一新会话照上游套默认限时",
            )
        }
    }
}
