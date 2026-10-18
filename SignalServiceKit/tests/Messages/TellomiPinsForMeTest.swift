//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Testing

@testable import LibSignalClient
@testable import SignalServiceKit

/// Tellomi (ADR-0081 §4.3, §4.6): a pin "for me only" is an ordinary `PinnedMessage` row plus a mark that every new pin row
/// wipes; the pin sheet's choices; the Tellomi fields a pin or an unpin carries.
@MainActor
struct TellomiPinsForMeTest {
    private let db = InMemoryDB()
    /// The real store reads threads through the model cache, which needs the whole app environment.
    private let threadStore = MockThreadStore()
    private let pinnedMessageManager: PinnedMessageManager
    private let author = Aci.randomForTesting()

    init() {
        pinnedMessageManager = PinnedMessageManager(
            disappearingMessagesConfigurationStore: MockDisappearingMessagesConfigurationStore(),
            interactionStore: InteractionStoreImpl(),
            accountManager: MockTSAccountManager(),
            db: db,
            threadStore: threadStore,
            dateProvider: Date.provider,
            expirationJob: PinnedMessageExpirationJob(dateProvider: { Date() }, db: db),
        )
    }

    // MARK: - Choices

    @Test
    func whatThePinSheetOffers() {
        #expect(TellomiPinChoice.choices(isNoteToSelf: false, isGroup: false, canPinForEveryone: true) == [.forBoth, .forMe])
        #expect(TellomiPinChoice.choices(isNoteToSelf: false, isGroup: false, canPinForEveryone: false) == [.forBoth, .forMe], "pinning in a 1:1 chat needs no permission")
        #expect(TellomiPinChoice.choices(isNoteToSelf: false, isGroup: true, canPinForEveryone: true) == [.forEveryone, .forEveryoneSilent, .forMe])
        #expect(TellomiPinChoice.choices(isNoteToSelf: false, isGroup: true, canPinForEveryone: false) == [.forMe], "without permission, only for me")
        #expect(TellomiPinChoice.choices(isNoteToSelf: true, isGroup: false, canPinForEveryone: true) == nil, "Saved Messages pins without asking")
    }

    // MARK: - On the wire

    @Test
    func theFlagOnlyCountsOnAPinOrAnUnpin() {
        #expect(TellomiPinsForMe.isSelfOnly(dataMessage(pin: true, forSelfOnly: true)))
        #expect(TellomiPinsForMe.isSelfOnly(dataMessage(unpin: true, forSelfOnly: true)))
        #expect(!TellomiPinsForMe.isSelfOnly(dataMessage(pin: true, forSelfOnly: false)))
        #expect(!TellomiPinsForMe.isSelfOnly(dataMessage(body: "hi", forSelfOnly: true)))
    }

    @Test
    func theTellomiFieldsAPinOrAnUnpinCarries() {
        #expect(TellomiPinsForMe.tellomiProto(isPin: true, forSelfOnly: false, silent: false, isGroup: true) == nil, "a plain pin keeps upstream bytes")
        #expect(TellomiPinsForMe.tellomiProto(isPin: true, forSelfOnly: false, silent: true, isGroup: false) == nil, "1:1 pins always notify")
        #expect(TellomiPinsForMe.tellomiProto(isPin: false, forSelfOnly: false, silent: true, isGroup: true) == nil, "not on an unpin")
        #expect(TellomiPinsForMe.tellomiProto(isPin: true, forSelfOnly: false, silent: true, isGroup: true)?.pinSilent == true)
        #expect(TellomiPinsForMe.tellomiProto(isPin: true, forSelfOnly: true, silent: false, isGroup: false)?.pinForSelfOnly == true)
        #expect(TellomiPinsForMe.tellomiProto(isPin: false, forSelfOnly: true, silent: false, isGroup: true)?.pinForSelfOnly == true)
    }

    // MARK: - Stored

    @Test
    func aPinForMeIsAPinThatIsMineOnly() {
        let (thread, interactionId, threadId) = insertThreadAndMessage()

        pinForMe(in: thread)

        db.read { tx in
            #expect(pinnedMessageManager.fetchPinnedMessagesForThread(threadId: threadId, tx: tx).map { $0.grdbId?.int64Value } == [interactionId])
            #expect(TellomiPinsForMe.isPinnedForMe(interactionId: interactionId, tx: tx))
            #expect(TellomiPinsForMe.pinnedForMeInteractionIds(threadId: threadId, tx: tx) == [interactionId])
            #expect(interactionCount(tx) == 1, "no \"pinned a message\"")
        }
    }

    @Test
    func anOrdinaryPinOfTheSameMessageMakesItEveryones() {
        let (thread, interactionId, threadId) = insertThreadAndMessage()
        pinForMe(in: thread)

        // What every ordinary pin does: replace the row.
        db.write { tx in
            pinnedMessageManager.deletePinForMessage(interactionId: interactionId, transaction: tx)
            _ = try! PinnedMessageRecord.insertRecord(interactionId: interactionId, threadId: threadId, sentTimestamp: 3000, receivedTimestamp: 3000, tx: tx)
        }

        db.read { tx in
            #expect(pinnedMessageManager.fetchPinnedMessagesForThread(threadId: threadId, tx: tx).count == 1)
            #expect(!TellomiPinsForMe.isPinnedForMe(interactionId: interactionId, tx: tx))
        }
    }

