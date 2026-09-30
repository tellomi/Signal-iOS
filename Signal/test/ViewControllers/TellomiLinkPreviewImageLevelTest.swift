//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import UIKit
import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// ADR-0063 §5.3、审计 I9：卡片的级别按 `Preview.image` 在不在判，不看图下没下载完，也不因为下载失败改级，免得卡片跳来跳去。
/// 图还没下完（附件指针还没有内容、也没有 blurHash）时，video 卡照样是结构化的视频卡，不会先降成品牌壳、下完又升回去。
final class TellomiLinkPreviewImageLevelTest: SignalBaseTest {

    override func setUp() {
        super.setUp()
        write { tx in
            (DependenciesBridge.shared.registrationStateChangeManager as! RegistrationStateChangeManagerImpl).registerForTests(
                localIdentifiers: .forUnitTests,
                tx: tx,
            )
        }
    }

    private static let url = "https://www.bilibili.com/video/BV1YDhJ6ZEL6"
    private static let title = "【演示】给朋友发一条视频链接会长什么样"

    private func richBytes() -> Data {
        let builder = SSKProtoRichContent.builder()
        builder.setKind("video")
        builder.setProvider("bilibili")
        builder.setSchema(1)
        builder.setLevel(2)
        for (key, value) in [("author", "演示UP主"), ("duration_ms", "257000")] {
            let attr = SSKProtoAttr.builder()
            attr.setKey(key)
            attr.setValue(value)
            builder.addAttrs(attr.buildInfallibly())
        }
        return try! builder.buildSerializedData()
    }

    private func makeAcceptedThread() -> TSContactThread {
        return write { tx in
            let thread = ContactThreadFactory().create(transaction: tx)
            if let aci = thread.contactAddress.aci {
                var recipient = DependenciesBridge.shared.recipientFetcher.fetchOrCreate(serviceId: aci, tx: tx)
                SSKEnvironment.shared.profileManagerRef.addRecipientToProfileWhitelist(&recipient, userProfileWriter: .debugging, tx: tx)
            }
            return thread
        }
    }

    private func insertVideoMessage(in thread: TSContactThread) throws -> TSIncomingMessage {
        let authorAci = try XCTUnwrap(thread.contactAddress.aci)
        let rich = richBytes()
        return write { tx in
            let body = DependenciesBridge.shared.attachmentContentValidator.truncatedMessageBodyForInlining(
                MessageBody(text: Self.url, ranges: .empty),
                tx: tx,
            )
            let builder: TSIncomingMessageBuilder = .withDefaultValues(
                thread: thread,
                timestamp: Date.ows_millisecondTimestamp(),
                authorAci: authorAci,
                messageBody: body,
                linkPreview: OWSLinkPreview(urlString: Self.url, title: Self.title, previewDescription: nil, date: nil, rich: rich),
            )
            let message = builder.build()
            message.anyInsert(transaction: tx)
            return message
        }
    }

    /// 图还在路上：附件指针建好了，没有内容，也没有 blurHash（`Preview.image` 在，但现在画不出任何东西）。
    private func attachPendingImage(to message: TSMessage, thread: TSThread, blurHash: String? = nil) throws {
        let image = SSKProtoAttachmentPointer.builder()
        image.setCdnKey("cdnKey-\(UUID().uuidString)")
        image.setCdnNumber(3)
        image.setKey(Randomness.generateRandomBytes(64))
        image.setDigest(Randomness.generateRandomBytes(32))
        image.setContentType(MimeType.imageJpeg.rawValue)
        image.setSize(1234)
        image.setWidth(1280)
        image.setHeight(720)
        if let blurHash {
            image.setBlurHash(blurHash)
        }
        try write { tx in
            _ = try DependenciesBridge.shared.attachmentManager.createAttachmentPointer(
                from: OwnedAttachmentPointerProto(
                    proto: image.buildInfallibly(),
                    owner: .messageLinkPreview(.init(
                        messageRowId: message.sqliteRowId!,
                        receivedAtTimestamp: message.receivedAtTimestamp,
                        threadRowId: thread.sqliteRowId!,
                        isPastEditRevision: false,
                    )),
                ),
                tx: tx,
            )
        }
    }

