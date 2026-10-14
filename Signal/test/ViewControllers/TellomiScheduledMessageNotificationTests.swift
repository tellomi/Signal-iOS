//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import UserNotifications
import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// Tellomi（tellomi/tellomi#1519 M-4，方案 §6.2 / §6.3）：到点通知怎么对齐记录、写什么；后台刷新提前到最早那一条；「立即发送」。
final class TellomiScheduledMessageNotificationTests: SignalBaseTest {

    private typealias Notifications = TellomiScheduledMessageNotifications

    override func setUp() {
        super.setUp()
        write { tx in
            (DependenciesBridge.shared.registrationStateChangeManager as! RegistrationStateChangeManagerImpl).registerForTests(
                localIdentifiers: .forUnitTests,
                tx: tx,
            )
        }
    }

    // MARK: - Sync plan

    func testThePlanRemovesStaleOnesAndSchedulesNewOnes() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let kept = wanted("kept", at: now.addingTimeInterval(60))
        let moved = wanted("moved", at: now.addingTimeInterval(120))
        let new = wanted("new", at: now.addingTimeInterval(180))
        let alreadyDue = wanted("due", at: now.addingTimeInterval(-1))

        let plan = Notifications.plan(
            wanted: [kept, moved, new, alreadyDue],
            pending: [
                pending("kept", at: kept.scheduledAt),
                pending("moved", at: now.addingTimeInterval(30)),
                pending("sent", at: now.addingTimeInterval(90)),
                Notifications.Pending(identifier: "Signal.someOtherNotification", scheduledAt: nil),
            ],
            delivered: [id("due"), id("sentEarlier"), "Signal.someMessage"],
            now: now,
        )

