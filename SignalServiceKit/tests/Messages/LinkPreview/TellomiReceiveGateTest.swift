//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import LibSignalClient
import XCTest

@testable import SignalServiceKit

/// ADR-0063 §5.1 铁律 4、§6.1「超大、畸形的 RichContent」、§7.4，口径 S2：收到带预览的消息、写库之前，
/// 预览留不留、`rich` 留不留交给 rust/links 的 `receive_check`；预览图附件只在卡片确实要显示图的时候才建（判的是渲染同一个 `classify`）。
/// 收到的 `rich` 原始字节落库不变（`TellomiRichContentTest`）；`receive_check` 出不了答案时行为和改动前一样，绝不让收消息失败。
final class TellomiReceiveGateTest: XCTestCase {

    // MARK: - 假注册表

    /// 记下每次问了什么，答案由测试给。
    private final class FakeRegistry: TellomiLinkClassifying {
        struct Call {
            let preview: String
            let body: String
            let message: String
        }

        var version: UInt64 = 1
        var receive: Result<String, Error> = .success(#"{"keep_preview":true,"keep_rich":true}"#)
        var card: Result<String, Error> = .success(#"{"level":"generic","title":"标题","domain":"example.org","show_image":true}"#)
        private(set) var receiveCalls = [Call]()
        private(set) var classifyCalls = [Call]()

        func classify(preview: String, body: String, message: String) throws -> String {
            classifyCalls.append(Call(preview: preview, body: body, message: message))
            return try card.get()
        }

        func receiveCheck(preview: String, body: String, message: String) throws -> String {
            receiveCalls.append(Call(preview: preview, body: body, message: message))
            return try receive.get()
        }

        func openPlan(_ url: String) throws -> String { #"{"steps":[],"label":"open_link"}"# }
    }

    private struct Boom: Error {}

    // MARK: - 夹具

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

    /// key = 1000 << 3 | 2，再是长度和值。
    private static func field1000(_ rich: Data) -> Data {
        return Data([0xC2, 0x3E]) + varint(rich.count) + rich
    }

    private static func richBytes(kind: String, provider: String, level: UInt32, attrs: [(String, String)] = [], unknownField: Bool = false) -> Data {
        let builder = SSKProtoRichContent.builder()
        builder.setKind(kind)
        builder.setProvider(provider)
        builder.setSchema(1)
        builder.setLevel(level)
        for (key, value) in attrs {
            let attr = SSKProtoAttr.builder()
            attr.setKey(key)
            attr.setValue(value)
            builder.addAttrs(attr.buildInfallibly())
        }
        var data = try! builder.buildSerializedData()
        if unknownField {
            // 本机不认识的字段 99（length-delimited）：原样落库要带着它。
            let payload = Data("from a newer client".utf8)
            data += Data([0x9A, 0x06]) + varint(payload.count) + payload
        }
        return data
    }

    private struct Received {
        var url: String
        /// 正文；nil = 就是这条链接。
        var body: String?
        var title: String? = "某个标题"
        var previewDescription: String?
        var rich: Data?
        var image = true
        /// 消息自己带的附件的 content type（长文本 `text/x-signal-plain` 允许出预览）。
        var attachmentTypes = [String]()
    }

    private func imagePointer() -> SSKProtoAttachmentPointer {
        let image = SSKProtoAttachmentPointer.builder()
        image.setCdnKey("cdnKey")
        image.setCdnNumber(2)
        image.setKey(Data(repeating: 1, count: 32))
        image.setDigest(Data(repeating: 2, count: 32))
        image.setContentType(MimeType.imageJpeg.rawValue)
        image.setSize(34)
        return image.buildInfallibly()
    }

    /// 发送端把预览放上线的样子：snapshot，再是 1000 号字段的原始字节。
    private func dataMessage(_ received: Received) throws -> SSKProtoDataMessage {
        let preview = SSKProtoPreview.builder(url: received.url)
        if let title = received.title {
            preview.setTitle(title)
        }
        if let previewDescription = received.previewDescription {
            preview.setPreviewDescription(previewDescription)
        }
        if received.image {
            preview.setImage(imagePointer())
        }
        var bytes = try preview.buildSerializedData()
        if let rich = received.rich {
            bytes += Self.field1000(rich)
        }
        let builder = SSKProtoDataMessage.builder()
        builder.setBody(received.body ?? received.url)
        builder.addPreview(try SSKProtoPreview(serializedData: bytes))
        for contentType in received.attachmentTypes {
            let attachment = SSKProtoAttachmentPointer.builder()
            attachment.setCdnKey("attachmentKey")
            attachment.setCdnNumber(2)
            attachment.setContentType(contentType)
            builder.addAttachments(attachment.buildInfallibly())
        }
        return try builder.build()
    }

    private func manager(_ classifier: TellomiLinkClassifier) -> LinkPreviewManagerImpl {
        return LinkPreviewManagerImpl(
            attachmentStore: AttachmentStore(),
            attachmentValidator: AttachmentContentValidatorMock(),
            db: InMemoryDB(),
            linkPreviewSettingStore: LinkPreviewSettingStore.mock(),
            tellomiClassifier: classifier,
        )
    }

    private func validate(_ received: Received, with classifier: TellomiLinkClassifier) throws -> ValidatedLinkPreviewProto {
        let message = try dataMessage(received)
        return try manager(classifier).validateAndBuildLinkPreview(from: message.preview[0], dataMessage: message)
    }

    private func fake(_ registry: FakeRegistry) -> TellomiLinkClassifier {
        return TellomiLinkClassifier(registry: registry)
    }

    private func json(_ text: String) throws -> [String: Any] {
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], text)
    }

