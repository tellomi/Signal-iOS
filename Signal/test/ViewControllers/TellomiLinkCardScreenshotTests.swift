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
        ),
        Fixture(
            name: "taobao-brand",
            url: "https://item.taobao.com/item.htm?id=674169489573",
            previewTitle: "登录",
            rich: .init(kind: "product", provider: "taobao", level: 1, attrs: []),
            expectedLevel: "brand",
        ),
        Fixture(name: "tellomi-user", url: "https://tell.cc/hk881qb", previewTitle: "Tellomi", expectedLevel: "first_party"),
        Fixture(name: "tellomi-official", url: "https://tellomi.app/download", previewTitle: "Tellomi", expectedLevel: "first_party"),
        Fixture(name: "generic", url: "https://www.wikipedia.org/", previewTitle: "Wikipedia", previewDescription: "Wikipedia is a free online encyclopedia, created and edited by volunteers.", expectedLevel: "generic"),
        Fixture(
            name: "with-text",
            body: "看看这个 https://www.bilibili.com/video/BV1YDhJ6ZEL6",
            url: "https://www.bilibili.com/video/BV1YDhJ6ZEL6",
            previewTitle: "【演示】给朋友发一条视频链接会长什么样",
            rich: .init(kind: "video", provider: "bilibili", level: 2, attrs: [("author", "演示UP主"), ("duration_ms", "257000")]),
            image: (CGSize(width: 1280, height: 720), (0.55, 0.55, 0.85)),
            expectedLevel: "structured",
        ),
        Fixture(name: "no-preview", url: "https://www.bilibili.com/video/BV1YDhJ6ZEL6", hasPreview: false, expectedLevel: "plain_link"),
        Fixture(name: "lookalike", url: "https://www.bi1ibili.com/video/BV1YDhJ6ZEL6", hasPreview: false, expectedLevel: "plain_link"),
        Fixture(name: "icon-yellow", url: "https://www.meituan.com/", previewTitle: "美团", image: (CGSize(width: 100, height: 100), (0.13, 0.95, 0.98)), expectedLevel: "generic"),
        Fixture(name: "large-orange", url: "https://www.cloudflare.com/", previewTitle: "Cloudflare", previewDescription: "Connect, protect, and build everywhere.", image: (CGSize(width: 1400, height: 800), (0.06, 0.9, 0.95)), expectedLevel: "generic"),
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
                png(size: image.size, hsb: image.hsb),
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

    private func png(size: CGSize, hsb: (CGFloat, CGFloat, CGFloat)) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(hue: hsb.0, saturation: hsb.1, brightness: hsb.2, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
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
    private func host(message: TSMessage, thread: TSThread, width: CGFloat) async throws -> Hosted {
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
        window.backgroundColor = Theme.backgroundColor
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

    private func save(_ image: UIImage, name: String) throws {
        let url = try shotsDirectory().appendingPathComponent(name)
        try XCTUnwrap(image.pngData()).write(to: url)
        report += "saved \(url.path)\n"
    }
}