    @Test
    func aMarkWithoutItsPinIsNotAPin() {
        let (thread, interactionId, threadId) = insertThreadAndMessage()
        pinForMe(in: thread)

        db.write { tx in
            pinnedMessageManager.deletePinForMessage(interactionId: interactionId, transaction: tx)
        }

        db.read { tx in
            #expect(!TellomiPinsForMe.isPinnedForMe(interactionId: interactionId, tx: tx))
            #expect(TellomiPinsForMe.pinnedForMeInteractionIds(threadId: threadId, tx: tx).isEmpty)
        }
    }

    @Test
    func aSyncedPinForMeFromMyOtherDeviceIsMarkedWithoutAnUpdate() throws {
        let (thread, interactionId, _) = insertThreadAndMessage()
        let pin = SSKProtoDataMessagePinMessage.builder()
        pin.setTargetAuthorAciBinary(author.serviceIdBinary)
        pin.setTargetSentTimestamp(1000)
        pin.setPinDurationForever(true)

        try db.write { tx in
            try pinnedMessageManager.pinMessage(
                pinMessageProto: pin.buildInfallibly(),
                pinAuthor: LocalIdentifiers.forUnitTests.aci,
                thread: thread,
                pinSentAtTimestamp: 2000,
                expireTimer: 0,
                expireTimerVersion: 0,
                tellomiForMeOnly: true,
                transaction: tx,
            )
        }

        db.read { tx in
            #expect(TellomiPinsForMe.isPinnedForMe(interactionId: interactionId, tx: tx))
            #expect(interactionCount(tx) == 1, "no \"pinned a message\"")
        }
    }

    // MARK: - Unpinned

    @Test
    func someoneElsesUnpinLeavesMyPinForMeAlone() throws {
        let (thread, interactionId, _) = insertThreadAndMessage()
        pinForMe(in: thread)

        try db.write { tx in
            _ = try pinnedMessageManager.unpinMessage(unpinMessageProto: unpin(), threadUniqueId: thread.uniqueId, tellomiRule: .keepPinForMe, transaction: tx)
        }

        db.read { tx in
            #expect(TellomiPinsForMe.isPinnedForMe(interactionId: interactionId, tx: tx))
        }
    }

    @Test
    func myUnpinForMeTakesAwayOnlyAPinForMe() throws {
        let (thread, interactionId, threadId) = insertThreadAndMessage()
        db.write { tx in
            _ = try! PinnedMessageRecord.insertRecord(interactionId: interactionId, threadId: threadId, sentTimestamp: 3000, receivedTimestamp: 3000, tx: tx)
        }

        try db.write { tx in
            _ = try pinnedMessageManager.unpinMessage(unpinMessageProto: unpin(), threadUniqueId: thread.uniqueId, tellomiRule: .onlyPinForMe, transaction: tx)
        }
        db.read { tx in
            #expect(pinnedMessageManager.fetchPinnedMessagesForThread(threadId: threadId, tx: tx).count == 1, "an ordinary pin stays")
        }

        pinForMe(in: thread)
        try db.write { tx in
            _ = try pinnedMessageManager.unpinMessage(unpinMessageProto: unpin(), threadUniqueId: thread.uniqueId, tellomiRule: .onlyPinForMe, transaction: tx)
        }
        db.read { tx in
            #expect(pinnedMessageManager.fetchPinnedMessagesForThread(threadId: threadId, tx: tx).isEmpty)
        }
    }

    // MARK: - Helpers

    private func insertThreadAndMessage() -> (thread: TSThread, interactionId: Int64, threadId: Int64) {
        db.write { tx in
            let thread = TSThread(uniqueId: UUID().uuidString)
            threadStore.insertThread(thread) // gives it the next row id, which the insert below keeps
            try! thread.insert(tx.database)
            let message = TSIncomingMessageBuilder.withDefaultValues(thread: thread, timestamp: 1000, authorAci: author).build()
            try! message.asRecord().insert(tx.database)
            return (thread, message.grdbId!.int64Value, thread.grdbId!.int64Value)
        }
    }

    private func pinForMe(in thread: TSThread) {
        db.write { tx in
            pinnedMessageManager.applyPinMessageChangeToLocalState(
                targetTimestamp: 1000,
                targetAuthorAci: author,
                expiresAt: nil,
                isPin: true,
                sentTimestamp: 2000,
                threadUniqueId: thread.uniqueId,
                tellomiForMeOnly: true,
                tx: tx,
            )
        }
    }

    private func unpin() -> SSKProtoDataMessageUnpinMessage {
        let unpin = SSKProtoDataMessageUnpinMessage.builder()
        unpin.setTargetAuthorAciBinary(author.serviceIdBinary)
        unpin.setTargetSentTimestamp(1000)
        return unpin.buildInfallibly()
    }

    private func interactionCount(_ tx: DBReadTransaction) -> Int {
        return try! InteractionRecord.fetchCount(tx.database)
    }

    private func dataMessage(pin: Bool = false, unpin: Bool = false, body: String? = nil, forSelfOnly: Bool) -> SSKProtoDataMessage {
        let builder = SSKProtoDataMessage.builder()
        if pin {
            let pinBuilder = SSKProtoDataMessagePinMessage.builder()
            pinBuilder.setTargetAuthorAciBinary(author.serviceIdBinary)
            pinBuilder.setTargetSentTimestamp(1000)
            pinBuilder.setPinDurationForever(true)
            builder.setPinMessage(pinBuilder.buildInfallibly())
        }
        if unpin {
            builder.setUnpinMessage(self.unpin())
        }
        if let body {
            builder.setBody(body)
        }
        if forSelfOnly {
            let tellomi = SSKProtoTellomiDataMessage.builder()
            tellomi.setPinForSelfOnly(true)
            builder.setTellomi(tellomi.buildInfallibly())
        }
        return try! builder.build()
    }
}
