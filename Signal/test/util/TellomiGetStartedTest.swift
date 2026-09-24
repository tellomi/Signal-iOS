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

    /// 新建一个横幅，读它这一刻要显示的卡；再同步写一次，等它顺手发出的「收起」异步写完。
    private func shownCards() -> [String] {
        let delegate = NoopDelegate()
        let identifiers = GetStartedBannerViewController(delegate: delegate).bannerContent.map(\.identifier)
        SSKEnvironment.shared.databaseStorageRef.write { _ in }
        return identifiers
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
        insertVisibleThread(TSContactThread(contactAddress: SignalServiceAddress(Aci.randomForTesting())))

        XCTAssertEqual(shownCards(), ["avatarBuilder"])
        // 收起写进了库里：再开一个横幅也只剩设头像
        XCTAssertEqual(shownCards(), ["avatarBuilder"])
    }
}
