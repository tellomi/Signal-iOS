//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import LibSignalClient
import XCTest

@testable import SignalServiceKit

/// ADR-0063 §4.5 / §7.4 (tellomi/tellomi#1420): a received `Preview.rich` (field 1000) shows the same snapshot as a
/// preview without it, and its bytes — including fields this build does not know — survive receive → database →
/// forward → database → send unchanged.
final class TellomiRichContentTest: SSKBaseTest {

    private static let url = "https://www.bilibili.com/video/BV1GJ411x7h7"
    private static let title = "某个视频的标题"
    private static let previewDescription = "视频简介"
    private static let date: UInt64 = 1_790_000_000_000

    private static func varint(_ value: Int) -> Data {
        var bytes = [UInt8]()
        var rest = value
        while rest >= 0x80 {
            bytes.append(UInt8(rest & 0x7F) | 0x80)
            rest >>= 7
        }
        bytes.append(UInt8(rest))
        return Data(bytes)
    }

    /// key = 1000 << 3 | 2, then the length, then the value.
    private static func field1000(_ rich: Data) -> Data {
        return Data([0xC2, 0x3E]) + varint(rich.count) + rich
    }

    /// A `RichContent` as `rust/links` writes it, plus a field this build does not know (99, length-delimited).
    private static let richBytes: Data = {
        let builder = SSKProtoRichContent.builder()
        builder.setKind("video")
        builder.setProvider("bilibili")
        builder.setSchema(1)
        builder.setCanonicalURL(url)
        for (key, value) in [("author", "某位 UP 主"), ("duration_ms", "212000")] {
            let attr = SSKProtoAttr.builder()
            attr.setKey(key)
            attr.setValue(value)
            builder.addAttrs(attr.buildInfallibly())
        }
        builder.setLevel(2)
        let payload = Data("from a newer client".utf8)
        return try! builder.buildSerializedData() + Data([0x9A, 0x06]) + varint(payload.count) + payload
    }()

    private static func snapshotBuilder(withImage: Bool) -> SSKProtoPreviewBuilder {
        let builder = SSKProtoPreview.builder(url: url)
        builder.setTitle(title)
        builder.setPreviewDescription(previewDescription)
        builder.setDate(date)
        if withImage {
            let image = SSKProtoAttachmentPointer.builder()
            image.setCdnKey("cdnKey")
            image.setCdnNumber(2)
            image.setKey(Data(repeating: 1, count: 32))
            image.setDigest(Data(repeating: 2, count: 32))
            image.setContentType(MimeType.imageJpeg.rawValue)
            image.setSize(34)
            builder.setImage(image.buildInfallibly())
        }
        return builder
    }

    /// The preview as a sender puts it on the wire: the snapshot, then field 1000 carrying `richBytes` verbatim.
    private static func receivedDataMessage(withRich: Bool, withImage: Bool) throws -> SSKProtoDataMessage {
        var previewBytes = try snapshotBuilder(withImage: withImage).buildSerializedData()
        if withRich {
            previewBytes += field1000(richBytes)
        }
        let dataMessage = SSKProtoDataMessage.builder()
        dataMessage.setBody("看这个 \(url)")
        dataMessage.addPreview(try SSKProtoPreview(serializedData: previewBytes))
        return try dataMessage.build()
    }

    private var linkPreviewManager: LinkPreviewManager { DependenciesBridge.shared.linkPreviewManager }

    override func setUp() {
        super.setUp()
        SSKEnvironment.shared.databaseStorageRef.write { tx in
            (DependenciesBridge.shared.registrationStateChangeManager as! RegistrationStateChangeManagerImpl).registerForTests(
                localIdentifiers: .forUnitTests,
                tx: tx,
            )
        }
        DependenciesBridge.shared.identityManager.generateAndPersistNewIdentityKey(for: .aci)
        DependenciesBridge.shared.identityManager.generateAndPersistNewIdentityKey(for: .pni)
    }