    private static let url = "https://www.wikipedia.org/wiki/Tellomi"

    // MARK: - receive_check：预览留不留

    func testAPreviewTheReceiveCheckRefusesIsDroppedAndTheMessageIsKept() throws {
        let registry = FakeRegistry()
        registry.receive = .success(#"{"keep_preview":false,"keep_rich":false}"#)
        XCTAssertThrowsError(try validate(Received(url: Self.url), with: fake(registry))) { error in
            // MessageReceiver 对这个错误的处理是「丢掉预览，消息照收」
            guard case LinkPreviewError.invalidPreview = error else {
                return XCTFail("\(error)")
            }
        }
        XCTAssertEqual(registry.receiveCalls.count, 1)
        XCTAssertEqual(registry.classifyCalls.count, 0, "预览都不要了，不用再问图")
    }

    func testRichThatFailsTheCheckIsDroppedButTheSnapshotAndTheImageStay() throws {
        let registry = FakeRegistry()
        registry.receive = .success(#"{"keep_preview":true,"keep_rich":false}"#)
        let rich = Self.richBytes(kind: "video", provider: "bilibili", level: 2)
        let validated = try validate(Received(url: Self.url, title: "快照标题", previewDescription: "快照描述", rich: rich), with: fake(registry))
        XCTAssertNil(validated.preview.rich, "超长 / 畸形的 rich 整个丢掉、不落库（§6.1）")
        XCTAssertEqual(validated.preview.title, "快照标题")
        XCTAssertEqual(validated.preview.previewDescription, "快照描述")
        XCTAssertEqual(validated.preview.urlString, Self.url)
        XCTAssertNotNil(validated.imageProto)
    }

    func testRichThatPassesIsStoredByteForByteIncludingFieldsWeDoNotKnow() throws {
        let registry = FakeRegistry()
        let rich = Self.richBytes(kind: "video", provider: "bilibili", level: 2, attrs: [("author", "某位 UP 主")], unknownField: true)
        let validated = try validate(Received(url: Self.url, rich: rich), with: fake(registry))
        XCTAssertEqual(validated.preview.rich, rich)
    }

    func testTheReceiveCheckIsGivenWhatTheMessageCarries() throws {
        let registry = FakeRegistry()
        let rich = Self.richBytes(kind: "video", provider: "bilibili", level: 2)
        _ = try validate(
            Received(url: Self.url, body: "看这个 \(Self.url) 很好", rich: rich, attachmentTypes: ["text/x-signal-plain"]),
            with: fake(registry),
        )
        let call = try XCTUnwrap(registry.receiveCalls.first)
        XCTAssertEqual(call.body, "看这个 \(Self.url) 很好")
        let preview = try json(call.preview)
        XCTAssertEqual(preview["url"] as? String, Self.url)
        XCTAssertEqual(preview["rich"] as? String, rich.map { String(format: "%02x", $0) }.joined(), "rich 是收到的原始字节（十六进制）")
        let message = try json(call.message)
        XCTAssertEqual(message["is_story"] as? Bool, false)
        XCTAssertEqual(message["attachment_content_types"] as? [String], ["text/x-signal-plain"])
    }

    // MARK: - 出不了答案：照改动前

    /// 三种「没有判定」：注册表没装上、rust/links 出错、答案读不懂。
    private func classifiersWithoutAnAnswer() -> [(String, TellomiLinkClassifier)] {
        let failing = FakeRegistry()
        failing.receive = .failure(Boom())
        failing.card = .failure(Boom())
        let garbled = FakeRegistry()
        garbled.receive = .success("not json")
        garbled.card = .success("not json")
        return [
            ("没有注册表", TellomiLinkClassifier(registry: nil)),
            ("rust/links 出错", fake(failing)),
            ("答案读不懂", fake(garbled)),
        ]
    }

    func testWithoutAnAnswerThePreviewRichAndImageAreKeptAsBefore() throws {
        let rich = Self.richBytes(kind: "video", provider: "bilibili", level: 2, unknownField: true)
        for (name, classifier) in classifiersWithoutAnAnswer() {
            let validated = try validate(Received(url: Self.url, rich: rich), with: classifier)
            XCTAssertEqual(validated.preview.rich, rich, name)
            XCTAssertEqual(validated.preview.title, "某个标题", name)
            XCTAssertNotNil(validated.imageProto, "\(name)：判不出就照旧建图")
        }
    }

    func testWithoutAnAnswerTheUpstreamSubstringRuleStillApplies() throws {
        for (name, classifier) in classifiersWithoutAnAnswer() {
            XCTAssertThrowsError(try validate(Received(url: Self.url, body: "没有链接"), with: classifier), name) { error in
                guard case LinkPreviewError.invalidPreview = error else {
                    return XCTFail("\(name)：\(error)")
                }
            }
        }
    }

    // MARK: - 预览图门控

    func testTheImageIsNotKeptWhenTheCardWillNotShowIt() throws {
        let registry = FakeRegistry()
        registry.card = .success(#"{"level":"brand","show_image":false,"domain":"taobao.com"}"#)
        let validated = try validate(Received(url: Self.url, title: "快照标题"), with: fake(registry))
        XCTAssertNil(validated.imageProto, "卡片不显示图 → 不建附件指针，也就不会下载")
        XCTAssertEqual(validated.preview.title, "快照标题", "消息和快照照收")
    }

    func testTheImageIsKeptWhenTheCardShowsIt() throws {
        let registry = FakeRegistry()
        registry.card = .success(#"{"level":"structured","show_image":true,"domain":"bilibili.com"}"#)
        XCTAssertNotNil(try validate(Received(url: Self.url), with: fake(registry)).imageProto)
    }

    func testAPreviewWithoutAnImageAsksNothingAboutIt() throws {
        let registry = FakeRegistry()
        registry.card = .success(#"{"level":"brand","show_image":false}"#)
        let validated = try validate(Received(url: Self.url, image: false), with: fake(registry))
        XCTAssertNil(validated.imageProto)
        XCTAssertEqual(registry.classifyCalls.count, 0)
    }

    func testTheImageQuestionIsTheOneRenderingAsks() throws {
        let registry = FakeRegistry()
        registry.card = .success(#"{"level":"generic","show_image":true}"#)
        let rich = Self.richBytes(kind: "video", provider: "bilibili", level: 2)
        _ = try validate(
            Received(url: Self.url, body: "看这个 \(Self.url)", title: "  标题\n第二行  ", previewDescription: "描述", rich: rich, attachmentTypes: ["text/x-signal-plain"]),
            with: fake(registry),
        )
        let call = try XCTUnwrap(registry.classifyCalls.first)
        XCTAssertEqual(call.body, "看这个 \(Self.url)")
        let preview = try json(call.preview)
        XCTAssertEqual(preview["url"] as? String, Self.url)
        XCTAssertEqual(preview["has_image"] as? Bool, true)
        XCTAssertEqual(preview["description"] as? String, "描述")
        XCTAssertEqual(preview["rich"] as? String, rich.map { String(format: "%02x", $0) }.joined())
        // 标题是落库的那一份（上游规整过），渲染时问的也是它
        XCTAssertEqual(preview["title"] as? String, "标题\n第二行")
        let message = try json(call.message)
        XCTAssertEqual(message["is_story"] as? Bool, false)
        XCTAssertEqual(message["attachment_content_types"] as? [String], ["text/x-signal-plain"])
    }

    func testAStoryPreviewIsNotGated() throws {
        let registry = FakeRegistry()
        registry.card = .success(#"{"level":"brand","show_image":false}"#)
        registry.receive = .success(#"{"keep_preview":false,"keep_rich":false}"#)
        let proto = try dataMessage(Received(url: Self.url)).preview[0]
        let validated = try manager(fake(registry)).validateAndBuildStoryLinkPreview(from: proto)
        XCTAssertNotNil(validated.imageProto, "故事里的预览渲染时不走 classify，收到时也不门控")
        XCTAssertEqual(registry.receiveCalls.count, 0)
        XCTAssertEqual(registry.classifyCalls.count, 0)
    }
}

// MARK: - 随包的真注册表

/// 同一批判断，交给随包的真注册表（`rust/links` 的真实规则，不是假答案）。
final class TellomiReceiveGateBundledRegistryTest: XCTestCase {

    private func manager() -> LinkPreviewManagerImpl {
        return LinkPreviewManagerImpl(
            attachmentStore: AttachmentStore(),
            attachmentValidator: AttachmentContentValidatorMock(),
            db: InMemoryDB(),
            linkPreviewSettingStore: LinkPreviewSettingStore.mock(),
            tellomiClassifier: TellomiLinkRegistry.classifier,
        )
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(TellomiLinkRegistry.classifier.isAvailable, "随包注册表没加载")
    }

    private struct Case {
        var url: String
        var body: String?
        var title: String? = "某个标题"
        var rich: Data?
        var image = true
    }

    private func validate(_ received: Case) throws -> ValidatedLinkPreviewProto {
        let preview = SSKProtoPreview.builder(url: received.url)
        if let title = received.title {
            preview.setTitle(title)
        }
        if received.image {
            let image = SSKProtoAttachmentPointer.builder()
            image.setCdnKey("cdnKey")
            image.setCdnNumber(2)
            image.setKey(Data(repeating: 1, count: 32))
            image.setDigest(Data(repeating: 2, count: 32))
            image.setContentType(MimeType.imageJpeg.rawValue)
            image.setSize(34)
            preview.setImage(image.buildInfallibly())
        }
        var bytes = try preview.buildSerializedData()
        if let rich = received.rich {
            bytes += Data([0xC2, 0x3E]) + Self.varint(rich.count) + rich
        }
        let builder = SSKProtoDataMessage.builder()
        builder.setBody(received.body ?? received.url)
        builder.addPreview(try SSKProtoPreview(serializedData: bytes))
        let message = try builder.build()
        return try manager().validateAndBuildLinkPreview(from: message.preview[0], dataMessage: message)
    }

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

    private static func rich(kind: String, provider: String, level: UInt32, attrs: [(String, String)] = []) -> Data {
        let builder = SSKProtoRichContent.builder()
        builder.setKind(kind)
        builder.setProvider(provider)
        builder.setSchema(1)
        builder.setLevel(level)
        for (key, value) in attrs {
            let attr = SSKProtoAttr.builder()
            attr.setKey(key)
            attr.setValue(value)
            builder.addAttrs(attr.buildInfallibly())
        }
        return try! builder.buildSerializedData()
    }

    // MARK: - 预览图：要显示才建

    func testCardsThatShowTheirImageKeepIt() throws {
        // 结构化的视频：图必填，卡片显示它
        let video = try validate(Case(
            url: "https://www.bilibili.com/video/BV1GJ411x7h7",
            rich: Self.rich(kind: "video", provider: "bilibili", level: 2, attrs: [("author", "某位 UP 主"), ("duration_ms", "212000")]),
        ))
        XCTAssertNotNil(video.imageProto, "结构化的视频要图")
        // 没有 provider 的普通网页（generic）：Signal 原来的预览，带图
        XCTAssertNotNil(try validate(Case(url: "https://www.wikipedia.org/wiki/Tellomi")).imageProto)
    }

    func testCardsThatDoNotShowAnImageDoNotCreateAPointerForIt() throws {
        // 品牌壳：图是随包图标，不用发送端的图
        let shell = try validate(Case(url: "https://item.taobao.com/item.htm?id=674169489573", rich: Self.rich(kind: "product", provider: "taobao", level: 1)))
        XCTAssertNil(shell.imageProto, "品牌壳不下载发送端的图")
        // 支付金融：品牌壳
        XCTAssertNil(try validate(Case(url: "https://render.alipay.com/p/s/i/", rich: Self.rich(kind: "web", provider: "alipay", level: 1))).imageProto)
        // 纯链接：没有标题的预览
        XCTAssertNil(try validate(Case(url: "https://www.wikipedia.org/wiki/Tellomi", title: nil)).imageProto)
        // 冒充知名域名：降成纯链接
        XCTAssertNil(try validate(Case(url: "https://www.bi1ibili.com/video/BV1YDhJ6ZEL6")).imageProto)
        // 第一方：用户卡、官网卡的头像 / 标志都是本地的
        XCTAssertNil(try validate(Case(url: "https://tell.cc/hk881qb", rich: Self.rich(kind: "tellomi.user", provider: "tellomi", level: 1))).imageProto)
        XCTAssertNil(try validate(Case(url: "https://tellomi.app/download", rich: Self.rich(kind: "tellomi.official", provider: "tellomi", level: 1))).imageProto)
    }

    func testGroupAndStickerCardsKeepTheirImageBecauseThatIsTheirAvatar() throws {
        let masterKey = try GroupMasterKey(contents: Data(repeating: 7, count: 32))
        let groupUrl = try GroupInviteLink(masterKey: masterKey, inviteLinkPassword: Data(repeating: 7, count: 16)).url().absoluteString
        let group = try validate(Case(url: groupUrl, title: "周末爬山群", rich: Self.rich(kind: "tellomi.group", provider: "tellomi", level: 1)))
        XCTAssertNotNil(group.imageProto, "群头像是这张卡的图")
    }

    func testTheRichAndTheSnapshotOfAShellAreStillStored() throws {
        let rich = Self.rich(kind: "product", provider: "taobao", level: 1)
        let shell = try validate(Case(url: "https://item.taobao.com/item.htm?id=674169489573", title: "商品标题", rich: rich))
        XCTAssertNil(shell.imageProto)
        XCTAssertEqual(shell.preview.rich, rich, "rich 原始字节落库不变（§7.4）")
        XCTAssertEqual(shell.preview.title, "商品标题")
    }

    // MARK: - rich 超长 / 畸形

    func testAnOversizedRichIsDroppedAndTheSnapshotStays() throws {
        let tooLong = String(repeating: "k", count: 33) // kind ≤ 32（§6.1）
        let validated = try validate(Case(
            url: "https://www.bilibili.com/video/BV1GJ411x7h7",
            title: "快照标题",
            rich: Self.rich(kind: tooLong, provider: "bilibili", level: 2),
        ))
        XCTAssertNil(validated.preview.rich, "超长的 rich 不落库")
        XCTAssertEqual(validated.preview.title, "快照标题")
        XCTAssertEqual(validated.preview.urlString, "https://www.bilibili.com/video/BV1GJ411x7h7")
    }

    // MARK: - 链接在正文里：并进 receive_check

    func testTheLinkMustBeInTheBodyAtABoundary() throws {
        // 上游的子串检查会认「更长的网址的前缀」：这里不认
        XCTAssertThrowsError(try validate(Case(url: "https://www.wikipedia.org", body: "点这里 https://www.wikipedia.org.evil.cn/login"))) { error in
            guard case LinkPreviewError.invalidPreview = error else {
                return XCTFail("\(error)")
            }
        }
        XCTAssertThrowsError(try validate(Case(url: "https://www.wikipedia.org/wiki/Tellomi", body: "没有链接"))) { error in
            guard case LinkPreviewError.invalidPreview = error else {
                return XCTFail("\(error)")
            }
        }
    }

    /// 审计 I19 的例子：`Preview.url` 末尾有 `/`、正文里没有（或反过来）。Rust 和 Android 认，iOS 上游的子串检查不认。
    func testATrailingSlashOnEitherSideStillCounts() throws {
        XCTAssertNoThrow(try validate(Case(url: "https://www.wikipedia.org/", body: "看看 https://www.wikipedia.org 吧")))
        XCTAssertNoThrow(try validate(Case(url: "https://www.wikipedia.org", body: "看看 https://www.wikipedia.org/ 吧")))
        // 句末的标点不算网址的一部分
        XCTAssertNoThrow(try validate(Case(url: "https://www.wikipedia.org/wiki/Tellomi", body: "看看 https://www.wikipedia.org/wiki/Tellomi.")))
    }
}
