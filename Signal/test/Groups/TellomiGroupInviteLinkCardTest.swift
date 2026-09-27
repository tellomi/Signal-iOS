//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// ADR-0063 §4.1 第 2 条、§5.3：群邀请卡片只用本地数据渲染（tellomi/tellomi#1423）。
///
/// 跑在 `MockSSKEnvironment` 里：它的 `MockGroupsV2` 对 `cachedGroupInviteLinkPreview` / `fetchGroupInviteLinkPreview` /
/// `fetchGroupInviteLinkAvatar` 一律 `owsFail`。上游的渲染路径第一步就查这个缓存、缓存没有就去取，在这里会直接崩；
/// 现在的路径一次都不碰它。
final class TellomiGroupInviteLinkCardTest: SignalBaseTest {

    override func setUp() {
        super.setUp()
        write { tx in
            (DependenciesBridge.shared.registrationStateChangeManager as! RegistrationStateChangeManagerImpl).registerForTests(
                localIdentifiers: .forUnitTests,
                tx: tx,
            )
        }
    }

    private func inviteLink(masterKey: GroupMasterKey) throws -> GroupInviteLink {
        return try GroupInviteLink(masterKey: masterKey, inviteLinkPassword: GroupInviteLink.generateInviteLinkPassword())
    }

    private func conversationStyle() -> ConversationStyle {
        let thread = TSContactThread(contactAddress: SignalServiceAddress(Aci.constantForTesting("00000000-0000-4000-8000-00000000000B")))
        return ConversationStyle(
            type: .`default`,
            thread: thread,
            viewWidth: 320,
            hasWallpaper: false,
            shouldDimWallpaperInDarkMode: false,
            chatColor: ChatColorSettingStore.Constants.defaultColor.colorSetting,
        )
    }

    private func state(for link: GroupInviteLink, snapshotTitle: String?) -> LinkPreviewGroupLink? {
        let linkPreview = OWSLinkPreview(urlString: link.url().absoluteString, title: snapshotTitle)
        let conversationStyle = conversationStyle()
        return read { tx in
            CVComponentState.localGroupInviteLinkPreviewState(
                linkPreview: linkPreview,
                messageRowId: nil,
                groupInviteLink: link,
                linkType: .incomingMessageGroupInviteLink,
                conversationStyle: conversationStyle,
                transaction: tx,
            )
        }
    }

    func testCardUsesTheSnapshotWhenTheGroupIsNotLocal() throws {
        let link = try inviteLink(masterKey: try GroupSecretParams.generate().getMasterKey())

        let card = try XCTUnwrap(state(for: link, snapshotTitle: "周末爬山群"))
        XCTAssertEqual(card.title, "周末爬山群")
        XCTAssertTrue(card.isGroupInviteLink)
        XCTAssertTrue(card.isLoaded)
        XCTAssertEqual(card.displayDomain, "tell.cc")
        // 不认识的群不显示人数（人数只能来自本地库）
        XCTAssertEqual(card.previewDescription, OWSLocalizedString("GROUP_LINK_ACTION_SHEET_VIEW_GROUP_INDICATOR", comment: ""))
    }

    func testNoSnapshotTitleAndUnknownGroupMeansPlainLink() throws {
        let link = try inviteLink(masterKey: try GroupSecretParams.generate().getMasterKey())
        XCTAssertNil(state(for: link, snapshotTitle: nil))
        XCTAssertNil(state(for: link, snapshotTitle: "  "))
    }

    func testLocalGroupOverridesTheSnapshot() throws {
        let groupThread = try write { tx in
            let localAci = try XCTUnwrap(DependenciesBridge.shared.tsAccountManager.localIdentifiers(tx: tx)?.aci)
            return try GroupManager.createGroupForTests(
                members: [
                    SignalServiceAddress(localAci),
                    SignalServiceAddress(Aci.constantForTesting("00000000-0000-4000-8000-00000000000A")),
                ],
                name: "本地的群名",
                transaction: tx,
            )
        }
        let masterKey = try XCTUnwrap(groupThread.groupModel as? TSGroupModelV2).masterKey()
        let link = try inviteLink(masterKey: masterKey)
        let derivedGroupId = GroupV2ContextInfo.deriveFrom(masterKey: masterKey).groupId
        XCTAssertNotNil(read { TSGroupThread.fetchThread(forGroupId: derivedGroupId, tx: $0) })
        let localAci = try XCTUnwrap(read { DependenciesBridge.shared.tsAccountManager.localIdentifiers(tx: $0)?.aci })
        XCTAssertTrue(groupThread.groupModel.groupMembership.isFullMember(localAci))

        // 发送端写的标题想冒充别的群：本机已在群里，用本地的名字和人数
        let card = try XCTUnwrap(state(for: link, snapshotTitle: "Tellomi 官方客服群"))
        XCTAssertEqual(card.title, "本地的群名")
        let memberCount = groupThread.groupModel.groupMembership.fullMembers.count
        XCTAssertEqual(
            card.previewDescription,
            OWSLocalizedString("GROUP_LINK_ACTION_SHEET_VIEW_GROUP_INDICATOR", comment: "")
                + " | " + GroupViewUtils.formatGroupMembersLabel(memberCount: memberCount, isTerminated: false),
        )
    }

    func testResolveIsPure() {
        XCTAssertEqual(
            GroupInviteLinkCardContent.resolve(snapshotTitle: "A", localGroup: nil),
            GroupInviteLinkCardContent(title: "A", localMemberCount: nil),
        )
        XCTAssertEqual(
            GroupInviteLinkCardContent.resolve(snapshotTitle: "A", localGroup: .init(title: "B", memberCount: 3)),
            GroupInviteLinkCardContent(title: "B", localMemberCount: 3),
        )
        XCTAssertEqual(
            GroupInviteLinkCardContent.resolve(snapshotTitle: "A", localGroup: .init(title: nil, memberCount: 2)),
            GroupInviteLinkCardContent(title: "A", localMemberCount: 2),
        )
        XCTAssertNil(GroupInviteLinkCardContent.resolve(snapshotTitle: nil, localGroup: nil))
        XCTAssertNil(GroupInviteLinkCardContent.resolve(snapshotTitle: "\u{200B}", localGroup: nil))
    }
}
