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

/// tellomi/tellomi#1257：横滑相册在**真实的消息 cell**（CVComponentMessage → CVCellView）里的判据与截图。
///
/// SignalBaseTest 的内存环境里建会话和带真实图片数据的相册消息（不连服务端、不建真账号），用
/// `CVLoader.buildStandaloneRenderItem`（消息详情页、聊天颜色预览走的同一条路）按指定屏宽排版，断言几何与手势归属，顺手截图。
///
/// 只在环境变量 `TELLOMI_SHOTS=1` 时跑（xcodebuild 用 `TEST_RUNNER_TELLOMI_SHOTS=1` 传进来）；
/// 截图写到 `TELLOMI_SHOTS_DIR/<屏宽>/`，屏宽取 `TELLOMI_SHOT_WIDTHS`（逗号分隔，默认 402,440,375）。
final class AlbumCarouselScreenshotTests: XCTestCase {

    private var report = ""
    private var oldContext: (any AppContext)!

    /// 同 SignalBaseTest，但通讯录与资料管理器用真的：群消息要画发送者头像，假的那两个在头像路径上会被强转崩掉。
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
                    networkManager: OWSFakeNetworkManager(appReadiness: appReadiness, libsignalNet: nil),
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

    private var shotWidths: [CGFloat] {
        let raw = ProcessInfo.processInfo.environment["TELLOMI_SHOT_WIDTHS"] ?? "402,440,375"
        return raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }.map { CGFloat($0) }
    }

    private func shotsDirectory(width: CGFloat) throws -> URL {
        let root = ProcessInfo.processInfo.environment["TELLOMI_SHOTS_DIR"] ?? NSTemporaryDirectory()
        let url = URL(fileURLWithPath: root).appendingPathComponent("\(Int(width))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func requireShots() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TELLOMI_SHOTS"] == "1", "只在 TELLOMI_SHOTS=1 时跑")
    }

    // MARK: - 判据 1–4：2 / 5 / 12 / 32 张

    @MainActor
    func testAlbumsByCount() async throws {
        try requireShots()

        let thread = write { tx in ContactThreadFactory().create(transaction: tx) }
        var messages = [(label: String, message: TSMessage)]()
        for count in [2, 5, 12, 32] {
            messages.append(("in\(count)", try await insertAlbum(thread: thread, incoming: true, sizes: sizes(count), body: nil)))
            messages.append(("out\(count)", try await insertAlbum(thread: thread, incoming: false, sizes: sizes(count), body: nil)))
        }
        // 两张 9:16 竖图：自己发的放得下，整组靠右、不能滑（C-5）
        messages.append(("out2fits", try await insertAlbum(thread: thread, incoming: false, sizes: [CGSize(width: 1080, height: 1920), CGSize(width: 1080, height: 1920)], body: nil)))

        for width in shotWidths {
            let expectedRowHeight = AlbumCarouselGeometry.rowHeight(screenWidth: width, screenHeight: max(width, 874), capByScreenHeight: false)
            let expectedOutgoingStart = width - 16 - maxMessageWidth(width: width, isGroup: false)
            report += "width=\(width) rowHeight(expected)=\(expectedRowHeight) outgoingStart(expected)=\(expectedOutgoingStart)\n"

            var shots = [UIImage]()
            for (label, message) in messages {
                let hosted = try await host(message: message, thread: thread, width: width)
                let carousel = try XCTUnwrap(findCarousel(in: hosted.cellView), "\(label): 没有横滑相册")
                let layout = try XCTUnwrap(carousel.geometry)
                let firstItem = try XCTUnwrap(carousel.itemViews.first)
                let lastItem = try XCTUnwrap(carousel.itemViews.last)
                let firstLeft = hosted.cellView.convert(firstItem.bounds, from: firstItem).minX

                report += "  \(label): rowHeight=\(carousel.bounds.size.height) carouselWidth=\(carousel.bounds.size.width) firstLeft=\(firstLeft) scrollable=\(layout.isScrollable) items=\(carousel.itemViews.count)\n"
                if label == "in2" || label == "out2" {
                    report += carousel.layoutDescriptionForTesting + "\n"
                    if let renderItem = hosted.cellView.renderItem {
                        let m = renderItem.cellMeasurement
                        report += "    cellSize=\(NSCoder.string(for: m.cellSize)) rowHeight(measured)=\(m.value(key: "CVComponentBodyMedia.measurementKey_albumCarouselRowHeight") ?? -1)\n"
                        for key in ["CVComponentMessage.measurementKey_hOuterStack", "CVComponentMessage.measurementKey_hInnerStack", "CVComponentMessage.measurementKey_contentStack", "CVComponentMessage.measurementKey_bottomFullWidthStackView", "CVComponentBodyMedia.measurementKey_stackView"] {
                            report += "    \(key)=\(m.measurement(key: key).map { NSCoder.string(for: $0.measuredSize) } ?? "nil")\n"
                        }
                    }
                    if let placeholder = findPlaceholder(in: hosted.cellView) {
                        var node: UIView? = placeholder
                        while let view = node, view !== hosted.cellView {
                            report += "    placeholder-ancestor \(type(of: view)) frame=\(NSCoder.string(for: view.frame)) subviews=\(view.subviews.count)\n"
                            node = view.superview
                        }
                    }
                    var ancestor: UIView? = carousel
                    while let view = ancestor, view !== hosted.cellView {
                        report += "    ancestor \(type(of: view)) frame=\(NSCoder.string(for: view.frame))\n"
                        ancestor = view.superview
                    }
                }

                // C-2：行高；C-5：滑动区整屏宽
                XCTAssertEqual(carousel.bounds.size.height, expectedRowHeight, "\(label) width=\(width)")
                XCTAssertEqual(hosted.cellView.convert(carousel.bounds, from: carousel).size.width, width, "\(label) width=\(width)")

                let isIncoming = message is TSIncomingMessage
                if label == "out2fits" {
                    // 放得下：不能滑、整组靠右，最后一张右边 = 屏宽 − 16
                    XCTAssertFalse(layout.isScrollable, "\(label) width=\(width)")
                    let lastRight = hosted.cellView.convert(lastItem.bounds, from: lastItem).maxX
                    XCTAssertEqual(lastRight, width - 16, accuracy: 0.5, "\(label) width=\(width)")
                } else if layout.isScrollable {
                    // C-5：静止时第一张对齐起点（对方 16，自己 = 气泡列起点）
                    XCTAssertEqual(firstLeft, isIncoming ? 16 : expectedOutgoingStart, accuracy: 0.5, "\(label) width=\(width)")
                }

                shots.append(render(hosted))
                try save(shots.last!, name: "\(label).png", width: width)

                if layout.isScrollable {
                    // 滑到底：最后一张右边 = 屏宽 − 16；每个吸附位上下一张都露出来（≤ 屏宽 − 48）
                    carousel.setContentOffsetForTesting(layout.maxScroll)
                    hosted.window.layoutIfNeeded()
                    let lastRight = hosted.cellView.convert(lastItem.bounds, from: lastItem).maxX
                    report += "    atEnd lastRight=\(lastRight)\n"
                    XCTAssertEqual(lastRight, width - 16, accuracy: 0.5, "\(label) width=\(width)")
                    for index in 0..<(layout.itemCount - 1) {
                        let nextLeftOnScreen = layout.itemLefts[index + 1] - layout.snapOffset(forItem: index)
                        XCTAssertLessThanOrEqual(nextLeftOnScreen, width - 48, "\(label) width=\(width) item=\(index)")
                    }
                    if label == "in12" {
                        try await settle(hosted)
                        shots.append(render(hosted))
                        try save(shots.last!, name: "in12-scrolled-to-end.png", width: width)
                    }
                    carousel.setContentOffsetForTesting(0)
                    hosted.window.layoutIfNeeded()
                }

                // C-10：长按预览要连相册一起（整行），不是气泡里那段空占位
                let componentView = try XCTUnwrap(hosted.cellView.componentView)
                XCTAssertTrue(componentView.contextMenuContentView?() === componentView.rootView, "\(label) width=\(width)：长按预览要是整行")

                // C-13：读作「相册，共 N 项」，上下滑逐张切换
                XCTAssertEqual(carousel.accessibilityLabel, "Album, \(carousel.itemViews.count) items", "\(label) width=\(width)")
                XCTAssertEqual(carousel.accessibilityValue, "Item 1 of \(carousel.itemViews.count)", "\(label) width=\(width)")

                if label == "in12" {
                    // C-9：查看器缩回前按附件找这一张——先把它滚到完整露出
                    let messageComponent = try XCTUnwrap(hosted.cellView.renderItem?.rootComponent as? CVComponentMessage)
                    let target = carousel.itemViews[7]
                    let returned = messageComponent.albumItemView(forAttachment: target.attachment.attachment, componentView: componentView)
                    hosted.window.layoutIfNeeded()
                    let revealed = hosted.cellView.convert(target.bounds, from: target)
                    report += "    revealItem8 frame=\(NSCoder.string(for: revealed)) offset=\(carousel.contentOffsetForTesting)\n"
                    XCTAssertTrue(returned === target, "\(label)：要返回第 8 张自己的视图")
                    XCTAssertGreaterThanOrEqual(revealed.minX, 0, "\(label) width=\(width)：第 8 张要整张露出")
                    XCTAssertLessThanOrEqual(revealed.maxX, width, "\(label) width=\(width)：第 8 张要整张露出")

                    carousel.setContentOffsetForTesting(0)
                    carousel.accessibilityIncrement()
                    try await Task.sleep(nanoseconds: 700_000_000)
                    report += "    afterIncrement value=\(carousel.accessibilityValue ?? "nil") offset=\(carousel.contentOffsetForTesting)\n"
                    XCTAssertEqual(carousel.accessibilityValue, "Item 2 of 12", "\(label) width=\(width)")
                    XCTAssertEqual(carousel.contentOffsetForTesting, layout.snapOffset(forItem: 1), accuracy: 0.5, "\(label) width=\(width)")
                    carousel.setContentOffsetForTesting(0)
                    hosted.window.layoutIfNeeded()
                }

                // C-11：能滑的相册上横向拖动不归消息（不滑动回复）；放得下的照常
                let panOnAlbum = FakePan()
                panOnAlbum.locationInWindow = hosted.window.convert(CGPoint(x: carousel.bounds.midX, y: carousel.bounds.midY), from: carousel)
                let panHandler = hosted.cellView.findPanHandler(
                    sender: panOnAlbum,
                    componentDelegate: hosted.delegate,
                    messageSwipeActionState: CVMessageSwipeActionState(),
                )
                report += "    panHandlerOnAlbum=\(panHandler == nil ? "nil" : "swipe")\n"
                if layout.isScrollable {
                    XCTAssertNil(panHandler, "\(label) width=\(width)：能滑的相册上不应滑动回复")
                } else {
                    XCTAssertNotNil(panHandler, "\(label) width=\(width)：放得下的相册照常滑动回复")
                }

                // 点气泡外面的某一张（第 2 张的中心；气泡里的占位宽 0）也要归相册处理
                if isIncoming, carousel.itemViews.count >= 2 {
                    let second = carousel.itemViews[1]
                    let tap = FakeTap()
                    tap.locationInWindow = hosted.window.convert(CGPoint(x: second.bounds.midX, y: second.bounds.midY), from: second)
                    let handled = hosted.cellView.handleTap(sender: tap, componentDelegate: hosted.delegate)
                    report += "    tapOnSecondItemHandled=\(handled)\n"
                    XCTAssertTrue(handled, "\(label) width=\(width)：点相册里的一张要被处理")
                }

                // C-7：无说明时时间胶囊在相册可视区右下角，不随图片滚动
                let pill = carousel.overlayView.subviews.first { $0 is ManualLayoutViewWithLayer }
                report += "    footerPill=\(pill.map { NSCoder.string(for: hosted.cellView.convert($0.bounds, from: $0)) } ?? "nil")\n"
                XCTAssertNotNil(pill, "\(label) width=\(width)：无说明时要有时间胶囊")
                if let pill {
                    let pillFrame = hosted.cellView.convert(pill.bounds, from: pill)
                    let areaFrame = hosted.cellView.convert(carousel.albumAreaFrame, from: carousel)
                    XCTAssertEqual(pillFrame.maxX, areaFrame.maxX - 8, accuracy: 0.5, "\(label) width=\(width)")
                    XCTAssertEqual(pillFrame.maxY, areaFrame.maxY - 8, accuracy: 0.5, "\(label) width=\(width)")
                }

                hosted.tearDown()
            }
            try save(stack(shots, width: width), name: "albums-by-count.png", width: width)
        }

        try report.write(to: shotsDirectory(width: shotWidths.first ?? 402).deletingLastPathComponent().appendingPathComponent("metrics-albums.txt"), atomically: true, encoding: .utf8)
    }

    // MARK: - C-8：说明、群昵称

    @MainActor
    func testCaptionAndGroupName() async throws {
        try requireShots()

        let contactThread = write { tx in ContactThreadFactory().create(transaction: tx) }
        let member = CommonGenerator.address()
        let groupThread = try write { tx in
            try GroupManager.createGroupForTests(members: [member], name: "相册测试群", transaction: tx)
        }

        let captionIn = try await insertAlbum(thread: contactThread, incoming: true, sizes: sizes(5), body: "周末去爬山拍的，最后一张是山顶。")
        let captionOut = try await insertAlbum(thread: contactThread, incoming: false, sizes: sizes(5), body: "收到，这组我也发一下 👍")
        let groupIn = try await insertAlbum(thread: groupThread, incoming: true, sizes: sizes(5), body: nil, author: member.aci)
        let groupInCaption = try await insertAlbum(thread: groupThread, incoming: true, sizes: sizes(12), body: "群里的第二组，带说明", author: member.aci)

        for width in shotWidths {
            var shots = [UIImage]()
            report += "width=\(width)\n"
            for (label, message, thread) in [
                ("captionIn", captionIn, contactThread as TSThread),
                ("captionOut", captionOut, contactThread),
                ("groupIn", groupIn, groupThread),
                ("groupInCaption", groupInCaption, groupThread),
            ] {
                let hosted = try await host(message: message, thread: thread, width: width)
                let carousel = try XCTUnwrap(findCarousel(in: hosted.cellView), "\(label): 没有横滑相册")
                let firstItem = try XCTUnwrap(carousel.itemViews.first)
                let firstLeft = hosted.cellView.convert(firstItem.bounds, from: firstItem).minX
                let isGroup = thread is TSGroupThread
                report += "  \(label): firstLeft=\(firstLeft) rowHeight=\(carousel.bounds.size.height)\n"

                if message is TSIncomingMessage {
                    // 群聊在头像后：12 + 28 + 8 = 48
                    XCTAssertEqual(firstLeft, isGroup ? 48 : 16, accuracy: 0.5, "\(label) width=\(width)")
                }

                if message.body?.isEmpty == false {
                    // 说明气泡上照常滑动回复（C-11）
                    let bubbleText = try XCTUnwrap(findBodyTextLabel(in: hosted.cellView), "\(label): 找不到说明文字")
                    let pan = FakePan()
                    pan.locationInWindow = hosted.window.convert(CGPoint(x: bubbleText.bounds.midX, y: bubbleText.bounds.midY), from: bubbleText)
                    let panHandler = hosted.cellView.findPanHandler(
                        sender: pan,
                        componentDelegate: hosted.delegate,
                        messageSwipeActionState: CVMessageSwipeActionState(),
                    )
                    report += "    panHandlerOnCaption=\(panHandler == nil ? "nil" : "swipe")\n"
                    XCTAssertNotNil(panHandler, "\(label) width=\(width)：说明气泡上照常滑动回复")

                    // 说明在相册下方
                    let textFrame = hosted.cellView.convert(bubbleText.bounds, from: bubbleText)
                    let carouselFrame = hosted.cellView.convert(carousel.bounds, from: carousel)
                    XCTAssertGreaterThanOrEqual(textFrame.minY, carouselFrame.maxY, "\(label) width=\(width)：说明要在相册下方")
                }

                shots.append(render(hosted))
                try save(shots.last!, name: "\(label).png", width: width)
                hosted.tearDown()
            }
            try save(stack(shots, width: width), name: "caption-and-group.png", width: width)
        }

        try report.write(to: shotsDirectory(width: shotWidths.first ?? 402).deletingLastPathComponent().appendingPathComponent("metrics-caption-group.txt"), atomically: true, encoding: .utf8)
    }

    // MARK: - Hosting

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
        // 窗口放在状态栏以下：否则 cell 落在安全区里，布局边距会被加上安全区（会话页里 cell 不会这样）
        let window = UIWindow(frame: CGRect(x: 0, y: 150, width: width, height: cellHeight + 24))
        window.backgroundColor = Theme.backgroundColor
        let cellView = CVCellView()
        cellView.configure(renderItem: renderItem, componentDelegate: delegate)
        cellView.frame = CGRect(x: 0, y: 12, width: width, height: cellHeight)
        window.addSubview(cellView)
        window.isHidden = false
        cellView.isCellVisible = true
        window.layoutIfNeeded()
        report += "    window.safeAreaInsets=\(NSCoder.string(for: window.safeAreaInsets)) cell.safeAreaInsets=\(NSCoder.string(for: cellView.safeAreaInsets))\n"

        let hosted = Hosted(window: window, cellView: cellView, delegate: delegate)
        try await settle(hosted)
        return hosted
    }

    @MainActor
    private func settle(_ hosted: Hosted) async throws {
        // 缩略图是异步解出来的
        for _ in 0..<12 {
            try await Task.sleep(nanoseconds: 150_000_000)
            hosted.window.layoutIfNeeded()
        }
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

    private func save(_ image: UIImage, name: String, width: CGFloat) throws {
        let url = try shotsDirectory(width: width).appendingPathComponent(name)
        try XCTUnwrap(image.pngData()).write(to: url)
        report += "saved \(url.path)\n"
    }

    // MARK: - Finding views

    private func findCarousel(in view: UIView) -> CVAlbumCarouselView? {
        if let carousel = view as? CVAlbumCarouselView {
            return carousel
        }
        for subview in view.subviews {
            if let carousel = findCarousel(in: subview) {
                return carousel
            }
        }
        return nil
    }

    /// 横滑模式下 CVComponentBodyMedia 的 rootView（气泡里的占位）。
    private func findPlaceholder(in view: UIView) -> UIView? {
        if String(reflecting: type(of: view)).contains("CVComponentViewBodyMediaRootView") {
            return view
        }
        for subview in view.subviews {
            if let found = findPlaceholder(in: subview) {
                return found
            }
        }
        return nil
    }

    /// 说明文字用的是 SignalUI 里 CVTextLabel 的私有视图类（不是 UILabel），按类型名找。
    private func findBodyTextLabel(in view: UIView) -> UIView? {
        if String(reflecting: type(of: view)).contains("CVTextLabel") {
            return view
        }
        for subview in view.subviews {
            if let found = findBodyTextLabel(in: subview) {
                return found
            }
        }
        return nil
    }

    private func maxMessageWidth(width: CGFloat, isGroup: Bool) -> CGFloat {
        let thread = write { tx in ContactThreadFactory().create(transaction: tx) }
        let style = ConversationStyle(
            type: .`default`,
            thread: thread,
            viewWidth: width,
            hasWallpaper: false,
            shouldDimWallpaperInDarkMode: false,
            chatColor: ChatColorSettingStore.Constants.defaultColor.colorSetting,
        )
        return style.maxMessageWidth
    }

    // MARK: - Messages with real image data

    /// 宽高轮换：竖 3:4、横 4:3、16:9、9:16、1:1。
    private func sizes(_ count: Int) -> [CGSize] {
        let cycle = [CGSize(width: 1200, height: 1600), CGSize(width: 1600, height: 1200), CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920), CGSize(width: 1200, height: 1200)]
        return (0..<count).map { cycle[$0 % cycle.count] }
    }

    @MainActor
    private func insertAlbum(thread: TSThread, incoming: Bool, sizes: [CGSize], body: String?, author: Aci? = nil) async throws -> TSMessage {
        let message: TSMessage = write { tx in
            if incoming {
                let factory = IncomingMessageFactory()
                factory.threadCreator = { _ in thread }
                factory.messageBodyBuilder = { body ?? "" }
                if let author {
                    factory.authorAciBuilder = { _ in author }
                }
                return factory.create(transaction: tx)
            } else {
                // 「已发出」的样子：附件没有上传记录时，本机建的外发消息会一直显示上传进度圈；
                // 这里当作另一台设备发的（wasNotCreatedLocally），画出来就是发完之后的稳定状态
                let message = TSOutgoingMessageBuilder(
                    thread: thread,
                    timestamp: NSDate.ows_millisecondTimeStamp(),
                    receivedAtTimestamp: NSDate.ows_millisecondTimeStamp(),
                    messageBody: DependenciesBridge.shared.attachmentContentValidator.truncatedMessageBodyForInlining(
                        MessageBody(text: body ?? "", ranges: .empty),
                        tx: tx,
                    ),
                    editState: .none,
                    expiresInSeconds: nil,
                    expireTimerVersion: nil,
                    expireStartedAt: nil,
                    isVoiceMessage: false,
                    isSmsMessageRestoredFromBackup: false,
                    isViewOnceMessage: false,
                    isViewOnceComplete: false,
                    wasRemotelyDeleted: false,
                    wasNotCreatedLocally: true,
                    groupChangeProtoData: nil,
                    storyAuthorAci: nil,
                    storyTimestamp: nil,
                    storyReactionEmoji: nil,
                    quotedMessage: nil,
                    contactShare: nil,
                    linkPreview: nil,
                    messageSticker: nil,
                    giftBadge: nil,
                    isPoll: false,
                ).build(transaction: tx)
                message.anyInsert(transaction: tx)
                if let recipientAci = (thread as? TSContactThread)?.contactAddress.aci {
                    message.updateWithSentRecipients([recipientAci], wasSentByUD: false, tx: tx)
                }
                return message
            }
        }

        var pendingAttachments = [PendingAttachment]()
        for (index, size) in sizes.enumerated() {
            pendingAttachments.append(try await DependenciesBridge.shared.attachmentContentValidator.validateDataContents(
                jpeg(size: size, number: index + 1),
                mimeType: "image/jpeg",
                renderingFlag: .default,
                sourceFilename: nil,
            ))
        }

        try write { tx in
            for (index, pending) in pendingAttachments.enumerated() {
                _ = try DependenciesBridge.shared.attachmentManager.createAttachmentStream(
                    from: OwnedAttachmentDataSource(
                        dataSource: .pendingAttachment(pending),
                        owner: .messageBodyAttachment(.init(
                            messageRowId: message.sqliteRowId!,
                            receivedAtTimestamp: message.receivedAtTimestamp,
                            threadRowId: thread.sqliteRowId!,
                            isViewOnce: false,
                            isPastEditRevision: false,
                            orderInMessage: UInt32(index),
                        )),
                    ),
                    tx: tx,
                )
            }
        }
        return message
    }

    private func jpeg(size: CGSize, number: Int) -> Data {
        let imageSize = CGSize(width: size.width / 4, height: size.height / 4)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: imageSize, format: format).image { context in
            let hue = CGFloat((number * 47) % 360) / 360
            let colors = [
                UIColor(hue: hue, saturation: 0.55, brightness: 0.95, alpha: 1).cgColor,
                UIColor(hue: (hue + 0.11).truncatingRemainder(dividingBy: 1), saturation: 0.75, brightness: 0.65, alpha: 1).cgColor,
            ] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: imageSize.width, y: imageSize.height), options: [])

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let numberFont = UIFont.systemFont(ofSize: min(imageSize.width, imageSize.height) * 0.42, weight: .regular)
            let numberText = NSAttributedString(string: "\(number)", attributes: [.font: numberFont, .foregroundColor: UIColor.white, .paragraphStyle: paragraph])
            let numberHeight = numberFont.lineHeight
            numberText.draw(in: CGRect(x: 0, y: (imageSize.height - numberHeight) / 2, width: imageSize.width, height: numberHeight))

            let sizeFont = UIFont.systemFont(ofSize: min(imageSize.width, imageSize.height) * 0.09)
            let sizeText = NSAttributedString(string: "\(Int(size.width))×\(Int(size.height))", attributes: [.font: sizeFont, .foregroundColor: UIColor.white, .paragraphStyle: paragraph])
            sizeText.draw(in: CGRect(x: 0, y: imageSize.height - sizeFont.lineHeight * 1.8, width: imageSize.width, height: sizeFont.lineHeight))
        }
        return image.jpegData(compressionQuality: 0.9)!
    }
}

// MARK: - Fake gestures（只用来喂「落点」给消息 cell 的手势分派）

private final class FakePan: UIPanGestureRecognizer {
    var locationInWindow: CGPoint = .zero

    override func location(in view: UIView?) -> CGPoint {
        guard let view else {
            return locationInWindow
        }
        return view.convert(locationInWindow, from: nil)
    }
}

private final class FakeTap: UITapGestureRecognizer {
    var locationInWindow: CGPoint = .zero

    override func location(in view: UIView?) -> CGPoint {
        guard let view else {
            return locationInWindow
        }
        return view.convert(locationInWindow, from: nil)
    }
}