    /// 图已经下载好：库里是有内容的附件。
    @MainActor
    private func attachDownloadedImage(to message: TSMessage, thread: TSThread) async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let png = UIGraphicsImageRenderer(size: CGSize(width: 1280, height: 720), format: format).image { context in
            UIColor(hue: 0.55, saturation: 0.55, brightness: 0.85, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1280, height: 720))
        }.pngData()!
        let pending = try await DependenciesBridge.shared.attachmentContentValidator.validateDataContents(
            png,
            mimeType: "image/png",
            renderingFlag: .default,
            sourceFilename: nil,
        )
        try write { tx in
            _ = try DependenciesBridge.shared.attachmentManager.createAttachmentStream(
                from: OwnedAttachmentDataSource(
                    dataSource: .pendingAttachment(pending),
                    owner: .messageLinkPreview(.init(
                        messageRowId: message.sqliteRowId!,
                        receivedAtTimestamp: message.receivedAtTimestamp,
                        threadRowId: thread.sqliteRowId!,
                        isPastEditRevision: false,
                    )),
                ),
                tx: tx,
            )
        }
    }

    @MainActor
    private func cardState(_ message: TSMessage) throws -> TellomiLinkPreviewCardState {
        let componentState = try read { tx in
            let latest = try XCTUnwrap(TSMessage.anyFetch(uniqueId: message.uniqueId, transaction: tx) as? TSMessage)
            return try XCTUnwrap(CVLoader.buildStandaloneComponentState(
                interaction: latest,
                spoilerState: SpoilerRenderState(),
                transaction: tx,
            ))
        }
        return try XCTUnwrap(componentState.linkPreview?.state as? TellomiLinkPreviewCardState)
    }

    /// 结构化的视频卡：发送端的标题，副行「作者 · 时长」。品牌壳是平台名 + 类型文字，不是这样。
    private func assertStructuredVideoCard(_ state: TellomiLinkPreviewCardState, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(state.title, Self.title, "\(what)：标题应该是视频标题，不是品牌壳的平台名", file: file, line: line)
        XCTAssertEqual(state.previewDescription, "演示UP主 · 4:17", "\(what)：副行是「作者 · 时长」，不是品牌壳的类型文字", file: file, line: line)
        XCTAssertNil(state.bundledIcon, "\(what)：不是品牌壳，没有随包图标", file: file, line: line)
    }

    @MainActor
    func testAVideoCardIsTheSameCardWhetherOrNotItsImageHasArrived() async throws {
        try XCTSkipUnless(TellomiLinkRegistry.classifier.isAvailable, "随包注册表没加载")
        let thread = makeAcceptedThread()

        // 1. 图还在路上（指针没有内容、没有 blurHash）
        let pending = try insertVideoMessage(in: thread)
        try attachPendingImage(to: pending, thread: thread)
        let whileDownloading = try cardState(pending)
        assertStructuredVideoCard(whileDownloading, "图还没下完")
        XCTAssertEqual(whileDownloading.imageState, .none, "现在没有东西可画")

        // 2. 只有 blurHash（占位图可以画）
        let withBlurHash = try insertVideoMessage(in: thread)
        try attachPendingImage(to: withBlurHash, thread: thread, blurHash: "LEHV6nWB2yk8pyo0adR*.7kCMdnj")
        assertStructuredVideoCard(try cardState(withBlurHash), "只有 blurHash")

        // 3. 图已经下完
        let downloaded = try insertVideoMessage(in: thread)
        try await attachDownloadedImage(to: downloaded, thread: thread)
        let afterDownloading = try cardState(downloaded)
        assertStructuredVideoCard(afterDownloading, "图已下完")
        XCTAssertEqual(afterDownloading.imageState, .loaded)

        // 三种状态下文字一模一样（级别没有跳）
        XCTAssertEqual(whileDownloading.title, afterDownloading.title)
        XCTAssertEqual(whileDownloading.previewDescription, afterDownloading.previewDescription)
        XCTAssertEqual(whileDownloading.displayDomain, afterDownloading.displayDomain)
    }

    /// 对照：预览根本没带图（没有 `Preview.image`）时，video 缺必填的图，才是品牌壳。
    @MainActor
    func testAVideoWithoutAnImageAtAllIsABrandShell() throws {
        try XCTSkipUnless(TellomiLinkRegistry.classifier.isAvailable, "随包注册表没加载")
        let thread = makeAcceptedThread()
        let message = try insertVideoMessage(in: thread)
        let state = try cardState(message)
        XCTAssertNotEqual(state.title, Self.title, "没有图：video 的必填字段不齐，降成品牌壳")
    }
}
