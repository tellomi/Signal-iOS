//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import XCTest
@testable import SignalServiceKit

/// card-visual §5.2 / §5.3（tellomi/tellomi#1423）：Tellomi 卡片说的对象，本机已经有什么——只读本地库。
/// 已经在的群（正式成员才算）、已装的贴纸包、已被接受的用户（或自己）。与 Android `TellomiFirstPartyLocalLookup`、Desktop `firstPartyLocal.node.ts` 同样的查法。
final class TellomiFirstPartyLocalLookupTest: SSKBaseTest {

    private let localAci = Aci.constantForTesting("00000000-0000-4000-8000-000000000AAA")

    override func setUp() {
        super.setUp()
        write { tx in
            (DependenciesBridge.shared.registrationStateChangeManager as! RegistrationStateChangeManagerImpl).registerForTests(
                localIdentifiers: .forUnitTests,
                tx: tx,
            )
        }
    }

    private func lookup(_ url: URL, _ card: TellomiLinkCard) -> TellomiFirstPartyCard.Local? {
        SSKEnvironment.shared.databaseStorageRef.read { TellomiFirstPartyLocalLookup.local(url: url, card: card, tx: $0) }
    }

    private func card(_ type: String, username: String? = nil) -> TellomiLinkCard {
        TellomiLinkCard(level: .firstParty, provider: "tellomi", domain: "tell.cc", firstParty: .init(type: type, username: username), showImage: false)
    }

    // MARK: - 群

    private func inviteLink(masterKey: GroupMasterKey) throws -> URL {
        try GroupInviteLink(masterKey: masterKey, inviteLinkPassword: GroupInviteLink.generateInviteLinkPassword()).url()
    }

    private func insertGroup(masterKey: GroupMasterKey, name: String, members: [(Aci, isInvited: Bool)]) throws {
        var membership = GroupMembership.Builder()
        for (aci, isInvited) in members {
            if isInvited {
                membership.addInvitedMember(aci, role: .normal, addedByAci: aci)
            } else {
                membership.addFullMember(aci, role: .normal)
            }
        }
        var builder = TSGroupModelBuilder(secretParams: try GroupSecretParams.deriveFromMasterKey(groupMasterKey: masterKey))
        builder.name = name
        builder.groupMembership = membership.build()
        let groupModel = try builder.buildAsV2()
        let thread = TSGroupThread(groupModel: groupModel)
        let secretParams = try GroupSecretParams.deriveFromMasterKey(groupMasterKey: masterKey)
        write { tx in
            thread.anyInsert(transaction: tx)
            // 群 id → 线程行的映射；没有这一行，按群 id 查不到线程（真实流程里入群时会建）。
            _ = GroupRecord.insertRecord(
                groupId: groupModel.groupId,
                threadId: thread.sqliteRowId!,
                masterKey: try! secretParams.getMasterKey(),
                refreshedAt: .distantPast,
                tx: tx,
            )
        }
    }

    func testAGroupThisAccountIsAFullMemberOfIsKnownWithItsLocalName() throws {
        let masterKey = try GroupMasterKey(contents: Randomness.generateRandomBytes(32))
        let url = try inviteLink(masterKey: masterKey)
        try insertGroup(masterKey: masterKey, name: "本地群名", members: [(localAci, false)])

        let local = lookup(url, card("group"))
        XCTAssertEqual(local, TellomiFirstPartyCard.Local(isGroupMember: true, groupName: "本地群名"))
    }

    func testAGroupThisAccountIsOnlyInvitedToIsNotKnown() throws {
        let masterKey = try GroupMasterKey(contents: Randomness.generateRandomBytes(32))
        let url = try inviteLink(masterKey: masterKey)
        try insertGroup(masterKey: masterKey, name: "只是被邀请", members: [(localAci, true)])

        XCTAssertNil(lookup(url, card("group")))
    }

    func testAGroupTheDeviceHasNeverSeenIsNotKnown() throws {
        let url = try inviteLink(masterKey: GroupMasterKey(contents: Randomness.generateRandomBytes(32)))
        XCTAssertNil(lookup(url, card("group")))
    }

    // MARK: - 贴纸包

    private func stickerPack() -> (info: StickerPackInfo, url: URL) {
        let info = StickerPackInfo(packId: Randomness.generateRandomBytes(16), packKey: Randomness.generateRandomBytes(UInt(StickerManager.packKeyLength)))
        let url = URL(string: "https://tell.cc/s#pack_id=\(info.packId.hexadecimalString)&pack_key=\(info.packKey.hexadecimalString)")!
        return (info, url)
    }