        XCTAssertEqual(plan.removePending.sorted(), [id("moved"), id("sent")])
        XCTAssertEqual(plan.removeDelivered, [id("sentEarlier")], "a delivered one stays while its message is still waiting")
        XCTAssertEqual(plan.add.map(\.messageId).sorted(), ["moved", "new"], "already-due ones aren't scheduled; the executor sends them")
    }

    func testThePlanToleratesTheDateRoundTrip() {
        let at = Date(timeIntervalSinceReferenceDate: 812_345_678.123_456)
        let roundTripped = Date(timeIntervalSince1970: at.timeIntervalSince1970)
        let plan = Notifications.plan(
            wanted: [wanted("a", at: at)],
            pending: [pending("a", at: roundTripped)],
            delivered: [],
            now: at.addingTimeInterval(-60),
        )
        XCTAssertEqual(plan, Notifications.Plan())
    }

    // MARK: - Content

    func testTheNotificationNeverShowsTheTextAndFiresAtTheScheduledSecond() throws {
        let at = Date(timeIntervalSince1970: 1_800_000_123)
        let request = Notifications.request(for: Notifications.Wanted(messageId: "m", threadUniqueId: "t", scheduledAt: at, title: "小明"))

        XCTAssertEqual(request.identifier, id("m"))
        XCTAssertEqual(request.content.title, "小明")
        XCTAssertEqual(request.content.body, OWSLocalizedString("TELLOMI_SCHEDULED_MESSAGE_DUE_NOTIFICATION_BODY", comment: ""))
        XCTAssertEqual(request.content.categoryIdentifier, Notifications.categoryIdentifier)
        let trigger = try XCTUnwrap(request.trigger as? UNCalendarNotificationTrigger)
        XCTAssertEqual(trigger.nextTriggerDate(), at)

        // 点通知：发出并打开会话；点「立即发送」：只发出；划掉：什么都不做。
        let tap = try XCTUnwrap(Notifications.response(for: request.content, actionIdentifier: UNNotificationDefaultActionIdentifier))
        XCTAssertEqual(tap.messageId, "m")
        XCTAssertEqual(tap.threadUniqueId, "t")
        XCTAssertTrue(tap.opensChat)
        let sendNow = try XCTUnwrap(Notifications.response(for: request.content, actionIdentifier: Notifications.sendNowActionIdentifier))
        XCTAssertFalse(sendNow.opensChat)
        XCTAssertNil(Notifications.response(for: request.content, actionIdentifier: UNNotificationDismissActionIdentifier))

        let category = Notifications.category
        XCTAssertEqual(category.actions.map(\.identifier), [Notifications.sendNowActionIdentifier])
        XCTAssertEqual(category.actions.first?.options, UNNotificationActionOptions.authenticationRequired, "runs in the background, needs an unlocked device")
        XCTAssertTrue(UserNotificationConfig.allNotificationCategories.contains { $0.identifier == Notifications.categoryIdentifier })
    }

    /// 标题照通知设置：「不显示名字也不显示内容」时不写会话名。
    @MainActor
    func testTheTitleFollowsTheNotificationPrivacySetting() async throws {
        let thread = write { tx in ContactThreadFactory().create(transaction: tx) }
        try await TellomiScheduledMessageSender().schedule(
            body: MessageBody(text: "秘密", ranges: .empty),
            attachments: [],
            isViewOnce: false,
            thread: thread,
            quotedReplyDraft: nil,
            linkPreviewDraft: nil,
            captionAboveMedia: false,
            at: Date().addingTimeInterval(3600),
        )
        let name = read { tx in SSKEnvironment.shared.contactManagerRef.displayName(for: thread, transaction: tx) }

        write { tx in DependenciesBridge.shared.notificationPreferencesManager.setPreviewType(.nameNoPreview, tx: tx) }
        XCTAssertEqual(read(block: Notifications.wanted(tx:)).map(\.title), [name])

        write { tx in DependenciesBridge.shared.notificationPreferencesManager.setPreviewType(.noNameNoPreview, tx: tx) }
        XCTAssertEqual(read(block: Notifications.wanted(tx:)).map(\.title), [nil])
    }

    // MARK: - Background refresh

    func testBackgroundRefreshIsMovedUpToTheEarliestMessage() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let interval: TimeInterval = 6 * 3600
        func earliest(_ next: Date?) -> Date {
            MessageFetchBGRefreshTask.tellomiEarliestBeginDate(now: now, refreshInterval: interval, nextScheduledMessage: next)
        }
        XCTAssertEqual(earliest(nil), now.addingTimeInterval(interval))
        XCTAssertEqual(earliest(now.addingTimeInterval(600)), now.addingTimeInterval(600))
        XCTAssertEqual(earliest(now.addingTimeInterval(-600)), now, "an overdue message: as soon as possible")
        XCTAssertEqual(earliest(now.addingTimeInterval(interval + 600)), now.addingTimeInterval(interval))
    }

    // MARK: - Send now

    /// 「立即发送」：还没到点的提前到现在发出，返回时已在发送队列里。
    @MainActor
    func testSendNowSendsAMessageBeforeItsTime() async throws {
        let thread = write { tx in ContactThreadFactory().create(transaction: tx) }
        let sender = TellomiScheduledMessageSender()
        let message = try await sender.schedule(
            body: MessageBody(text: "提前发", ranges: .empty),
            attachments: [],
            isViewOnce: false,
            thread: thread,
            quotedReplyDraft: nil,
            linkPreviewDraft: nil,
            captionAboveMedia: false,
            at: Date().addingTimeInterval(3600),
        )

        await sender.sendNow(id: message.id)

        let sent = read { tx in
            ((try? InteractionFinder(threadUniqueId: thread.uniqueId).fetchAllInteractions(rowIdFilter: .newest, limit: 10, tx: tx)) ?? [])
                .compactMap { ($0 as? TSOutgoingMessage)?.body }
        }
        XCTAssertEqual(sent, ["提前发"])
        XCTAssertEqual(read { tx in TellomiScheduledMessageStore.fetchAll(tx: tx) }, [])
    }

    // MARK: - Helpers

    private func id(_ messageId: String) -> String {
        Notifications.identifier(messageId: messageId)
    }

    private func wanted(_ messageId: String, at date: Date) -> Notifications.Wanted {
        Notifications.Wanted(messageId: messageId, threadUniqueId: "t", scheduledAt: date, title: nil)
    }

    private func pending(_ messageId: String, at date: Date) -> Notifications.Pending {
        Notifications.Pending(identifier: id(messageId), scheduledAt: date)
    }
}
