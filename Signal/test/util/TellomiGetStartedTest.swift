//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import XCTest

@testable import Signal
@testable import SignalServiceKit

/// Tellomi（tellomi/tellomi#1218 F-02、第 5 条）：首屏「开始使用」= 搜索用户名 / 我的二维码 / 邀请朋友 + 设头像，
/// 上游的「新建群组」「聊天颜色」不出；出现第一个真人会话（不算「笔记」和官方账号）后前三张收起，设头像留着。
final class TellomiGetStartedTest: SignalBaseTest {

    private final class NoopDelegate: GetStartedBannerViewControllerDelegate {
        func getStartedBannerDidTapInviteFriends(_ banner: GetStartedBannerViewController) {}
        func getStartedBannerDidTapCreateGroup(_ banner: GetStartedBannerViewController) {}
        func getStartedBannerDidTapAppearance(_ banner: GetStartedBannerViewController) {}
        func getStartedBannerDidDismissAllCards(_ banner: GetStartedBannerViewController, animated: Bool) {}
        func getStartedBannerDidTapAvatarBuilder(_ banner: GetStartedBannerViewController) {}
        func getStartedBannerDidTapFindByUsername(_ banner: GetStartedBannerViewController) {}
        func getStartedBannerDidTapMyQRCode(_ banner: GetStartedBannerViewController) {}
    }

    private let allCards = ["tellomi.findByUsername", "tellomi.myQRCode", "inviteFriends", "avatarBuilder"]

    override func setUp() {
        super.setUp()

        SSKEnvironment.shared.databaseStorageRef.write { tx in
            (DependenciesBridge.shared.registrationStateChangeManager as! RegistrationStateChangeManagerImpl).registerForTests(
                localIdentifiers: .forUnitTests,
                tx: tx,
            )
            GetStartedBannerViewController.enableAllCards(writeTx: tx)
        }
    }

    /// 新建一个横幅，读它这一刻要显示的卡。
    private func shownCards() -> [String] {
        let delegate = NoopDelegate()
        return GetStartedBannerViewController(delegate: delegate).bannerContent.map(\.identifier)
    }

    /// 等横幅顺手发出的「收起」写完：asyncWrite 走同一条串行队列（`asyncWriteQueue`），在它后面再排一个、等回调。
    /// 同步的 write 不走那条队列，等不到它（taishi 中转包 8）。
    private func waitForPendingAsyncWrites() {
        let drained = expectation(description: "async writes drained")
        SSKEnvironment.shared.databaseStorageRef.asyncWrite(block: { _ in }, completion: { drained.fulfill() })
        wait(for: [drained], timeout: 5)
    }

    private func insertVisibleThread(_ thread: TSThread) {
        SSKEnvironment.shared.databaseStorageRef.write { tx in
            thread.shouldThreadBeVisible = true
            thread.anyInsert(transaction: tx)
        }
    }

    func testFindFriendsPathsComeFirstAndNewGroupOrChatColorNeverShow() {
        XCTAssertEqual(shownCards(), allCards)
    }

    func testNoteToSelfAndTheOfficialAccountAreNotRealConversations() {
        insertVisibleThread(TSContactThread(contactAddress: SignalServiceAddress(LocalIdentifiers.forUnitTests.aci)))
        insertVisibleThread(TSReleaseNotesThread(uniqueId: TSReleaseNotesThread.releaseNotesUniqueId))

        XCTAssertEqual(shownCards(), allCards)
    }

    func testTheFirstRealConversationFoldsThePathsButKeepsAddPhoto() {
        let friend = TSContactThread(contactAddress: SignalServiceAddress(Aci.randomForTesting()))
        insertVisibleThread(friend)

        XCTAssertEqual(shownCards(), ["avatarBuilder"])
        waitForPendingAsyncWrites()

        // 收起写进了库里：把那个会话删掉再开一个横幅，扫不到真人会话了，前三张也不回来
        SSKEnvironment.shared.databaseStorageRef.write { tx in
            friend.anyRemove(transaction: tx)
        }
        XCTAssertEqual(shownCards(), ["avatarBuilder"])
    }
}