    func testFieldNumbersAndTypesMatchRustLinks() throws {
        // The same value and expected bytes as rust/links/src/rich.rs `field_numbers_match_the_adr`.
        let builder = SSKProtoRichContent.builder()
        builder.setKind("video")
        builder.setProvider("bilibili")
        builder.setSchema(1)
        builder.setCanonicalURL("u")
        let attr = SSKProtoAttr.builder()
        attr.setKey("k")
        attr.setValue("v")
        builder.addAttrs(attr.buildInfallibly())
        builder.setLevel(2)
        XCTAssertEqual(
            try builder.buildSerializedData().hexadecimalString,
            "0a05766964656f120862696c6962696c6918012201752a060a016b1201763002",
        )

        var previewRichOnly = SignalServiceProtos_Preview()
        previewRichOnly.rich = SignalServiceProtos_RichContent()
        XCTAssertEqual(try previewRichOnly.serializedData().hexadecimalString, "c23e00")
    }

    func testPreviewCarryingRichShowsTheSameSnapshot() throws {
        let withRichMessage = try Self.receivedDataMessage(withRich: true, withImage: true)
        let withoutRichMessage = try Self.receivedDataMessage(withRich: false, withImage: true)

        let withRich = try linkPreviewManager.validateAndBuildLinkPreview(from: withRichMessage.preview[0], dataMessage: withRichMessage)
        let withoutRich = try linkPreviewManager.validateAndBuildLinkPreview(from: withoutRichMessage.preview[0], dataMessage: withoutRichMessage)

        XCTAssertEqual(withRich.preview.urlString, withoutRich.preview.urlString)
        XCTAssertEqual(withRich.preview.title, withoutRich.preview.title)
        XCTAssertEqual(withRich.preview.previewDescription, withoutRich.preview.previewDescription)
        XCTAssertEqual(withRich.preview.date, withoutRich.preview.date)
        XCTAssertNotNil(withRich.imageProto)
        XCTAssertEqual(try withRich.imageProto?.serializedData(), try withoutRich.imageProto?.serializedData())

        XCTAssertEqual(withRich.preview.rich, Self.richBytes)
        XCTAssertNil(withoutRich.preview.rich)
    }

    func testReceivePersistLoadForwardPersistSendKeepsTheBytes() async throws {
        let db = SSKEnvironment.shared.databaseStorageRef

        // Receive.
        let received = try Self.receivedDataMessage(withRich: true, withImage: false)
        let validated = try linkPreviewManager.validateAndBuildLinkPreview(from: received.preview[0], dataMessage: received)
        XCTAssertEqual(validated.preview.rich, Self.richBytes)

        // Persist and load (TSMessage.linkPreview is archived into model_TSInteraction.linkPreview).
        let incomingId: String = await db.awaitableWrite { tx in
            let thread = TSContactThread.getOrCreateThread(
                withContactAddress: SignalServiceAddress(serviceId: Aci.randomForTesting(), phoneNumber: "+12223334444"),
                transaction: tx,
            )
            let incoming = TSIncomingMessageBuilder.withDefaultValues(
                thread: thread,
                authorAci: Aci.randomForTesting(),
                linkPreview: validated.preview,
            ).build()
            incoming.anyInsert(transaction: tx)
            return incoming.uniqueId
        }
        let loaded = try XCTUnwrap(db.read { tx in (TSInteraction.anyFetch(uniqueId: incomingId, transaction: tx) as? TSMessage)?.linkPreview })
        XCTAssertEqual(loaded.rich, Self.richBytes)

        // Forward: ForwardMessageItem.tryToCloneLinkPreview turns the stored preview into a draft…
        let draft = OWSLinkPreviewDraft(
            url: try XCTUnwrap(loaded.urlString.flatMap(URL.init(string:))),
            title: loaded.title,
            previewDescription: loaded.previewDescription,
            date: loaded.date,
            isForwarded: true,
            rich: loaded.rich,
        )
        // …which UnpreparedOutgoingMessage turns into the new message's preview.
        let dataSource = try await linkPreviewManager.buildDataSource(from: draft)
        let (outgoingId, threadId): (String, String) = try await db.awaitableWrite { tx in
            let thread = TSContactThread.getOrCreateThread(
                withContactAddress: SignalServiceAddress(serviceId: Aci.randomForTesting(), phoneNumber: "+12225556666"),
                transaction: tx,
            )
            let forwarded = try linkPreviewManager.validateDataSource(dataSource: dataSource, tx: tx)
            let builder = TSOutgoingMessageBuilder.outgoingMessageBuilder(
                thread: thread,
                messageBody: AttachmentContentValidatorMock.mockValidatedBody("看这个 \(Self.url)"),
            )
            builder.timestamp = 100
            builder.linkPreview = forwarded.preview
            let outgoing = builder.build(transaction: tx)
            outgoing.anyInsert(transaction: tx)
            return (outgoing.uniqueId, thread.uniqueId)
        }

        // Send: the stored outgoing message's plaintext carries the same bytes in field 1000.
        let sentPreview: SSKProtoPreview = try await db.awaitableWrite { tx in
            let outgoing = try XCTUnwrap(TSInteraction.anyFetch(uniqueId: outgoingId, transaction: tx) as? TSOutgoingMessage)
            XCTAssertEqual(outgoing.linkPreview?.rich, Self.richBytes)
            let thread = try XCTUnwrap(TSThread.anyFetch(uniqueId: threadId, transaction: tx))
            let content = try SSKProtoContent(serializedData: try outgoing.buildPlaintextData(inThread: thread, tx: tx))
            return try XCTUnwrap(content.dataMessage?.preview.first)
        }
        let expected = try Self.snapshotBuilder(withImage: false).buildSerializedData() + Self.field1000(Self.richBytes)
        XCTAssertEqual(try sentPreview.serializedData().hexadecimalString, expected.hexadecimalString)
    }

