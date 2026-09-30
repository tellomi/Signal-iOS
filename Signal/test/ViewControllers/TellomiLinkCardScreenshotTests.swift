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

/// tellomi/tellomi#1423：收到的链接卡片，按会话页同一条渲染路径（`CVLoader.buildStandaloneRenderItem` + `CVCellView`）排成**真实的消息 cell**，
/// 在内存环境里（不连服务端、不建真账号）截图；同时断言每条消息落在哪一级、要不要只画卡片。
///
/// 截图只在 `TELLOMI_SHOTS=1` 时存（xcodebuild 用 `TEST_RUNNER_TELLOMI_SHOTS=1` 传进来），写到 `TELLOMI_SHOTS_DIR/<屏宽>/`，屏宽取
/// `TELLOMI_SHOT_WIDTHS`（默认 402）。断言总是跑。
final class TellomiLinkCardScreenshotTests: XCTestCase {

    private var oldContext: (any AppContext)!
    private var report = ""

    @MainActor
    override func setUp() {
        super.setUp()
        let setupExpectation = expectation(description: "mock ssk environment setup completed")
        self.oldContext = CurrentAppContext()
        Task {
            let appReadiness = AppReadinessImpl()
            await MockSSKEnvironment.activate(
                appReadiness: appReadiness,
                testDependencies: AppSetup.TestDependencies(
                    groupV2Updates: MockGroupV2Updates(),
                    groupsV2: MockGroupsV2(),
                    messageSender: FakeMessageSender(),
                    networkManager: OWSFakeNetworkManager(appReadiness: appReadiness, netProvider: nil),
                    paymentsCurrencies: MockPaymentsCurrencies(),
                    paymentsHelper: MockPaymentsHelper(),
                    pendingReceiptRecorder: NoopPendingReceiptRecorder(),
                    reachabilityManager: MockSSKReachabilityManager(),
                    remoteConfigManager: StubbableRemoteConfigManager(),
                    signalService: OWSSignalServiceMock(),
                    storageServiceManager: FakeStorageServiceManager(),
                    syncManager: OWSMockSyncManager(),
                    systemStoryManager: SystemStoryManagerMock(),
                    versionedProfiles: MockVersionedProfiles(),
                    webSocketFactory: WebSocketFactoryMock(),
                ),
            )
            setupExpectation.fulfill()
        }
        waitForExpectations(timeout: 30)

        write { tx in
            (DependenciesBridge.shared.registrationStateChangeManager as! RegistrationStateChangeManagerImpl).registerForTests(
                localIdentifiers: .forUnitTests,
                tx: tx,
            )
        }
    }

    @MainActor
    override func tearDown() {
        MockSSKEnvironment.deactivate(oldContext: self.oldContext)
        super.tearDown()
    }

    private func read<T>(block: (DBReadTransaction) throws -> T) rethrows -> T {
        return try SSKEnvironment.shared.databaseStorageRef.read(block: block)
    }

    private func write<T>(block: (DBWriteTransaction) throws -> T) rethrows -> T {
        return try SSKEnvironment.shared.databaseStorageRef.write(block: block)
    }

    private var shooting: Bool { ProcessInfo.processInfo.environment["TELLOMI_SHOTS"] == "1" }

