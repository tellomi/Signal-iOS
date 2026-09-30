//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import XCTest
@testable import SignalServiceKit

/// card-visual §5.2 / §3.9 / §3.10（tellomi/tellomi#1423）：Tellomi 自己对象的卡片有头像或封面、标题、副行和一个动作按钮；
/// 本机已知的东西会改副行和按钮，发送端写的不会。与 Android `TellomiFirstPartyCardTest`、Desktop `firstPartyCard_test.node.ts` 同一批用例。
final class TellomiFirstPartyCardTest: XCTestCase {

    private let strings = TellomiFirstPartyCard.Strings(
        officialTitle: "Tellomi website",
        tellomiUser: "Tellomi user",
        callTitle: "Tellomi call",
        actionMessage: "Message",
        actionJoinGroup: "Join Group",
        actionOpen: "Open",
        actionJoinCall: "Join Call",
        actionAddStickers: "Add",
        actionViewStickers: "View",
        groupJoined: "You’re a member",
        stickersAdded: "Added",
        memberCount: { $0 == 1 ? "1 member" : "\($0) members" },
        stickerCount: { $0 == 1 ? "1 sticker" : "\($0) stickers" },
    )

    private func card(_ firstParty: TellomiLinkCard.FirstParty?, level: TellomiLinkCard.Level = .firstParty, officialBadge: Bool = false) -> TellomiLinkCard {
        TellomiLinkCard(level: level, provider: "tellomi", domain: "tell.cc", officialBadge: officialBadge, firstParty: firstParty, showImage: false)
    }

    private var user: TellomiLinkCard { card(.init(type: "user", display: "@kefu.57", username: "kefu.57")) }
    private var group: TellomiLinkCard { card(.init(type: "group", title: "周末爬山群", memberCount: 12)) }
    private var sticker: TellomiLinkCard { card(.init(type: "sticker", title: "Bandit", stickerCount: 24)) }

    private func display(_ card: TellomiLinkCard, _ local: TellomiFirstPartyCard.Local? = nil) -> TellomiFirstPartyCard.Display? {
        TellomiFirstPartyCard.display(card: card, local: local, strings: strings)
    }

    func testAUserIsNamedFromTheURLAndTheButtonSaysWhatItDoes() {
        XCTAssertEqual(
            display(user),
            TellomiFirstPartyCard.Display(kind: .user, title: "@kefu.57", subtitle: "Tellomi user", action: "Message", officialBadge: false),
        )
    }

    func testAUserThisDeviceAlreadyKnowsKeepsTheNameItHas() {
        let shown = display(user, .init(knownUserName: "Kai Xin"))
        XCTAssertEqual(shown?.title, "Kai Xin")
        XCTAssertEqual(shown?.subtitle, "Tellomi user")
    }

    /// 本机认识的用户卡带着头像来源（ACI）；不认识的用户（默认头像）和别的对象（群、贴纸包、通话、官网）没有。
    func testOnlyAKnownUserCardCarriesAnAvatarSource() {
        let aci = Aci.randomForTesting()
        XCTAssertEqual(display(user, .init(knownUserName: "Kai Xin", knownUserAci: aci))?.avatarAci, aci)
        XCTAssertNil(display(user)?.avatarAci, "本机不认识：默认头像")
        XCTAssertNil(display(user, .init(isGroupMember: true))?.avatarAci)
        XCTAssertNil(display(group, .init(isGroupMember: true, groupName: "爬山", knownUserAci: aci))?.avatarAci)
        XCTAssertNil(display(sticker, .init(isStickerPackInstalled: true, knownUserAci: aci))?.avatarAci)
        XCTAssertNil(display(card(.init(type: "call", title: "周五例会")), .init(knownUserAci: aci))?.avatarAci)
        XCTAssertNil(display(card(.init(type: "official", path: "/"), officialBadge: true), .init(knownUserAci: aci))?.avatarAci)
    }

    func testAUserWithNoNameInTheURLIsATellomiUserOnce() {
        let shown = display(card(.init(type: "user")))
        XCTAssertEqual(shown?.title, "Tellomi user")
        XCTAssertNil(shown?.subtitle)
    }

    func testAGroupToJoinCountsItsMembers() {
        XCTAssertEqual(
            display(group),
            TellomiFirstPartyCard.Display(kind: .group, title: "周末爬山群", subtitle: "12 members", action: "Join Group", officialBadge: false),
        )
        XCTAssertEqual(display(card(.init(type: "group", title: "Two", memberCount: 1)))?.subtitle, "1 member")
        for count in [nil, 0, -3] as [Int64?] {
            XCTAssertNil(display(card(.init(type: "group", title: "G", memberCount: count)))?.subtitle, "\(String(describing: count))")
        }
    }

    func testAGroupThisAccountIsAlreadyInOpens() {
        let shown = display(group, .init(isGroupMember: true))
        XCTAssertEqual(shown?.subtitle, "You’re a member")
        XCTAssertEqual(shown?.action, "Open")
    }

    func testAMemberSeesTheLocalGroupNameNotTheSenders() {
        let shown = display(group, .init(isGroupMember: true, groupName: "爬山（改名后）"))
        XCTAssertEqual(shown?.title, "爬山（改名后）")
        // 不是成员时，本地名字不用（本机不该有）：发送端写的群名
        XCTAssertEqual(display(group, .init(isGroupMember: false, groupName: "别的"))?.title, "周末爬山群")
    }

    func testACallIsNamedByItsRoomOrIsATellomiCall() {
        XCTAssertEqual(
            display(card(.init(type: "call", title: "Camping Prep"))),
            TellomiFirstPartyCard.Display(kind: .call, title: "Camping Prep", subtitle: nil, action: "Join Call", officialBadge: false),
        )
        XCTAssertEqual(display(card(.init(type: "call")))?.title, "Tellomi call")
    }

    func testAStickerPackToAddCountsItsStickersAndOneAlreadyAddedIsViewed() {
        XCTAssertEqual(
            display(sticker),
            TellomiFirstPartyCard.Display(kind: .sticker, title: "Bandit", subtitle: "24 stickers", action: "Add", officialBadge: false),
        )
        let installed = display(sticker, .init(isStickerPackInstalled: true))
        XCTAssertEqual(installed?.subtitle, "Added")
        XCTAssertEqual(installed?.action, "View")
        XCTAssertEqual(display(card(.init(type: "sticker", title: "One", stickerCount: 1)))?.subtitle, "1 sticker")
    }

    func testTheOfficialSiteCardShowsFixedTextThePathAndTheBadge() {
        let official = card(.init(type: "official", path: "/download"), officialBadge: true)
        XCTAssertEqual(
            display(official),
            TellomiFirstPartyCard.Display(kind: .official, title: "Tellomi website", subtitle: "/download", action: "Open", officialBadge: true),
        )
    }

    func testItIsNotAFirstPartyCardAtAnyOtherLevelOrWithATypeThisBuildDoesNotKnow() {
        XCTAssertNil(display(card(.init(type: "group", title: "G", memberCount: 3), level: .generic)))
        XCTAssertNil(display(card(nil)))
        XCTAssertNil(display(card(.init(type: "hologram", title: "x"))))
    }
}