    func testAStickerPackIsInstalledOnlyOnceItIs() {
        let (info, url) = stickerPack()
        XCTAssertEqual(
            lookup(url, card("sticker")),
            TellomiFirstPartyCard.Local(isStickerPackInstalled: false),
        )

        let record = StickerPackRecord(
            info: info,
            title: "Bandit",
            author: nil,
            cover: StickerPackItem(stickerId: 0, emojiString: "😀", contentType: "image/webp"),
            items: [StickerPackItem(stickerId: 0, emojiString: "😀", contentType: "image/webp")],
        )
        // 直接写库并标成已安装：`installStickerPack` 会排下载，测试里没有文件。
        write { tx in
            record.anyInsert(transaction: tx)
            record.updateWith(isInstalled: true, tx: tx)
        }

        XCTAssertEqual(
            lookup(url, card("sticker")),
            TellomiFirstPartyCard.Local(isStickerPackInstalled: true),
        )
    }

    func testAStickerLinkThatIsNotAPackLinkKnowsNothing() {
        let url = URL(string: "https://tell.cc/s#pack_id=zz&pack_key=yy")!
        XCTAssertNil(lookup(url, card("sticker")))
    }

    // MARK: - 用户

    func testAUserIsKnownOnlyOnceAcceptedOrWhenItIsYou() {
        let stranger = Aci.randomForTesting()
        let accepted = Aci.randomForTesting()
        write { tx in
            let usernames = DependenciesBridge.shared.usernameLookupManager
            usernames.saveUsername("stranger.01", forAci: stranger, transaction: tx)
            usernames.saveUsername("accepted.01", forAci: accepted, transaction: tx)
            usernames.saveUsername("me.01", forAci: localAci, transaction: tx)
            var recipient = DependenciesBridge.shared.recipientFetcher.fetchOrCreate(serviceId: accepted, tx: tx)
            SSKEnvironment.shared.profileManagerRef.addRecipientToProfileWhitelist(&recipient, userProfileWriter: .debugging, tx: tx)
        }
        let url = URL(string: "https://tell.cc/x")!

        XCTAssertNil(lookup(url, card("user", username: "stranger.01")), "没被接受的不算认识")
        XCTAssertNotNil(lookup(url, card("user", username: "Accepted.01")), "已被接受的算，用户名不分大小写")
        XCTAssertNotNil(lookup(url, card("user", username: "me.01")), "自己算")
        XCTAssertNil(lookup(url, card("user", username: "nobody.01")), "本机没见过的用户名")
        XCTAssertNil(lookup(url, card("user")), "URL 里没有用户名")
    }

    /// 认识的用户带上头像的来源（对方的 ACI）：卡片用它从本地库取头像（联系人照片 / 对方的资料头像 / 默认头像）——
    /// 只读本地库，不联网（card-visual §5.2「本地认识 → 真头像」，ADR-0063 §4.1）。
    func testAKnownUserCarriesWhoseAvatarToShow() {
        let accepted = Aci.randomForTesting()
        let stranger = Aci.randomForTesting()
        write { tx in
            let usernames = DependenciesBridge.shared.usernameLookupManager
            usernames.saveUsername("accepted.01", forAci: accepted, transaction: tx)
            usernames.saveUsername("stranger.01", forAci: stranger, transaction: tx)
            usernames.saveUsername("me.01", forAci: localAci, transaction: tx)
            var recipient = DependenciesBridge.shared.recipientFetcher.fetchOrCreate(serviceId: accepted, tx: tx)
            SSKEnvironment.shared.profileManagerRef.addRecipientToProfileWhitelist(&recipient, userProfileWriter: .debugging, tx: tx)
        }
        let url = URL(string: "https://tell.cc/x")!

        XCTAssertEqual(lookup(url, card("user", username: "accepted.01"))?.knownUserAci, accepted)
        XCTAssertEqual(lookup(url, card("user", username: "me.01"))?.knownUserAci, localAci, "自己也有头像")
        XCTAssertNil(lookup(url, card("user", username: "stranger.01")), "没被接受的不算认识，也就没有头像来源")
    }

    func testNothingIsLookedUpForACallTheOfficialSiteOrAnyOtherLevel() throws {
        let url = URL(string: "https://tell.cc/call#key=bcdf-ghkm")!
        XCTAssertNil(lookup(url, card("call")))
        XCTAssertNil(lookup(url, card("official")))
        var generic = card("group")
        generic.level = .generic
        XCTAssertNil(lookup(url, generic))
    }
}