    private var shotWidth: CGFloat {
        let raw = ProcessInfo.processInfo.environment["TELLOMI_SHOT_WIDTHS"] ?? "402"
        return raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }.first.map { CGFloat($0) } ?? 402
    }

    private func shotsDirectory() throws -> URL {
        let root = ProcessInfo.processInfo.environment["TELLOMI_SHOTS_DIR"] ?? NSTemporaryDirectory()
        let url = URL(fileURLWithPath: root).appendingPathComponent("\(Int(shotWidth))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - 样例

    private struct Fixture {
        let name: String
        /// 消息正文；nil = 就是这条链接。
        var body: String?
        let url: String
        var previewTitle: String?
        var previewDescription: String?
        var rich: Rich?
        var hasPreview = true
        /// 预览图的像素尺寸和主色（(色相, 饱和度, 亮度)）；nil = 没有图。
        var image: (size: CGSize, hsb: (CGFloat, CGFloat, CGFloat))?
        /// rust/links 应该给的级别（带着 rich 和图一起问）。
        let expectedLevel: String
        /// 气泡里必须出现的文字（卡片上的标题 / 副行 / 域名行）。
        var cardTexts: [String] = []
        /// 链接文字有没有画在卡片下面：只有一条链接的消息不画（card-visual §3.5）。
        var urlTextShown = false
        /// 图的下半部分（底部约 30%）的颜色；nil = 整张图一个颜色。大图卡的染色取最下面一条，用来验证方向没有上下颠倒。
        var imageBottomHsb: (CGFloat, CGFloat, CGFloat)?
        /// 版式，按 cell 里的视图判：`icon`（右侧 44 pt 图标）、`large`（整宽大图）、`text`（没有图）；nil = 不断言。
        var expectedLayout: String?
        /// 染色的色相范围（HSB 的 H，0…1）；nil = 不染色（保持默认卡片底色）。
        var expectedTintHue: ClosedRange<CGFloat>?

        struct Rich {
            let kind: String
            let provider: String
            let level: UInt32
            let attrs: [(String, String)]
        }
    }

    private static let fixtures: [Fixture] = [
        Fixture(
            name: "bilibili-video",
            url: "https://www.bilibili.com/video/BV1YDhJ6ZEL6",
            previewTitle: "【演示】给朋友发一条视频链接会长什么样",
            previewDescription: "发送端写的描述——不该出现在卡片上",
            rich: .init(kind: "video", provider: "bilibili", level: 2, attrs: [("author", "演示UP主"), ("duration_ms", "257000"), ("published_at", "2025-03-14T10:00:00Z")]),
            image: (CGSize(width: 1280, height: 720), (0.55, 0.55, 0.85)),
            expectedLevel: "structured",
            cardTexts: ["【演示】给朋友发一条视频链接会长什么样", "演示UP主 · 4:17", "bilibili.com"],
        ),
        Fixture(
            name: "taobao-brand",
            url: "https://item.taobao.com/item.htm?id=674169489573",
            previewTitle: "登录",
            rich: .init(kind: "product", provider: "taobao", level: 1, attrs: []),
            expectedLevel: "brand",
            cardTexts: ["Taobao", "Product", "taobao.com"],
            expectedLayout: "text",
        ),
        Fixture(name: "tellomi-user", url: "https://tell.cc/hk881qb", previewTitle: "Tellomi", expectedLevel: "first_party", cardTexts: ["@hk881qb", "Tellomi user"], expectedLayout: "text"),
        Fixture(name: "tellomi-official", url: "https://tellomi.app/download", previewTitle: "Tellomi", expectedLevel: "first_party", cardTexts: ["Tellomi website", "/download"]),
        Fixture(name: "generic", url: "https://www.wikipedia.org/", previewTitle: "Wikipedia", previewDescription: "Wikipedia is a free online encyclopedia, created and edited by volunteers.", expectedLevel: "generic", cardTexts: ["Wikipedia", "wikipedia.org"], expectedLayout: "text"),
        Fixture(
            name: "with-text",
            body: "看看这个 https://www.bilibili.com/video/BV1YDhJ6ZEL6",
            url: "https://www.bilibili.com/video/BV1YDhJ6ZEL6",
            previewTitle: "【演示】给朋友发一条视频链接会长什么样",
            rich: .init(kind: "video", provider: "bilibili", level: 2, attrs: [("author", "演示UP主"), ("duration_ms", "257000")]),
            image: (CGSize(width: 1280, height: 720), (0.55, 0.55, 0.85)),
            expectedLevel: "structured",
            cardTexts: ["演示UP主 · 4:17"],
            urlTextShown: true,
        ),
        Fixture(name: "no-preview", url: "https://www.bilibili.com/video/BV1YDhJ6ZEL6", hasPreview: false, expectedLevel: "plain_link", cardTexts: ["bilibili.com"]),
        Fixture(name: "lookalike", url: "https://www.bi1ibili.com/video/BV1YDhJ6ZEL6", hasPreview: false, expectedLevel: "plain_link", cardTexts: ["bi1ibili.com"]),
        Fixture(
            name: "icon-yellow",
            url: "https://www.meituan.com/",
            previewTitle: "美团",
            image: (CGSize(width: 100, height: 100), (0.13, 0.95, 0.98)),
            expectedLevel: "generic",
            cardTexts: ["美团", "meituan.com"],
            expectedLayout: "icon",
            expectedTintHue: 0.09...0.17,
        ),
        Fixture(
            name: "icon-white",
            url: "https://www.jd.com/",
            previewTitle: "京东",
            image: (CGSize(width: 100, height: 100), (0, 0, 0.98)),
            expectedLevel: "generic",
            cardTexts: ["京东", "jd.com"],
            expectedLayout: "icon",
        ),
        Fixture(
            name: "large-orange",
            url: "https://www.cloudflare.com/",
            previewTitle: "Cloudflare",
            previewDescription: "Connect, protect, and build everywhere.",
            image: (CGSize(width: 1400, height: 800), (0.06, 0.9, 0.95)),
            expectedLevel: "generic",
            cardTexts: ["Cloudflare", "cloudflare.com"],
            expectedLayout: "large",
            expectedTintHue: 0.02...0.10,
        ),
        Fixture(
            name: "large-two-tone",
            url: "https://www.apple.com/",
            previewTitle: "Apple",
            image: (CGSize(width: 1200, height: 630), (0.33, 0.8, 0.8)),
            expectedLevel: "generic",
            cardTexts: ["Apple", "apple.com"],
            imageBottomHsb: (0.78, 0.7, 0.7),
            expectedLayout: "large",
            expectedTintHue: 0.72...0.84,
        ),
    ]

    // MARK: - 用例

    /// 每条样例：真排一次版（画出来的 cell 不崩、有高度），并存截图。
    @MainActor
    func testEveryFixtureRenders() async throws {
        let width = shotWidth
        let thread = write { tx -> TSContactThread in
            let thread = ContactThreadFactory().create(transaction: tx)
            if let aci = thread.contactAddress.aci {
                var recipient = DependenciesBridge.shared.recipientFetcher.fetchOrCreate(serviceId: aci, tx: tx)
                SSKEnvironment.shared.profileManagerRef.addRecipientToProfileWhitelist(&recipient, userProfileWriter: .debugging, tx: tx)
            }
            return thread
        }
        var shots = [UIImage]()
        for fixture in Self.fixtures {
            let message = try await insert(fixture, thread: thread, incoming: true)
            let hosted = try await host(message: message, thread: thread, width: width)
            XCTAssertGreaterThan(hosted.cellView.frame.size.height, 20, "\(fixture.name)：cell 没有高度")
            let card = TellomiLinkRegistry.classifier.classify(
                .init(
                    url: fixture.url,
                    title: fixture.previewTitle,
                    description: fixture.previewDescription,
                    hasImage: fixture.image != nil,
                    rich: fixture.hasPreview ? Self.richBytes(fixture.rich) : nil,
                ),
                body: fixture.body ?? fixture.url,
                isStory: false,
                attachmentContentTypes: [],
            )
            report += "\(fixture.name): cell height \(hosted.cellView.frame.size.height), level \(card?.level.rawValue ?? "nil") (\(card?.reason ?? "-"))\n"
            XCTAssertEqual(card?.level.rawValue, fixture.expectedLevel, "\(fixture.name)：rust/links 给的级别")
            let texts = Self.texts(in: hosted.cellView)
            let joined = texts.joined(separator: "\n")
            for expected in fixture.cardTexts {
                XCTAssertTrue(joined.contains(expected), "\(fixture.name)：气泡里应该有「\(expected)」，实际：\(texts)")
            }
            XCTAssertEqual(Self.containsBodyText(in: hosted.cellView), fixture.urlTextShown, "\(fixture.name)：正文文字该不该画在卡片下面，实际：\(texts)")
            report += "  texts: \(texts)\n"
            checkVisual(fixture, hosted)
            if shooting {
                shots.append(render(hosted))
            }
            hosted.tearDown()
        }
        if shooting {
            try save(stack(shots, width: width), name: "cards-incoming.png")
            try report.write(to: shotsDirectory().deletingLastPathComponent().appendingPathComponent("metrics-cards.txt"), atomically: true, encoding: .utf8)
        }
    }

    /// 染色的卡在深色外观下：同一个色相、更暗的底、字色对比度仍达标；截图存 `cards-incoming-dark.png`。
    @MainActor
    func testTintedCardsFollowTheAppearance() async throws {
        let width = shotWidth
        let thread = write { tx -> TSContactThread in
            let thread = ContactThreadFactory().create(transaction: tx)
            if let aci = thread.contactAddress.aci {
                var recipient = DependenciesBridge.shared.recipientFetcher.fetchOrCreate(serviceId: aci, tx: tx)
                SSKEnvironment.shared.profileManagerRef.addRecipientToProfileWhitelist(&recipient, userProfileWriter: .debugging, tx: tx)
            }
            return thread
        }
        var shots = [UIImage]()
        for fixture in Self.fixtures where fixture.expectedTintHue != nil {
            let message = try await insert(fixture, thread: thread, incoming: true)
            let light = try await host(message: message, thread: thread, width: width)
            let lightBackground = Self.cardBackground(in: light)
            light.tearDown()
            let dark = try await host(message: message, thread: thread, width: width, dark: true)
            let darkBackground = Self.cardBackground(in: dark)
            if let lightBackground, let darkBackground {
                XCTAssertLessThan(Self.luminance(darkBackground), Self.luminance(lightBackground), "\(fixture.name)：深色下的底应该比浅色下更暗")
            } else {
                XCTFail("\(fixture.name)：找不到卡片底色")
            }
            checkVisual(fixture, dark, dark: true)
            if shooting {
                shots.append(render(dark))
            }
            dark.tearDown()
        }
        if shooting {
            try save(stack(shots, width: width), name: "cards-incoming-dark.png")
        }
    }

    /// 版式（按视图判）、卡片底色（染色 / 不染色）、标题字色对比度（染色时 ≥ 4.5:1，card-visual §3.3）。
    @MainActor
    private func checkVisual(_ fixture: Fixture, _ hosted: Hosted, dark: Bool = false) {
        guard let cardView = Self.findView(suffix: "CVLinkPreviewView", in: hosted.cellView) else {
            if fixture.expectedLayout != nil || fixture.expectedTintHue != nil {
                XCTFail("\(fixture.name)：找不到卡片视图")
            }
            return
        }
        let traits = hosted.window.traitCollection
        let imageView = Self.findView(suffix: "CVLinkPreviewImageView", in: cardView)
        if let expectedLayout = fixture.expectedLayout {
            switch expectedLayout {
            case "icon":
                if let imageView {
                    let frame = cardView.convert(imageView.bounds, from: imageView)
                    XCTAssertEqual(frame.size.width, 44, accuracy: 0.6, "\(fixture.name)：图标卡的图标 44 pt，实际 \(frame)")
                    XCTAssertEqual(frame.size.height, 44, accuracy: 0.6, "\(fixture.name)：图标卡的图标 44 pt，实际 \(frame)")
                    XCTAssertEqual(frame.maxX, cardView.bounds.size.width - 10, accuracy: 1, "\(fixture.name)：图标在右侧，实际 \(frame) / 卡宽 \(cardView.bounds.size.width)")
                } else {
                    XCTFail("\(fixture.name)：图标卡应该有图")
                }
            case "large":
                if let imageView {
                    let frame = cardView.convert(imageView.bounds, from: imageView)
                    XCTAssertEqual(frame.size.width, cardView.bounds.size.width, accuracy: 1, "\(fixture.name)：大图卡的图占满卡宽，实际 \(frame)")
                    XCTAssertEqual(frame.minY, 0, accuracy: 1, "\(fixture.name)：大图在上，实际 \(frame)")
                    XCTAssertGreaterThanOrEqual(frame.size.height, frame.size.width / 1.91 - 1, "\(fixture.name)：图的宽高比不超过 1.91:1，实际 \(frame)")
                    XCTAssertLessThanOrEqual(frame.size.height, frame.size.width + 1, "\(fixture.name)：图的宽高比不低于 1:1，实际 \(frame)")
                } else {
                    XCTFail("\(fixture.name)：大图卡应该有图")
                }
            default:
                XCTAssertNil(imageView, "\(fixture.name)：这张卡没有图")
            }
        }
        guard let background = cardView.backgroundColor?.resolvedColor(with: traits) else {
            XCTFail("\(fixture.name)：卡片没有底色")
            return
        }
        if let hueRange = fixture.expectedTintHue {
            var hue: CGFloat = 0
            var saturation: CGFloat = 0
            var brightness: CGFloat = 0
            var alpha: CGFloat = 0
            background.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
            XCTAssertTrue(hueRange.contains(hue), "\(fixture.name)：底色色相应在 \(hueRange)，实际 \(hue)（\(dark ? "深" : "浅")色）")
            XCTAssertGreaterThan(saturation, 0.2, "\(fixture.name)：染色的底色不该是灰的，实际饱和度 \(saturation)")
            if let title = fixture.previewTitle, let label = Self.findLabel(text: title, in: cardView) {
                let text = label.textColor.resolvedColor(with: traits)
                let ratio = Self.contrast(text, background)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(fixture.name)：标题对比度应 ≥ 4.5:1，实际 \(ratio)（\(dark ? "深" : "浅")色）")
            } else {
                XCTFail("\(fixture.name)：找不到标题")
            }
        } else if fixture.expectedLayout != nil {
            let plain = UIColor.Signal.LightBase.fillTertiary.resolvedColor(with: traits)
            XCTAssertLessThan(Self.distance(background, plain), 0.02, "\(fixture.name)：不该染色，实际底色 \(background)")
        }
    }

    private static func cardBackground(in hosted: Hosted) -> UIColor? {
        findView(suffix: "CVLinkPreviewView", in: hosted.cellView)?.backgroundColor?.resolvedColor(with: hosted.window.traitCollection)
    }

    private static func findView(suffix: String, in view: UIView) -> UIView? {
        if NSStringFromClass(type(of: view)).hasSuffix(suffix) {
            return view
        }
        for subview in view.subviews {
            if let found = findView(suffix: suffix, in: subview) {
                return found
            }
        }
        return nil
    }

    private static func findLabel(text: String, in view: UIView) -> UILabel? {
        if let label = view as? UILabel, (label.attributedText?.string ?? label.text) == text {
            return label
        }
        for subview in view.subviews {
            if let found = findLabel(text: text, in: subview) {
                return found
            }
        }
        return nil
    }

    private static func rgb(_ color: UIColor) -> (CGFloat, CGFloat, CGFloat) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (red, green, blue)
    }

    /// WCAG 相对亮度。
    private static func luminance(_ color: UIColor) -> CGFloat {
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let (red, green, blue) = rgb(color)
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    private static func contrast(_ a: UIColor, _ b: UIColor) -> CGFloat {
        let lighter = max(luminance(a), luminance(b))
        let darker = min(luminance(a), luminance(b))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func distance(_ a: UIColor, _ b: UIColor) -> CGFloat {
        let (r1, g1, b1) = rgb(a)
        let (r2, g2, b2) = rgb(b)
        return max(abs(r1 - r2), abs(g1 - g2), abs(b1 - b2))
    }

    // MARK: - 建消息

    private static func richBytes(_ rich: Fixture.Rich?) -> Data? {
        guard let rich else {
            return nil
        }
        let builder = SSKProtoRichContent.builder()
        builder.setKind(rich.kind)
        builder.setProvider(rich.provider)
        builder.setSchema(1)
        builder.setLevel(rich.level)
        for (key, value) in rich.attrs {
            let attr = SSKProtoAttr.builder()
            attr.setKey(key)
            attr.setValue(value)
            builder.addAttrs(attr.buildInfallibly())
        }
        return try? builder.buildSerializedData()
    }

    @MainActor
    private func insert(_ fixture: Fixture, thread: TSContactThread, incoming: Bool) async throws -> TSMessage {
        let richBytes = Self.richBytes(fixture.rich)
        let authorAci = try XCTUnwrap(thread.contactAddress.aci)
        let message: TSIncomingMessage = write { tx in
            let body = DependenciesBridge.shared.attachmentContentValidator.truncatedMessageBodyForInlining(
                MessageBody(text: fixture.body ?? fixture.url, ranges: .empty),
                tx: tx,
            )
            let linkPreview = fixture.hasPreview
                ? OWSLinkPreview(
                    urlString: fixture.url,
                    title: fixture.previewTitle,
                    previewDescription: fixture.previewDescription,
                    date: nil,
                    rich: richBytes,
                )
                : nil
            let builder: TSIncomingMessageBuilder = .withDefaultValues(
                thread: thread,
                timestamp: Date.ows_millisecondTimestamp(),
                authorAci: authorAci,
                messageBody: body,
                linkPreview: linkPreview,
            )
            let message = builder.build()
            message.anyInsert(transaction: tx)
            return message
        }
        if fixture.hasPreview, let image = fixture.image {
            let pending = try await DependenciesBridge.shared.attachmentContentValidator.validateDataContents(
                png(size: image.size, hsb: image.hsb, bottomHsb: fixture.imageBottomHsb),
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
        return message
    }

    private func png(size: CGSize, hsb: (CGFloat, CGFloat, CGFloat), bottomHsb: (CGFloat, CGFloat, CGFloat)? = nil) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(hue: hsb.0, saturation: hsb.1, brightness: hsb.2, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            if let bottomHsb {
                UIColor(hue: bottomHsb.0, saturation: bottomHsb.1, brightness: bottomHsb.2, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: size.height * 0.7, width: size.width, height: size.height * 0.3))
            }
        }.pngData()!
    }

    // MARK: - Hosting（同 AlbumViewerScreenshotTests）

    private struct Hosted {
        let window: UIWindow
        let cellView: CVCellView
        let delegate: MockConversationView

        func tearDown() {
            cellView.isCellVisible = false
            window.isHidden = true
        }
    }

    @MainActor
    private func host(message: TSMessage, thread: TSThread, width: CGFloat, dark: Bool = false) async throws -> Hosted {
        let renderItem = try read { (tx: DBReadTransaction) throws -> CVRenderItem in
            let chatColor = DependenciesBridge.shared.chatColorSettingStore.resolvedChatColor(for: thread, tx: tx)
            let conversationStyle = ConversationStyle(
                type: .`default`,
                thread: thread,
                viewWidth: width,
                hasWallpaper: false,
                shouldDimWallpaperInDarkMode: false,
                chatColor: chatColor,
            )
            let latest = try XCTUnwrap(TSMessage.anyFetch(uniqueId: message.uniqueId, transaction: tx) as? TSMessage)
            return try XCTUnwrap(CVLoader.buildStandaloneRenderItem(
                interaction: latest,
                thread: thread,
                conversationStyle: conversationStyle,
                spoilerState: SpoilerRenderState(),
                groupNameColors: GroupNameColors.forThread(thread),
                transaction: tx,
            ))
        }

        let delegate = MockConversationView(model: .init(items: []), hasWallpaper: false, customChatColor: nil)
        let cellHeight = renderItem.cellMeasurement.cellSize.height
        let window = UIWindow(frame: CGRect(x: 0, y: 150, width: width, height: cellHeight + 24))
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.backgroundColor = dark ? .black : .white
        let cellView = CVCellView()
        cellView.configure(renderItem: renderItem, componentDelegate: delegate)
        cellView.frame = CGRect(x: 0, y: 12, width: width, height: cellHeight)
        window.addSubview(cellView)
        window.isHidden = false
        cellView.isCellVisible = true
        window.layoutIfNeeded()

        let hosted = Hosted(window: window, cellView: cellView, delegate: delegate)
        // 缩略图是异步解出来的
        for _ in 0..<8 {
            try await Task.sleep(nanoseconds: 150_000_000)
            window.layoutIfNeeded()
        }
        return hosted
    }

    @MainActor
    private func render(_ hosted: Hosted) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(bounds: hosted.window.bounds, format: format).image { _ in
            hosted.window.drawHierarchy(in: hosted.window.bounds, afterScreenUpdates: true)
        }
    }

    private func stack(_ images: [UIImage], width: CGFloat) -> UIImage {
        let height = images.reduce(0) { $0 + $1.size.height }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: max(1, height)), format: format).image { context in
            Theme.backgroundColor.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            var y: CGFloat = 0
            for image in images {
                image.draw(at: CGPoint(x: 0, y: y))
                y += image.size.height
            }
        }
    }

    /// 正文文字是 `CVTextLabel` 自己的（私有）视图画的，不是 UILabel / UITextView；有没有这个视图就是有没有画正文。
    private static func containsBodyText(in view: UIView) -> Bool {
        if NSStringFromClass(type(of: view)).contains("CVTextLabel") {
            return true
        }
        return view.subviews.contains { containsBodyText(in: $0) }
    }

    /// cell 里所有标签和文本视图上的文字。
    private static func texts(in view: UIView) -> [String] {
        var result = [String]()
        if let label = view as? UILabel, let text = label.attributedText?.string ?? label.text, !text.isEmpty {
            result.append(text)
        } else if let textView = view as? UITextView, !textView.attributedText.string.isEmpty {
            result.append(textView.attributedText.string)
        }
        for subview in view.subviews {
            result += texts(in: subview)
        }
        return result
    }

    private func save(_ image: UIImage, name: String) throws {
        let url = try shotsDirectory().appendingPathComponent(name)
        try XCTUnwrap(image.pngData()).write(to: url)
        report += "saved \(url.path)\n"
    }
}