    func testWithoutRichTheSentPreviewIsTheUpstreamBytes() throws {
        let db = SSKEnvironment.shared.databaseStorageRef
        let sentPreview: SSKProtoPreview = try db.write { tx in
            let thread = TSContactThread.getOrCreateThread(
                withContactAddress: SignalServiceAddress(serviceId: Aci.randomForTesting(), phoneNumber: "+12227778888"),
                transaction: tx,
            )
            let builder = TSOutgoingMessageBuilder.outgoingMessageBuilder(
                thread: thread,
                messageBody: AttachmentContentValidatorMock.mockValidatedBody("看这个 \(Self.url)"),
            )
            builder.timestamp = 100
            builder.linkPreview = OWSLinkPreview(
                urlString: Self.url,
                title: Self.title,
                previewDescription: Self.previewDescription,
                date: Date(millisecondsSince1970: Self.date),
            )
            let outgoing = builder.build(transaction: tx)
            outgoing.anyInsert(transaction: tx)
            let content = try SSKProtoContent(serializedData: try outgoing.buildPlaintextData(inThread: thread, tx: tx))
            return try XCTUnwrap(content.dataMessage?.preview.first)
        }
        let upstream = try Self.snapshotBuilder(withImage: false).buildSerializedData()
        XCTAssertEqual(try sentPreview.serializedData().hexadecimalString, upstream.hexadecimalString)
        XCTAssertFalse(try sentPreview.serializedData().hexadecimalString.contains("c23e"))
    }

    func testArchivedPreviewKeepsRichAndOmitsItWhenAbsent() throws {
        let withRich = OWSLinkPreview(urlString: Self.url, title: Self.title, rich: Self.richBytes)
        let archived = try NSKeyedArchiver.archivedData(withRootObject: withRich, requiringSecureCoding: true)
        let unarchived = try XCTUnwrap(NSKeyedUnarchiver.unarchivedObject(ofClass: OWSLinkPreview.self, from: archived))
        XCTAssertEqual(unarchived.rich, Self.richBytes)
        XCTAssertEqual(unarchived, withRich)

        let decodedJSON = try JSONDecoder().decode(OWSLinkPreview.self, from: JSONEncoder().encode(withRich))
        XCTAssertEqual(decodedJSON.rich, Self.richBytes)

        let withoutRich = OWSLinkPreview(urlString: Self.url, title: Self.title)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(withoutRich), as: UTF8.self).contains("rich"))
        XCTAssertNotEqual(withRich, withoutRich)
    }

    func testUnparsableStoredBytesAreDroppedInsteadOfFailingTheSend() {
        XCTAssertNil(TellomiRichContent.forSending(Data([0xFF, 0xFF, 0xFF])))
        XCTAssertNil(TellomiRichContent.forSending(nil))
    }
}
