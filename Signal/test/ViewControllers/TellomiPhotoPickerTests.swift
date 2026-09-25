//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import UIKit
import UniformTypeIdentifiers
import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// tellomi/tellomi#1261：选图网格（`TellomiPhotoPickerViewController`）的判据与截图。
///
/// 相册用内存里的假图（不读系统相册、不要权限）；发送只看交给会话页的 `ApprovedAttachments`，
/// 会话页那一头「单独发送」的拆条规则见 `TellomiPhotoPickerSending`。
/// 截图只在 `TELLOMI_SHOTS=1` 时拍：屏宽取 `TELLOMI_SHOT_WIDTHS`（默认 402,440,375），写到 `TELLOMI_SHOTS_DIR/<屏宽>/picker-*.png`。
final class TellomiPhotoPickerTests: SignalBaseTest {

    // MARK: - P-1 / P-2 顶栏

    /// 没选中：只有 ✕ 和「最近」；选中 1 张：✕ 右边出现「✓1」（高 44）、右边出现「···」、底部出现说明栏；全取消又收回去。
    @MainActor
    func testTopBarBeforeAndAfterSelecting() async throws {
        let hosted = host()
        defer { hosted.tearDown() }
        let picker = hosted.picker

        XCTAssertEqual(picker.titleForTesting, "Recents")
        XCTAssertFalse(picker.isCountPillShownForTesting)
        XCTAssertFalse(picker.isMoreButtonShownForTesting)
        XCTAssertFalse(picker.isSendBarShownForTesting)
        XCTAssertFalse(picker.isModalInPresentation)

        picker.tapCheckForTesting(itemIndex: 0)
        XCTAssertTrue(picker.isCountPillShownForTesting)
        XCTAssertEqual(picker.countPillTextForTesting, "1")
        XCTAssertEqual(picker.countPillFrameForTesting.size.height, 44, accuracy: 0.01)
        XCTAssertTrue(picker.isMoreButtonShownForTesting)
        XCTAssertTrue(picker.isSendBarShownForTesting)
        XCTAssertEqual(picker.sendBarFrameForTesting.maxY, picker.view.bounds.size.height, accuracy: 0.01, "说明栏底色铺到底，不露出下面的网格")
        XCTAssertTrue(picker.isModalInPresentation, "有选中时不能一拉就关")

        picker.tapCheckForTesting(itemIndex: 0)
        XCTAssertFalse(picker.isCountPillShownForTesting)
        XCTAssertFalse(picker.isMoreButtonShownForTesting)
        XCTAssertFalse(picker.isSendBarShownForTesting)
    }

    // MARK: - P-8 网格

    /// 编号勾：按勾的顺序编号；取消中间一张，后面的往前补；勾在右上角、29 的触摸区、离上右各 3。
    @MainActor
    func testNumberedChecksFollowTapOrder() async throws {
        let hosted = host()
        defer { hosted.tearDown() }
        let picker = hosted.picker

        for index in [3, 0, 5] {
            picker.tapCheckForTesting(itemIndex: index)
        }
        XCTAssertEqual(picker.selectedIdsForTesting, ["r3", "r0", "r5"])
        XCTAssertEqual(picker.cellForTesting(itemIndex: 3)?.numberTextForTesting, "1")
        XCTAssertEqual(picker.cellForTesting(itemIndex: 0)?.numberTextForTesting, "2")
        XCTAssertEqual(picker.cellForTesting(itemIndex: 5)?.numberTextForTesting, "3")
        XCTAssertNil(picker.cellForTesting(itemIndex: 1)?.numberTextForTesting)
        XCTAssertEqual(picker.countPillTextForTesting, "3")

        picker.tapCheckForTesting(itemIndex: 0)
        XCTAssertEqual(picker.selectedIdsForTesting, ["r3", "r5"])
        XCTAssertEqual(picker.cellForTesting(itemIndex: 3)?.numberTextForTesting, "1")
        XCTAssertEqual(picker.cellForTesting(itemIndex: 5)?.numberTextForTesting, "2")
        XCTAssertNil(picker.cellForTesting(itemIndex: 0)?.numberTextForTesting)

        let cell = try XCTUnwrap(picker.cellForTesting(itemIndex: 0))
        let check = cell.checkFrameForTesting
        XCTAssertEqual(check.size, CGSize(width: 29, height: 29))
        XCTAssertEqual(check.minY, 3, accuracy: 0.01)
        XCTAssertEqual(cell.bounds.size.width - check.maxX, 3, accuracy: 0.01)
    }

    /// 竖屏 3 列、横屏 5 列，间距 1，正方形；三种屏宽都一样。
    /// 边长按屏幕像素（1/3 pt）向下取整，除不尽时剩下的不到每列 1 像素，由 flow layout 摊进列间距（最多 1.34）。
    @MainActor
    func testGridColumnsSpacingAndSquareCells() async throws {
        for (width, height) in [(375, 812), (402, 874), (440, 956)] as [(CGFloat, CGFloat)] {
            for (w, h, columns) in [(width, height, 3), (height, width, 5)] {
                let hosted = host(width: w, height: h)
                defer { hosted.tearDown() }
                let frames = (0...columns).map { frame(of: $0, in: hosted.picker) }
                let label = "\(Int(w))×\(Int(h))"
                XCTAssertEqual(frames[0].size.width, frames[0].size.height, accuracy: 0.01, "\(label) 正方形")
                let gap = frames[1].minX - frames[0].maxX
                XCTAssertGreaterThanOrEqual(gap, 0.99, "\(label) 列间距 1")
                XCTAssertLessThanOrEqual(gap, 1.34, "\(label) 列间距 1")
                XCTAssertEqual(frames[columns - 1].minY, frames[0].minY, accuracy: 0.01, "\(label) 第一行有 \(columns) 格")
                XCTAssertEqual(frames[columns].minX, frames[0].minX, accuracy: 0.01, "\(label) 第 \(columns + 1) 格换行")
                XCTAssertEqual(frames[columns].minY - frames[0].maxY, 1, accuracy: 0.01, "\(label) 行间距 1")
                let leftover = hosted.picker.collectionViewForTesting.bounds.size.width - (CGFloat(columns) * frames[0].size.width + CGFloat(columns - 1))
                XCTAssertGreaterThanOrEqual(leftover, -0.01, "\(label) 一行放得下")
                XCTAssertLessThan(leftover, CGFloat(columns) / 3, "\(label) 铺满一行（剩下的不到每列 1 像素）")
            }
        }
    }

    /// 视频右下角时长（m:ss，一小时以上 h:mm:ss），实况照片左上角小图标，普通照片两样都没有。
    @MainActor
    func testVideoDurationAndLivePhotoBadge() async throws {
        let hosted = host()
        defer { hosted.tearDown() }
        let picker = hosted.picker

        XCTAssertEqual(picker.cellForTesting(itemIndex: 1)?.durationTextForTesting, "1:15")
        XCTAssertEqual(picker.cellForTesting(itemIndex: 7)?.durationTextForTesting, "1:02:05")
        XCTAssertNil(picker.cellForTesting(itemIndex: 0)?.durationTextForTesting)

        let live = try XCTUnwrap(picker.cellForTesting(itemIndex: 2))
        XCTAssertTrue(live.isShowingLivePhotoBadgeForTesting)
        XCTAssertEqual(live.livePhotoBadgeFrameForTesting.origin, CGPoint(x: 6, y: 6))
        XCTAssertFalse(try XCTUnwrap(picker.cellForTesting(itemIndex: 0)).isShowingLivePhotoBadgeForTesting)
    }

    /// 横着滑过格子连续多选：起手那格没选就一路选上，已选就一路取消；先竖着动超过 5 就让给滚动；滑动期间网格不滚。
    @MainActor
    func testSwipeAcrossCellsSelectsAndDeselects() async throws {
        let hosted = host()
        defer { hosted.tearDown() }
        let picker = hosted.picker

        let start = center(of: 0, in: picker)
        let progress = picker.swipeForTesting(through: [
            start,
            CGPoint(x: start.x + 4, y: start.y + 1),
            CGPoint(x: start.x + 12, y: start.y + 2),
            center(of: 1, in: picker),
            center(of: 2, in: picker),
        ])
        XCTAssertEqual(progress, .swiping)
        XCTAssertEqual(picker.selectedIdsForTesting, ["r0", "r1", "r2"])

        let back = center(of: 2, in: picker)
        picker.swipeForTesting(through: [back, CGPoint(x: back.x - 12, y: back.y), center(of: 1, in: picker)])
        XCTAssertEqual(picker.selectedIdsForTesting, ["r0"], "起手在已选的格子上：一路取消")

        let vertical = center(of: 4, in: picker)
        XCTAssertEqual(
            picker.swipeForTesting(through: [vertical, CGPoint(x: vertical.x + 3, y: vertical.y + 6), CGPoint(x: vertical.x + 60, y: vertical.y + 6)]),
            .failed,
        )
        XCTAssertEqual(picker.selectedIdsForTesting, ["r0"], "先竖着动就是滚动，不选")

        let gesture = picker.swipeSelectGestureForTesting
        let third = center(of: 3, in: picker)
        XCTAssertEqual(gesture.track(from: third, to: CGPoint(x: third.x + 9, y: third.y)), .swiping)
        XCTAssertFalse(picker.isGridScrollEnabledForTesting, "滑动选择期间网格不滚")
        gesture.finishSwipe()
        XCTAssertTrue(picker.isGridScrollEnabledForTesting)
        XCTAssertEqual(picker.selectedIdsForTesting, ["r0", "r3"])
    }

    // MARK: - P-7 受限访问横幅

    /// 权限是「有限」：网格顶上一条横幅（跟着网格滚），文字 +「管理」；不是「有限」就没有，第一格贴顶。
    @MainActor
    func testLimitedAccessBanner() async throws {
        let limited = FakePhotoLibrary()
        limited.isAccessLimited = true
        let hosted = host(library: limited)
        defer { hosted.tearDown() }
        XCTAssertEqual(hosted.picker.limitedAccessBannerTextForTesting, "You’ve limited Tellomi’s access to your photos.")
        XCTAssertEqual(frame(of: 0, in: hosted.picker).minY, 56, accuracy: 0.01, "横幅在网格里，第一格在它下面")
        let manage = try XCTUnwrap(hosted.picker.limitedAccessManageButtonFrameForTesting)
        XCTAssertEqual(manage.size.height, 28, accuracy: 0.01, "「管理」胶囊高 28")
        XCTAssertLessThan(manage.size.width, 100, "「管理」按内容宽，不被拉伸")

        let full = host()
        defer { full.tearDown() }
        XCTAssertNil(full.picker.limitedAccessBannerTextForTesting)
        XCTAssertEqual(frame(of: 0, in: full.picker).minY, 0, accuracy: 0.01)
    }

    // MARK: - P-5「···」

    /// 已选里有照片才有「以高清质量发送」（默认已是高就换成「以标准质量发送」）；已选 ≥ 2 才有「单独发送」；只有视频时没有画质项。
    @MainActor
    func testMoreMenuItems() async throws {
        let hosted = host()
        defer { hosted.tearDown() }
        let picker = hosted.picker

        picker.tapCheckForTesting(itemIndex: 0)
        XCTAssertEqual(picker.moreMenuItemsForTesting, [.sendHighQuality])
        XCTAssertEqual(picker.moreMenuTitlesForTesting, ["Send in High Quality"])

        picker.tapCheckForTesting(itemIndex: 3)
        XCTAssertEqual(picker.moreMenuItemsForTesting, [.sendHighQuality, .sendSeparately])
        XCTAssertEqual(picker.moreMenuTitlesForTesting, ["Send in High Quality", "Send Separately"])

        let high = host(defaultImageQuality: .high)
        defer { high.tearDown() }
        high.picker.tapCheckForTesting(itemIndex: 0)
        XCTAssertEqual(high.picker.moreMenuItemsForTesting, [.sendStandardQuality])
        XCTAssertEqual(high.picker.moreMenuTitlesForTesting, ["Send in Standard Quality"])

        let videos = host()
        defer { videos.tearDown() }
        videos.picker.tapCheckForTesting(itemIndex: 1)
        XCTAssertEqual(videos.picker.moreMenuItemsForTesting, [])
        XCTAssertFalse(videos.picker.isMoreButtonShownForTesting, "只有一个视频：「···」里什么都没有就不出现")
        videos.picker.tapCheckForTesting(itemIndex: 7)
        XCTAssertEqual(videos.picker.moreMenuItemsForTesting, [.sendSeparately])
        XCTAssertTrue(videos.picker.isMoreButtonShownForTesting)

        let noSeparate = host(canSendSeparately: false)
        defer { noSeparate.tearDown() }
        noSeparate.picker.tapCheckForTesting(itemIndex: 0)
        noSeparate.picker.tapCheckForTesting(itemIndex: 3)
        XCTAssertEqual(noSeparate.picker.moreMenuItemsForTesting, [.sendHighQuality])
    }

    /// 「···」里三项都是点了立即发：高清 / 标准只管这一次（带在这次发送里，不写设置），单独发送带上 separately。
    @MainActor
    func testMoreMenuItemsSendRightAway() async throws {
        let hosted = host()
        defer { hosted.tearDown() }
        let picker = hosted.picker
        picker.tapCheckForTesting(itemIndex: 0)
        picker.tapCheckForTesting(itemIndex: 3)

        picker.performMoreMenuItemForTesting(.sendHighQuality)
        let first = try await nextSend(hosted, count: 1)
        XCTAssertEqual(first.approved.imageQuality, .high)
        XCTAssertFalse(first.separately)
        XCTAssertEqual(hosted.library.ids(of: first.approved), ["r0", "r3"])

        picker.performMoreMenuItemForTesting(.sendSeparately)
        let second = try await nextSend(hosted, count: 2)
        XCTAssertTrue(second.separately)
        XCTAssertEqual(second.approved.imageQuality, .standard, "单独发送按默认画质")
        XCTAssertEqual(hosted.library.ids(of: second.approved), ["r0", "r3"])

        let high = host(defaultImageQuality: .high)
        defer { high.tearDown() }
        high.picker.tapCheckForTesting(itemIndex: 0)
        high.picker.performMoreMenuItemForTesting(.sendStandardQuality)
        let standard = try await nextSend(high, count: 1)
        XCTAssertEqual(standard.approved.imageQuality, .standard)
    }

    // MARK: - P-9 / P-10 在网格里直接发

    /// 会话输入框里已打的字带过来当说明；发送按勾的顺序、默认画质、不是一次性查看，说明随这次发出去。
    @MainActor
    func testSendFromGridKeepsTapOrderAndCaption() async throws {
        let hosted = host(initialText: "今天的照片")
        defer { hosted.tearDown() }
        let picker = hosted.picker
        XCTAssertEqual(picker.captionTextForTesting, "今天的照片")
        picker.tapCheckForTesting(itemIndex: 1)
        picker.view.layoutIfNeeded()
        XCTAssertLessThan(picker.captionFieldHeightForTesting, 50, "一行字的说明框就是一行高")
        picker.tapCheckForTesting(itemIndex: 1)

        picker.tapCheckForTesting(itemIndex: 5)
        picker.tapCheckForTesting(itemIndex: 2)
        picker.tapCheckForTesting(itemIndex: 0)
        picker.tapSendForTesting()

        let sent = try await nextSend(hosted, count: 1)
        XCTAssertEqual(hosted.library.ids(of: sent.approved), ["r5", "r2", "r0"])
        XCTAssertEqual(sent.approved.imageQuality, .standard)
        XCTAssertFalse(sent.approved.isViewOnce)
        XCTAssertFalse(sent.separately)
        XCTAssertEqual(sent.body?.text, "今天的照片")
    }

    /// P-9 表情键：说明框右下角 32 的键（离框右、下各 4），字不压到它下面；点了说明框换成表情键盘并进入编辑、键变成「键盘」；
    /// 再点回到文字键盘（仍在编辑）；在表情键盘时收起键盘，下次就是文字键盘（同 Telegram）。
    @MainActor
    func testCaptionEmojiButtonSwitchesTheKeyboard() async throws {
        let hosted = host()
        defer { hosted.tearDown() }
        hosted.window.makeKey()
        let picker = hosted.picker
        picker.tapCheckForTesting(itemIndex: 0)
        picker.view.layoutIfNeeded()

        let field = picker.captionFieldFrameForTesting
        let button = picker.captionEmojiButtonFrameForTesting
        XCTAssertEqual(button.size.width, 32, accuracy: 0.01)
        XCTAssertEqual(button.size.height, 32, accuracy: 0.01)
        XCTAssertEqual(field.maxX - button.maxX, 4, accuracy: 0.5)
        XCTAssertEqual(field.maxY - button.maxY, 4, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(picker.captionTextContainerInsetForTesting.right, field.maxX - button.minX, "字不压到表情键下面")
        XCTAssertEqual(picker.captionEmojiButtonAccessibilityLabelForTesting, "Emoji")
        XCTAssertNil(picker.captionInputViewForTesting)
        XCTAssertFalse(picker.isCaptionEditingForTesting)

        picker.tapCaptionEmojiButtonForTesting()
        XCTAssertNotNil(picker.captionEmojiKeyboardForTesting, "说明框换成表情键盘")
        XCTAssertTrue(picker.isCaptionEditingForTesting, "点表情键直接进入编辑")
        XCTAssertEqual(picker.captionEmojiButtonAccessibilityLabelForTesting, "Keyboard")

        picker.tapCaptionEmojiButtonForTesting()
        XCTAssertNil(picker.captionInputViewForTesting, "再点回到文字键盘")
        XCTAssertTrue(picker.isCaptionEditingForTesting)
        XCTAssertEqual(picker.captionEmojiButtonAccessibilityLabelForTesting, "Emoji")

        picker.tapCaptionEmojiButtonForTesting()
        XCTAssertNotNil(picker.captionEmojiKeyboardForTesting)
        picker.endCaptionEditingForTesting()
        XCTAssertNil(picker.captionInputViewForTesting, "收起键盘后回到文字键盘")
        XCTAssertEqual(picker.captionEmojiButtonAccessibilityLabelForTesting, "Emoji")
    }

    /// 表情键盘里点一个 emoji：插在光标处（不是接在末尾），会话输入框跟着变；退格删掉光标前的整个 emoji。
    @MainActor
    func testEmojiKeyboardInsertsAtTheCursorAndDeletes() async throws {
        let hosted = host(initialText: "ab")
        defer { hosted.tearDown() }
        hosted.window.makeKey()
        let picker = hosted.picker
        picker.tapCheckForTesting(itemIndex: 0)
        picker.tapCaptionEmojiButtonForTesting()
        let keyboard = try XCTUnwrap(picker.captionEmojiKeyboardForTesting)

        picker.setCaptionCursorForTesting(1)
        let emoji = try XCTUnwrap(keyboard.tapEmojiForTesting(at: IndexPath(item: 0, section: 0)))
        XCTAssertEqual(picker.captionTextForTesting, "a" + emoji + "b")
        XCTAssertEqual(hosted.delegate.bodies.last??.text, "a" + emoji + "b", "会话输入框跟着变")

        let second = try XCTUnwrap(keyboard.tapEmojiForTesting(at: IndexPath(item: 1, section: 0)))
        XCTAssertEqual(picker.captionTextForTesting, "a" + emoji + second + "b", "光标跟在刚插的后面")

        keyboard.tapDeleteForTesting()
        XCTAssertEqual(picker.captionTextForTesting, "a" + emoji + "b", "退格删掉整个 emoji")
        keyboard.tapDeleteForTesting()
        keyboard.tapDeleteForTesting()
        XCTAssertEqual(picker.captionTextForTesting, "b")
        XCTAssertEqual(hosted.delegate.bodies.last??.text, "b")
    }

    /// 表情键盘照 Telegram 的排法：分类在上面（占满宽）、emoji 在中间、底栏左边「键盘」右边退格；点「键盘」回到文字键盘（仍在编辑）。
    @MainActor
    func testEmojiKeyboardLayoutAndSwitchBack() async throws {
        let hosted = host()
        defer { hosted.tearDown() }
        hosted.window.makeKey()
        let picker = hosted.picker
        picker.tapCheckForTesting(itemIndex: 0)
        picker.tapCaptionEmojiButtonForTesting()
        let keyboard = try XCTUnwrap(picker.captionEmojiKeyboardForTesting)
        // 键盘是系统异步放上屏的（在 UIRemoteKeyboardWindow 里），等它有了真实宽度再量。
        let onScreen = await waitUntil { keyboard.window != nil && keyboard.bounds.size.width >= picker.view.bounds.size.width - 0.5 }
        XCTAssertTrue(onScreen, "表情键盘上屏")
        keyboard.layoutIfNeeded()

        let toolbar = keyboard.sectionToolbarFrameForTesting
        let grid = keyboard.emojiViewFrameForTesting
        let switchButton = keyboard.keyboardButtonFrameForTesting
        let delete = keyboard.deleteButtonFrameForTesting
        XCTAssertEqual(toolbar.size.width, keyboard.bounds.size.width, accuracy: 0.5, "分类条占满宽，不和退格挤一行")
        XCTAssertLessThanOrEqual(toolbar.maxY, grid.minY + 0.5, "分类在 emoji 上面")
        XCTAssertLessThanOrEqual(grid.maxY, delete.minY + 0.5, "底栏在 emoji 下面")
        XCTAssertEqual(switchButton.minY, delete.minY, accuracy: 0.5, "「键盘」和退格在同一条底栏")
        XCTAssertLessThan(switchButton.midX, keyboard.bounds.midX, "「键盘」在左")
        XCTAssertGreaterThan(delete.midX, keyboard.bounds.midX, "退格在右")
        XCTAssertGreaterThan(grid.size.height, 150, "emoji 区不被挤没")

        keyboard.tapKeyboardForTesting()
        XCTAssertNil(picker.captionInputViewForTesting, "点「键盘」回到文字键盘")
        XCTAssertTrue(picker.isCaptionEditingForTesting)
        XCTAssertEqual(picker.captionEmojiButtonAccessibilityLabelForTesting, "Emoji")
    }

    /// 按住退格连着删（先删一个，0.5 秒后每 0.1 秒一个），松手就停。
    @MainActor
    func testHoldingDeleteKeepsDeleting() async throws {
        let hosted = host(initialText: String(repeating: "x", count: 40))
        defer { hosted.tearDown() }
        hosted.window.makeKey()
        let picker = hosted.picker
        picker.tapCheckForTesting(itemIndex: 0)
        picker.tapCaptionEmojiButtonForTesting()
        let keyboard = try XCTUnwrap(picker.captionEmojiKeyboardForTesting)
        picker.setCaptionCursorForTesting(40)

        try await keyboard.holdDeleteForTesting(seconds: 1.2)
        let afterHold = picker.captionTextForTesting.count
        XCTAssertLessThanOrEqual(afterHold, 40 - 3, "按住 1.2 秒删了好几个")
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(picker.captionTextForTesting.count, afterHold, "松手就停")
    }

    /// 点照片本身：选上并进上游的预览 / 编辑页（盖在网格上面），先看到点的那张；那里删掉一张，网格里也取消；那里取消回到网格、选中的还在；
    /// 那里改说明，网格的说明和会话输入框跟着变；那里发送照常交给会话页。
    @MainActor
    func testTapPhotoOpensUpstreamEditorOverTheGrid() async throws {
        let hosted = host()
        defer { hosted.tearDown() }
        let picker = hosted.picker

        picker.tapCheckForTesting(itemIndex: 3)
        picker.tapItemForTesting(itemIndex: 4)
        XCTAssertEqual(picker.selectedIdsForTesting, ["r3", "r4"])

        let opened = await waitUntil { self.approvalViewController(over: picker) != nil }
        XCTAssertTrue(opened, "进了上游的预览 / 编辑页")
        let approval = try XCTUnwrap(approvalViewController(over: picker))
        XCTAssertTrue(
            approval.currentItem?.attachment.rawValue === hosted.library.attachmentsById["r4"]?.rawValue,
            "点的是 r4，进来先看到 r4（不是已选里的第一张 r3）",
        )

        let removed = try XCTUnwrap(hosted.library.attachmentsById["r3"])
        picker.attachmentApproval(approval, didRemoveAttachment: AttachmentApprovalItem(attachment: removed, canSave: false))
        XCTAssertEqual(picker.selectedIdsForTesting, ["r4"], "预览页里删掉的，网格里也取消")

        picker.attachmentApproval(approval, didChangeMessageBody: MessageBody(text: "改过的说明", ranges: .empty))
        XCTAssertEqual(picker.captionTextForTesting, "改过的说明")
        XCTAssertEqual(hosted.delegate.bodies.last??.text, "改过的说明")

        picker.attachmentApprovalDidCancel()
        let closed = await waitUntil { picker.presentedViewController == nil }
        XCTAssertTrue(closed)
        XCTAssertEqual(picker.selectedIdsForTesting, ["r4"], "取消回到网格，选中的还在")
        XCTAssertEqual(hosted.delegate.cancels, 0, "只关预览页，不关选图")

        let edited = try XCTUnwrap(hosted.library.attachmentsById["r4"])
        picker.attachmentApproval(approval, didApproveAttachments: ApprovedAttachments(nonViewOnceAttachments: [edited], imageQuality: .high), messageBody: nil)
        let sent = try XCTUnwrap(hosted.delegate.sent.last)
        XCTAssertEqual(hosted.library.ids(of: sent.approved), ["r4"])
        XCTAssertEqual(sent.approved.imageQuality, .high)
        XCTAssertFalse(sent.separately)
    }

    // MARK: - P-11 上限

    /// 选满之后再勾（或滑过去）选不上，并提示「一次最多选 N 张」。
    @MainActor
    func testSelectionLimit() async throws {
        let hosted = host(maxSelection: 3)
        defer { hosted.tearDown() }
        let picker = hosted.picker

        for index in 0..<4 {
            picker.tapCheckForTesting(itemIndex: index)
        }
        XCTAssertEqual(picker.selectedIdsForTesting, ["r0", "r1", "r2"])
        XCTAssertEqual(toastTexts(in: picker.view), ["You can select up to 3 items at a time"])
        XCTAssertNil(picker.cellForTesting(itemIndex: 3)?.numberTextForTesting)

        let rowTwo = center(of: 3, in: picker)
        picker.swipeForTesting(through: [rowTwo, CGPoint(x: rowTwo.x + 12, y: rowTwo.y), center(of: 4, in: picker), center(of: 5, in: picker)])
        XCTAssertEqual(picker.selectedIdsForTesting, ["r0", "r1", "r2"], "滑过去也选不上")
    }

    // MARK: - 关闭（照 Telegram requestDismiss）

    /// 没选中：✕ 直接关。有选中：✕ 先问「丢弃媒体」，不直接关。
    @MainActor
    func testCloseAsksFirstOnlyWhenSomethingIsSelected() async throws {
        let hosted = host()
        defer { hosted.tearDown() }
        let picker = hosted.picker

        picker.tapCloseForTesting()
        XCTAssertEqual(hosted.delegate.cancels, 1)

        picker.tapCheckForTesting(itemIndex: 0)
        picker.tapCloseForTesting()
        XCTAssertEqual(hosted.delegate.cancels, 1, "有选中不直接关")
        let asked = await waitUntil { picker.presentedViewController is ActionSheetController }
        XCTAssertTrue(asked)
        let sheet = try XCTUnwrap(picker.presentedViewController as? ActionSheetController)
        XCTAssertEqual(sheet.actions.map { $0.button.configuration?.title }, ["Discard Media", CommonStrings.cancelButton])
    }

    // MARK: - 相册

    /// 「最近 ⌄」换相册：标题跟着换、网格换内容；别的相册里勾过的不丢。
    @MainActor
    func testSwitchAlbumKeepsSelection() async throws {
        let hosted = host()
        defer { hosted.tearDown() }
        let picker = hosted.picker
        XCTAssertEqual(picker.albumTitlesForTesting, ["Recents", "Screenshots"])

        picker.tapCheckForTesting(itemIndex: 0)
        picker.switchAlbumForTesting(title: "Screenshots")
        picker.collectionViewForTesting.layoutIfNeeded()
        XCTAssertEqual(picker.titleForTesting, "Screenshots")
        XCTAssertEqual(picker.collectionViewForTesting.numberOfItems(inSection: 0), 3)
        picker.tapCheckForTesting(itemIndex: 1)
        XCTAssertEqual(picker.selectedIdsForTesting, ["r0", "s1"])
        XCTAssertEqual(picker.cellForTesting(itemIndex: 1)?.numberTextForTesting, "2")
        XCTAssertEqual(picker.countPillTextForTesting, "2")
    }

    // MARK: - 单独发送的拆条（会话页那一头）

    /// 一张一条、按顺序；说明只挂最后一条；画质照原样；上一条没发出去就不发后面的。
    /// 时间戳不重复靠上游 `MessageTimestampGenerator`：连着取三次严格递增。
    @MainActor
    func testSendSeparatelyOnePerMessageCaptionOnLast() async throws {
        let library = FakePhotoLibrary()
        var attachments = [PreviewableAttachment]()
        for index in [2, 0, 5] {
            attachments.append(try await library.attachment(for: library.recents[index], attachmentLimits: .currentLimits()))
        }
        let approved = ApprovedAttachments(nonViewOnceAttachments: attachments, imageQuality: .high)
        let body = MessageBody(text: "今天的照片", ranges: .empty)

        struct Call: Equatable {
            let ids: [String]
            let body: String?
            let isHigh: Bool
        }
        var calls = [Call]()
        await TellomiPhotoPickerSending.sendSeparately(approved, messageBody: body) { part, partBody in
            calls.append(Call(ids: library.ids(of: part), body: partBody?.text, isHigh: part.imageQuality == .high))
            return true
        }
        XCTAssertEqual(calls, [
            Call(ids: ["r2"], body: nil, isHigh: true),
            Call(ids: ["r0"], body: nil, isHigh: true),
            Call(ids: ["r5"], body: "今天的照片", isHigh: true),
        ])

        calls.removeAll()
        await TellomiPhotoPickerSending.sendSeparately(approved, messageBody: body) { part, partBody in
            calls.append(Call(ids: library.ids(of: part), body: partBody?.text, isHigh: part.imageQuality == .high))
            return calls.count < 2
        }
        XCTAssertEqual(calls.map(\.ids), [["r2"], ["r0"]], "第二条没发出去，第三条不发")

        let timestamps = (0..<3).map { _ in MessageTimestampGenerator.sharedInstance.generateTimestamp() }
        XCTAssertEqual(timestamps, timestamps.sorted())
        XCTAssertEqual(Set(timestamps).count, 3)
    }

    // MARK: - P-3 只看已选

    /// 点「✓N」：网格换成「只看已选」——✕ 变返回、「✓N」「最近 ⌄」隐藏，「···」和说明栏照旧；顶部「消息预览」「拖动可调整顺序」；
    /// 卡片按勾的顺序、编号 1…N，行高与每张的宽照聊天里的相册（AlbumCarouselGeometry，放得下时靠右）；有说明时下面一个靠右的气泡；
    /// 铺的是会话的聊天背景。返回回到网格（不是关闭）。
    @MainActor
    func testCountPillShowsSelectedOnlyPreview() async throws {
        let background = UIView()
        background.backgroundColor = .systemTeal
        let hosted = host(initialText: "今天的照片", chatBackground: background)
        defer { hosted.tearDown() }
        let picker = hosted.picker
        for index in [3, 0, 5] {
            picker.tapCheckForTesting(itemIndex: index)
        }

        picker.tapCountPillForTesting()
        XCTAssertEqual(picker.displayMode, .selected)
        XCTAssertFalse(picker.isCountPillShownForTesting)
        XCTAssertFalse(picker.isTitleShownForTesting)
        XCTAssertEqual(picker.closeButtonAccessibilityLabelForTesting, CommonStrings.backButton)
        XCTAssertTrue(picker.isMoreButtonShownForTesting)
        XCTAssertTrue(picker.isSendBarShownForTesting)

        let preview = picker.selectedViewForTesting
        preview.layoutIfNeeded()
        XCTAssertTrue(preview.backgroundViewForTesting === background, "铺会话的聊天背景")
        XCTAssertEqual(preview.chipTextsForTesting, ["Message Preview", "Drag to reorder"])
        XCTAssertEqual(preview.cardIdsForTesting, ["r3", "r0", "r5"])
        XCTAssertEqual(preview.cardNumbersForTesting, ["1", "2", "3"])

        let expected = AlbumCarouselGeometry.layout(
            viewportWidth: 402,
            startInset: 16,
            endMargin: AlbumCarouselGeometry.endMargin,
            spacing: AlbumCarouselGeometry.itemSpacing,
            minNextPeek: AlbumCarouselGeometry.nextItemMinPeek,
            rowHeight: AlbumCarouselGeometry.rowHeight(screenWidth: 402, screenHeight: 874, capByScreenHeight: false),
            aspectRatios: [3, 0, 5].map { AlbumCarouselGeometry.aspectRatio(FakePhotoLibrary.pixelSizes[$0 % FakePhotoLibrary.pixelSizes.count]) },
            alignEndWhenFits: true,
        )
        XCTAssertEqual(preview.rowLayoutForTesting, expected, "按真实发出的样子：同聊天里的横滑相册")
        XCTAssertEqual(preview.cardFramesForTesting, (0..<3).map { expected.itemFrame($0) })
        XCTAssertEqual(preview.captionBubbleTextForTesting, "今天的照片")
        XCTAssertEqual(preview.captionBubbleFrameForTesting.maxX, 402 - AlbumCarouselGeometry.endMargin, accuracy: 0.01, "说明气泡靠右")
        XCTAssertGreaterThan(preview.captionBubbleFrameForTesting.minY, preview.rowFrameForTesting.maxY, "说明在那一行下面")

        picker.typeCaptionForTesting("改过的说明")
        XCTAssertEqual(preview.captionBubbleTextForTesting, "改过的说明", "说明改了，预览跟着变")
        XCTAssertEqual(hosted.delegate.bodies.last??.text, "改过的说明", "会话输入框也跟着变")

        picker.tapCloseForTesting()
        XCTAssertEqual(picker.displayMode, .all)
        XCTAssertTrue(picker.isCountPillShownForTesting)
        XCTAssertTrue(picker.isTitleShownForTesting)
        XCTAssertEqual(picker.closeButtonAccessibilityLabelForTesting, CommonStrings.dismissButton)
        XCTAssertEqual(hosted.delegate.cancels, 0, "返回不是关闭")
    }

    /// 只选一张：只有「消息预览」，没有「拖动可调整顺序」，也拿不起来排序；卡片靠右（同自己发的单张）。
    @MainActor
    func testSingleSelectionPreviewHasNoDragHint() async throws {
        let hosted = host()
        defer { hosted.tearDown() }
        hosted.picker.tapCheckForTesting(itemIndex: 2)
        hosted.picker.tapCountPillForTesting()
        let preview = hosted.picker.selectedViewForTesting
        preview.layoutIfNeeded()

        XCTAssertEqual(preview.chipTextsForTesting, ["Message Preview"])
        XCTAssertNil(preview.captionBubbleTextForTesting, "没有说明就没有气泡")
        let card = try XCTUnwrap(preview.cardFramesForTesting.first)
        XCTAssertEqual(card.maxX, 402 - AlbumCarouselGeometry.endMargin, accuracy: 0.01)
        XCTAssertFalse(preview.beginReorder(at: try XCTUnwrap(preview.cardCenterForTesting("r2"))))
    }

    /// 长按 0.3 秒拖动排序：拿起的那张跟着手指，越过别的卡片就换位，松手放下；新的顺序就是发出去的顺序（编号、网格、发送都照它）。
    @MainActor
    func testLongPressDragReordersSelection() async throws {
        let hosted = host()
        defer { hosted.tearDown() }
        let picker = hosted.picker
        for index in [3, 0, 5] {
            picker.tapCheckForTesting(itemIndex: index)
        }
        picker.tapCountPillForTesting()
        let preview = picker.selectedViewForTesting
        preview.layoutIfNeeded()
        XCTAssertEqual(preview.reorderPressDurationForTesting, 0.3, accuracy: 0.001)

        let start = try XCTUnwrap(preview.cardCenterForTesting("r3"))
        XCTAssertTrue(preview.beginReorder(at: start))
        XCTAssertTrue(preview.isReorderingForTesting)
        let over = try XCTUnwrap(preview.cardCenterForTesting("r0"))
        preview.moveReorder(to: CGPoint(x: over.x + 20, y: start.y + 30))
        XCTAssertEqual(preview.cardIdsForTesting, ["r0", "r3", "r5"])
        XCTAssertEqual(preview.cardNumbersForTesting, ["1", "2", "3"])
        XCTAssertEqual(picker.selectedIdsForTesting, ["r0", "r3", "r5"], "排序就是发出去的顺序")
        preview.endReorder()
        XCTAssertFalse(preview.isReorderingForTesting)

        picker.tapCloseForTesting()
        picker.collectionViewForTesting.layoutIfNeeded()
        XCTAssertEqual(picker.cellForTesting(itemIndex: 0)?.numberTextForTesting, "1")
        XCTAssertEqual(picker.cellForTesting(itemIndex: 3)?.numberTextForTesting, "2")
        XCTAssertEqual(picker.cellForTesting(itemIndex: 5)?.numberTextForTesting, "3")

        picker.tapSendForTesting()
        let sent = try await nextSend(hosted, count: 1)
        XCTAssertEqual(hosted.library.ids(of: sent.approved), ["r0", "r3", "r5"])
    }

    /// 拖到这一行的右端附近：整行自动往右滚，拿着的那张跟着往后排。
    @MainActor
    func testDragNearTheEndAutoScrollsTheRow() async throws {
        let hosted = host()
        defer { hosted.tearDown() }
        let picker = hosted.picker
        for index in [3, 0, 5, 9, 6] {
            picker.tapCheckForTesting(itemIndex: index)
        }
        picker.tapCountPillForTesting()
        let preview = picker.selectedViewForTesting
        preview.layoutIfNeeded()
        XCTAssertEqual(preview.rowLayoutForTesting?.isScrollable, true)

        let start = try XCTUnwrap(preview.cardCenterForTesting("r3"))
        XCTAssertTrue(preview.beginReorder(at: start))
        preview.moveReorder(to: CGPoint(x: preview.rowFrameForTesting.maxX - 10, y: start.y))
        for _ in 0..<120 {
            preview.autoScrollTick()
        }
        XCTAssertGreaterThan(preview.rowContentOffsetForTesting, 0, "整行往右滚了")
        XCTAssertEqual(preview.cardIdsForTesting.last, "r3", "拿着的那张一路排到最后")
        preview.endReorder()
        XCTAssertEqual(picker.selectedIdsForTesting.last, "r3")
    }

    /// 这一行松手吸附同聊天里的相册（某一张的左边对齐起点）。
    @MainActor
    func testPreviewRowSnapsLikeTheChatAlbum() async throws {
        let hosted = host()
        defer { hosted.tearDown() }
        for index in [3, 0, 5, 9] {
            hosted.picker.tapCheckForTesting(itemIndex: index)
        }
        hosted.picker.tapCountPillForTesting()
        let preview = hosted.picker.selectedViewForTesting
        preview.layoutIfNeeded()
        let layout = try XCTUnwrap(preview.rowLayoutForTesting)

        XCTAssertEqual(preview.scrollViewWillEndDraggingForTesting(projectedOffset: layout.snapOffsets[1] + 30, velocity: 0), layout.snapOffsets[1])
        XCTAssertEqual(preview.scrollViewWillEndDraggingForTesting(projectedOffset: 10, velocity: 1), layout.snapOffsets[1], "往右甩至少走一格")
    }

    /// 在「只看已选」里点某张的勾：取消它，说明栏上面弹「已取消选择 N 张 · 撤销」；再取消一张数字累加；撤销把它们放回原来的位置。
    @MainActor
    func testDeselectInPreviewOffersUndo() async throws {
        let hosted = host()
        defer { hosted.tearDown() }
        let picker = hosted.picker
        for index in [3, 0, 5] {
            picker.tapCheckForTesting(itemIndex: index)
        }
        picker.tapCountPillForTesting()
        let preview = picker.selectedViewForTesting
        preview.layoutIfNeeded()

        preview.tapCheckForTesting("r0")
        XCTAssertEqual(picker.selectedIdsForTesting, ["r3", "r5"])
        XCTAssertEqual(picker.undoBarTextForTesting, "1 deselected")
        XCTAssertEqual(picker.undoBarFrameForTesting.maxY, picker.sendBarFrameForTesting.minY - 8, accuracy: 0.01, "在说明栏上面")

        preview.tapCheckForTesting("r5")
        XCTAssertEqual(picker.undoBarTextForTesting, "2 deselected")
        XCTAssertEqual(preview.cardIdsForTesting, ["r3"])
        XCTAssertEqual(preview.chipTextsForTesting, ["Message Preview"], "只剩一张就不提示拖动")

        picker.tapUndoForTesting()
        XCTAssertEqual(picker.selectedIdsForTesting, ["r3", "r0", "r5"], "放回原来的位置")
        XCTAssertEqual(preview.cardIdsForTesting, ["r3", "r0", "r5"])
        let hidden = await waitUntil { picker.undoBarTextForTesting == nil }
        XCTAssertTrue(hidden)

        preview.tapCheckForTesting("r3")
        picker.expireUndoForTesting()
        picker.tapUndoForTesting()
        XCTAssertEqual(picker.selectedIdsForTesting, ["r0", "r5"], "过了时间就不能撤销")
    }

    /// 全部取消：自动回网格（撤销条还在，说明栏收起）；这时撤销，选中的回来、留在网格。
    @MainActor
    func testDeselectingEverythingReturnsToTheGrid() async throws {
        let hosted = host()
        defer { hosted.tearDown() }
        let picker = hosted.picker
        picker.tapCheckForTesting(itemIndex: 2)
        picker.tapCountPillForTesting()
        picker.selectedViewForTesting.layoutIfNeeded()

        picker.selectedViewForTesting.tapCheckForTesting("r2")
        XCTAssertEqual(picker.selectedIdsForTesting, [])
        let back = await waitUntil { picker.displayMode == .all }
        XCTAssertTrue(back, "全部取消自动回网格")
        XCTAssertEqual(picker.undoBarTextForTesting, "1 deselected")
        XCTAssertFalse(picker.isSendBarShownForTesting)

        picker.tapUndoForTesting()
        XCTAssertEqual(picker.selectedIdsForTesting, ["r2"])
        XCTAssertEqual(picker.displayMode, .all, "撤销后留在网格")
        XCTAssertTrue(picker.isCountPillShownForTesting)
    }

    /// 点卡片本身：进上游预览 / 编辑页，先看到点的那张（编辑页里仍是全部已选、顺序不变）；在那里取消，回到「只看已选」。
    @MainActor
    func testTapCardOpensTheUpstreamEditor() async throws {
        let hosted = host()
        defer { hosted.tearDown() }
        let picker = hosted.picker
        picker.tapCheckForTesting(itemIndex: 3)
        picker.tapCheckForTesting(itemIndex: 0)
        picker.tapCountPillForTesting()
        picker.selectedViewForTesting.layoutIfNeeded()

        picker.selectedViewForTesting.tapCardForTesting("r0")
        let opened = await waitUntil { self.approvalViewController(over: picker) != nil }
        XCTAssertTrue(opened)
        let approval = try XCTUnwrap(approvalViewController(over: picker))
        XCTAssertTrue(
            approval.currentItem?.attachment.rawValue === hosted.library.attachmentsById["r0"]?.rawValue,
            "点的是第 2 张卡片 r0，进来先看到它",
        )
        XCTAssertEqual(approval.attachmentApprovalItems.count, 2, "编辑页里仍是全部已选，顺序不变")
        XCTAssertTrue(approval.attachmentApprovalItems.first?.attachment.rawValue === hosted.library.attachmentsById["r3"]?.rawValue)
        picker.attachmentApprovalDidCancel()
        let closed = await waitUntil { picker.presentedViewController == nil }
        XCTAssertTrue(closed)
        XCTAssertEqual(picker.displayMode, .selected, "取消回到「只看已选」")
        XCTAssertEqual(picker.selectedIdsForTesting, ["r3", "r0"])
    }

    // MARK: - P-8 相机格

    /// 「最近」左上角是一格宽、两行高（含中间 1 的间距）的相机实时取景，其它格子绕开它排；换到别的相册就没有。
    @MainActor
    func testCameraCellSpansTwoRowsInRecents() async throws {
        let camera = FakeCamera(access: .authorized)
        let hosted = host(camera: camera)
        defer { hosted.tearDown() }
        let picker = hosted.picker

        let cameraFrame = try XCTUnwrap(picker.cameraFrameForTesting)
        let first = frame(of: 0, in: picker)
        XCTAssertEqual(cameraFrame.origin, .zero)
        XCTAssertEqual(cameraFrame.size.width, first.size.width, accuracy: 0.01, "一格宽")
        XCTAssertEqual(cameraFrame.size.height, first.size.height * 2 + 1, accuracy: 0.01, "两行高（含 1 的间距）")
        // 前两行的第 0 列让给相机：第 0、1 张在第一行第 1、2 列，第 2、3 张在第二行，第 4 张回到第三行第 0 列。
        XCTAssertEqual(first.minY, 0, accuracy: 0.01)
        XCTAssertGreaterThan(first.minX, cameraFrame.maxX)
        XCTAssertEqual(frame(of: 1, in: picker).minY, 0, accuracy: 0.01)
        XCTAssertEqual(frame(of: 2, in: picker).minY, first.maxY + 1, accuracy: 0.01)
        XCTAssertEqual(frame(of: 2, in: picker).minX, first.minX, accuracy: 0.01)
        XCTAssertEqual(frame(of: 4, in: picker).minX, 0, accuracy: 0.01)
        XCTAssertEqual(frame(of: 4, in: picker).minY, cameraFrame.maxY + 1, accuracy: 0.01)

        let cell = try XCTUnwrap(picker.cameraCellForTesting)
        XCTAssertTrue(cell.isShowingLivePreviewForTesting, "已授权：实时取景")
        XCTAssertTrue(cell.isShowingCornerIconForTesting, "右上角小相机图标")
        XCTAssertFalse(cell.isShowingPlaceholderForTesting)
        XCTAssertGreaterThanOrEqual(camera.starts, 1, "露出来就取景")

        let stopsBefore = camera.stops
        picker.switchAlbumForTesting(title: "Screenshots")
        picker.collectionViewForTesting.layoutIfNeeded()
        XCTAssertNil(picker.cameraFrameForTesting, "只在「最近」里")
        XCTAssertEqual(frame(of: 0, in: picker).origin, .zero)
        XCTAssertGreaterThan(camera.stops, stopsBefore, "看不见就停")

        let startsBefore = camera.starts
        picker.switchAlbumForTesting(title: "Recents")
        picker.collectionViewForTesting.layoutIfNeeded()
        XCTAssertNotNil(picker.cameraFrameForTesting)
        XCTAssertGreaterThan(camera.starts, startsBefore, "又露出来就重新取景")
    }

    /// 横屏 5 列：前两行每行 4 张在相机右边，第 8 张回到第三行第 0 列。
    @MainActor
    func testCameraCellInLandscape() async throws {
        let hosted = host(width: 874, height: 402, camera: FakeCamera(access: .authorized))
        defer { hosted.tearDown() }
        let picker = hosted.picker
        let cameraFrame = try XCTUnwrap(picker.cameraFrameForTesting)
        XCTAssertEqual(frame(of: 3, in: picker).minY, 0, accuracy: 0.01)
        XCTAssertEqual(frame(of: 4, in: picker).minX, frame(of: 0, in: picker).minX, accuracy: 0.01)
        XCTAssertEqual(frame(of: 8, in: picker).minX, 0, accuracy: 0.01)
        XCTAssertEqual(frame(of: 8, in: picker).minY, cameraFrame.maxY + 1, accuracy: 0.01)
    }

    /// 相机权限没问过：这一格只放相机图标，不取景；点了交给会话页去开相机（权限由上游相机流程问）。
    @MainActor
    func testCameraNotDeterminedShowsIconAndTapOpensCamera() async throws {
        let camera = FakeCamera(access: .notDetermined)
        let hosted = host(camera: camera)
        defer { hosted.tearDown() }
        let cell = try XCTUnwrap(hosted.picker.cameraCellForTesting)
        XCTAssertTrue(cell.isShowingPlaceholderForTesting)
        XCTAssertFalse(cell.isShowingLivePreviewForTesting)
        XCTAssertFalse(cell.isShowingCornerIconForTesting)

        cell.tapForTesting()
        XCTAssertEqual(hosted.delegate.cameraRequests, 1)
    }

    /// 没有相机或相机权限被拒：不挖这一格，第一张照片在左上角。
    @MainActor
    func testNoCameraCellWhenUnavailable() async throws {
        let hosted = host(camera: FakeCamera(access: .unavailable))
        defer { hosted.tearDown() }
        XCTAssertNil(hosted.picker.cameraFrameForTesting)
        XCTAssertNil(hosted.picker.cameraCellForTesting)
        XCTAssertEqual(frame(of: 0, in: hosted.picker).origin, .zero)
    }

    /// 有选中时点相机：拍到的不回到这里的已选里，所以同 ✕ 先问「丢弃媒体」，不直接打开。
    @MainActor
    func testCameraTapWithSelectionAsksFirst() async throws {
        let hosted = host(camera: FakeCamera(access: .authorized))
        defer { hosted.tearDown() }
        hosted.picker.tapCheckForTesting(itemIndex: 0)
        try XCTUnwrap(hosted.picker.cameraCellForTesting).tapForTesting()

        XCTAssertEqual(hosted.delegate.cameraRequests, 0)
        let asked = await waitUntil { hosted.picker.presentedViewController is ActionSheetController }
        XCTAssertTrue(asked)
    }

    // MARK: - 截图

    @MainActor
    func testScreenshots() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TELLOMI_SHOTS"] == "1", "只在 TELLOMI_SHOTS=1 时跑")
        let heights: [CGFloat: CGFloat] = [375: 812, 402: 874, 440: 956]
        for width in shotWidths {
            let height = heights[width] ?? 874

            let empty = host(width: width, height: height)
            try save(render(empty.window), name: "picker-1-empty.png", width: width)
            empty.tearDown()

            let selected = host(width: width, height: height, initialText: "今天的照片")
            for index in [3, 0, 5] {
                selected.picker.tapCheckForTesting(itemIndex: index)
            }
            try await settle()
            try save(render(selected.window), name: "picker-2-selected.png", width: width)
            selected.tearDown()

            let library = FakePhotoLibrary()
            library.isAccessLimited = true
            let limited = host(width: width, height: height, library: library)
            limited.picker.tapCheckForTesting(itemIndex: 1)
            try await settle()
            try save(render(limited.window), name: "picker-3-limited.png", width: width)
            limited.tearDown()

            let preview = host(width: width, height: height, initialText: "今天的照片", chatBackground: Self.shotChatBackground())
            for index in [3, 0, 5, 9] {
                preview.picker.tapCheckForTesting(itemIndex: index)
            }
            preview.picker.tapCountPillForTesting()
            try await settle()
            try save(render(preview.window), name: "picker-5-selected-preview.png", width: width)
            let view = preview.picker.selectedViewForTesting
            if let start = view.cardCenterForTesting("r3"), view.beginReorder(at: start) {
                view.moveReorder(to: CGPoint(x: start.x + 60, y: start.y + 24))
                try await settle()
                try save(render(preview.window), name: "picker-6-reordering.png", width: width)
                view.endReorder()
            }
            view.tapCheckForTesting("r0")
            try await settle()
            try save(render(preview.window), name: "picker-7-undo.png", width: width)
            preview.tearDown()

            let withCamera = host(width: width, height: height, camera: FakeCamera(access: .authorized))
            withCamera.picker.tapCheckForTesting(itemIndex: 1)
            try await settle()
            try save(render(withCamera.window), name: "picker-8-camera.png", width: width)
            withCamera.tearDown()

            // 键盘窗口按模拟器真实的屏幕排，这一张的窗口也用真实屏幕高（375 那台是 iPhone SE，667 高）。
            let screenSize = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.bounds.size }.first
            let emojiHeight = screenSize.map { $0.width == width ? $0.height : height } ?? height
            let emoji = host(width: width, height: emojiHeight, initialText: "今天的照片")
            emoji.window.makeKey()
            emoji.picker.tapCheckForTesting(itemIndex: 1)
            emoji.picker.tapCaptionEmojiButtonForTesting()
            try await settle()
            try save(renderScreen(over: emoji.window, keyboard: emoji.picker.captionEmojiKeyboardForTesting), name: "picker-9-emoji-keyboard.png", width: width)
            emoji.picker.endCaptionEditingForTesting()
            emoji.tearDown()

            let landscape = host(width: height, height: width)
            landscape.picker.tapCheckForTesting(itemIndex: 2)
            try await settle()
            try save(render(landscape.window), name: "picker-4-landscape.png", width: width)
            landscape.tearDown()
        }
    }

    // MARK: - Hosting

    private struct Hosted {
        let window: UIWindow
        let picker: TellomiPhotoPickerViewController
        let delegate: RecordingPickerDelegate
        let dataSource: FakeApprovalDataSource
        let library: FakePhotoLibrary

        func tearDown() {
            window.isHidden = true
        }
    }

    @MainActor
    private func host(
        width: CGFloat = 402,
        height: CGFloat = 874,
        library: FakePhotoLibrary = FakePhotoLibrary(),
        defaultImageQuality: ImageQuality = .standard,
        canSendSeparately: Bool = true,
        maxSelection: Int = 32,
        initialText: String? = nil,
        chatBackground: UIView? = nil,
        camera: TellomiPhotoPickerCamera? = nil,
    ) -> Hosted {
        let delegate = RecordingPickerDelegate()
        let dataSource = FakeApprovalDataSource()
        let picker = TellomiPhotoPickerViewController(
            library: library,
            initialMessageBody: initialText.map { MessageBody(text: $0, ranges: .empty) },
            defaultImageQuality: defaultImageQuality,
            canSendSeparately: canSendSeparately,
            hasQuotedReplyDraft: false,
            attachmentLimits: .currentLimits(),
            approvalDataSource: dataSource,
            stickerSheetDelegate: nil,
            chatBackground: chatBackground,
            camera: camera,
            maxSelection: maxSelection,
        )
        picker.delegate = delegate
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: height))
        window.backgroundColor = .Signal.background
        window.rootViewController = picker
        window.isHidden = false
        window.layoutIfNeeded()
        picker.collectionViewForTesting.layoutIfNeeded()
        return Hosted(window: window, picker: picker, delegate: delegate, dataSource: dataSource, library: library)
    }

    /// 截图用的「聊天背景」：一张浅色渐变（真机上是会话的壁纸）。
    @MainActor
    private static func shotChatBackground() -> UIView {
        let view = UIView()
        let gradient = CAGradientLayer()
        gradient.colors = [UIColor(rgbHex: 0xDCE8F5).cgColor, UIColor(rgbHex: 0xF3E7F0).cgColor]
        gradient.frame = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        view.layer.addSublayer(gradient)
        return view
    }

    @MainActor
    private func frame(of item: Int, in picker: TellomiPhotoPickerViewController) -> CGRect {
        picker.collectionViewForTesting.layoutAttributesForItem(at: IndexPath(item: item, section: 0))?.frame ?? .null
    }

    @MainActor
    private func center(of item: Int, in picker: TellomiPhotoPickerViewController) -> CGPoint {
        let frame = frame(of: item, in: picker)
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    @MainActor
    private func approvalViewController(over picker: TellomiPhotoPickerViewController) -> AttachmentApprovalViewController? {
        (picker.presentedViewController as? UINavigationController)?.viewControllers.first as? AttachmentApprovalViewController
    }

    @MainActor
    private func nextSend(_ hosted: Hosted, count: Int) async throws -> RecordingPickerDelegate.Sent {
        let arrived = await waitUntil { hosted.delegate.sent.count >= count }
        XCTAssertTrue(arrived, "发送交给了会话页")
        return try XCTUnwrap(hosted.delegate.sent.last)
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                return false
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }

    @MainActor
    private func settle() async throws {
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    private func toastTexts(in view: UIView) -> [String] {
        var texts = [String]()
        if let toast = view as? ToastView, let text = toast.text {
            texts.append(text)
        }
        for subview in view.subviews {
            texts += toastTexts(in: subview)
        }
        return texts
    }

    // MARK: - Screenshots

    private var shotWidths: [CGFloat] {
        let raw = ProcessInfo.processInfo.environment["TELLOMI_SHOT_WIDTHS"] ?? "402,440,375"
        return raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }.map { CGFloat($0) }
    }

    @MainActor
    private func render(_ window: UIWindow) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    /// 连同键盘一起拍：键盘在另外的窗口里（表情键盘在 UIRemoteKeyboardWindow，它不在 scene 的 windows 里），
    /// 按层级把测试窗口、它上面的窗口和键盘所在的窗口都画上（测试窗口盖住宿主 App 的窗口）。
    @MainActor
    private func renderScreen(over window: UIWindow, keyboard: UIView?) -> UIImage {
        var windows = (window.windowScene?.windows ?? [window])
            .filter { !$0.isHidden && ($0 === window || $0.windowLevel > window.windowLevel) }
        if let keyboardWindow = keyboard?.window, !windows.contains(where: { $0 === keyboardWindow }) {
            windows.append(keyboardWindow)
        }
        windows.sort { $0.windowLevel < $1.windowLevel }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            for each in windows {
                each.drawHierarchy(in: each.frame, afterScreenUpdates: true)
            }
        }
    }

    private func save(_ image: UIImage, name: String, width: CGFloat) throws {
        let root = ProcessInfo.processInfo.environment["TELLOMI_SHOTS_DIR"] ?? NSTemporaryDirectory()
        let directory = URL(fileURLWithPath: root).appendingPathComponent("\(Int(width))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent(name))
    }
}

// MARK: - Fakes

/// 内存里的相册：「最近」24 项（第 2、8 项是视频，第 3 项是实况照片），「Screenshots」3 项；缩略图是纯色块。
private final class FakePhotoLibrary: TellomiPhotoPickerLibrary {
    var isAccessLimited = false
    var onChange: (() -> Void)?

    let recents: [TellomiPhotoPickerItem]
    let screenshots: [TellomiPhotoPickerItem]

    /// 各种比例轮着来：横 4:3、竖 3:4、方、宽 16:9、窄 9:16、3:2。
    static let pixelSizes = [
        CGSize(width: 4032, height: 3024),
        CGSize(width: 3024, height: 4032),
        CGSize(width: 2000, height: 2000),
        CGSize(width: 1920, height: 1080),
        CGSize(width: 1080, height: 1920),
        CGSize(width: 3000, height: 2000),
    ]

    /// 交出去的附件，按网格里的 id（用来核对发送顺序）。
    private(set) var attachmentsById = [String: PreviewableAttachment]()

    init() {
        recents = (0..<24).map { index in
            TellomiPhotoPickerItem(
                id: "r\(index)",
                isVideo: index == 1 || index == 7,
                duration: index == 1 ? 75 : 3_725,
                isLivePhoto: index == 2,
                pixelSize: Self.pixelSizes[index % Self.pixelSizes.count],
                asset: nil,
            )
        }
        screenshots = (0..<3).map { index in
            TellomiPhotoPickerItem(id: "s\(index)", isVideo: false, duration: 0, isLivePhoto: false, pixelSize: CGSize(width: 1170, height: 2532), asset: nil)
        }
    }

    func albums() -> [TellomiPhotoPickerAlbum] {
        [
            TellomiPhotoPickerAlbum(id: "recents", title: TellomiSystemPhotoLibrary.recentsTitle, count: recents.count, isRecents: true),
            TellomiPhotoPickerAlbum(id: "screenshots", title: "Screenshots", count: screenshots.count, isRecents: false),
        ]
    }

    private func items(in album: TellomiPhotoPickerAlbum) -> [TellomiPhotoPickerItem] {
        album.id == "screenshots" ? screenshots : recents
    }

    func itemCount(in album: TellomiPhotoPickerAlbum) -> Int {
        items(in: album).count
    }

    func item(at index: Int, in album: TellomiPhotoPickerAlbum) -> TellomiPhotoPickerItem {
        items(in: album)[index]
    }

    private struct NoopRequest: TellomiPhotoPickerRequest {
        func cancel() {}
    }

    func requestThumbnail(for item: TellomiPhotoPickerItem, targetSize: CGSize, completion: @escaping (UIImage?) -> Void) -> TellomiPhotoPickerRequest {
        completion(image(for: item, size: CGSize(width: 90, height: 90)))
        return NoopRequest()
    }

    private func color(for item: TellomiPhotoPickerItem) -> UIColor {
        let index = Int(item.id.dropFirst()) ?? 0
        if item.id.hasPrefix("s") {
            return UIColor(white: 0.25 + 0.2 * CGFloat(index), alpha: 1)
        }
        return UIColor(hue: CGFloat(index % 12) / 12, saturation: 0.5, brightness: 0.85, alpha: 1)
    }

    private func image(for item: TellomiPhotoPickerItem, size: CGSize) -> UIImage {
        let color = color(for: item)
        return UIGraphicsImageRenderer(size: size).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.withAlphaComponent(0.3).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: size.width * 0.3, y: size.height * 0.3, width: size.width * 0.4, height: size.height * 0.4))
        }
    }

    func attachment(for item: TellomiPhotoPickerItem, attachmentLimits: OutgoingAttachmentLimits) async throws -> PreviewableAttachment {
        let data = try XCTUnwrap(image(for: item, size: CGSize(width: 64, height: 48)).jpegData(compressionQuality: 0.8))
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".jpg")
        try data.write(to: url)
        let attachment = try PreviewableAttachment.imageAttachment(
            dataSource: DataSourcePath(fileUrl: url, ownership: .owned),
            dataUTI: UTType.jpeg.identifier,
        )
        attachmentsById[item.id] = attachment
        return attachment
    }

    func ids(of approved: ApprovedAttachments) -> [String] {
        approved.attachments.map { attachment in
            attachmentsById.first { $0.value.rawValue === attachment.rawValue }?.key ?? "?"
        }
    }
}

private final class RecordingPickerDelegate: TellomiPhotoPickerDelegate {
    struct Sent {
        let approved: ApprovedAttachments
        let body: MessageBody?
        let separately: Bool
    }

    var cancels = 0
    var cameraRequests = 0
    var sent = [Sent]()
    var bodies = [MessageBody?]()

    func photoPickerDidCancel(_ picker: TellomiPhotoPickerViewController) {
        cancels += 1
    }

    func photoPickerDidRequestCamera(_ picker: TellomiPhotoPickerViewController) {
        cameraRequests += 1
    }

    func photoPicker(_ picker: TellomiPhotoPickerViewController, send approvedAttachments: ApprovedAttachments, messageBody: MessageBody?, separately: Bool) {
        sent.append(Sent(approved: approvedAttachments, body: messageBody, separately: separately))
    }

    func photoPicker(_ picker: TellomiPhotoPickerViewController, didChangeMessageBody messageBody: MessageBody?) {
        bodies.append(messageBody)
    }
}

/// 假相机：记下起停次数；「取景」是一块深色渐变（截图用）。
private final class FakeCamera: TellomiPhotoPickerCamera {
    let access: TellomiPhotoPickerCameraAccess
    var starts = 0
    var stops = 0

    init(access: TellomiPhotoPickerCameraAccess) {
        self.access = access
    }

    func makePreviewView() -> UIView {
        let view = UIView()
        let gradient = CAGradientLayer()
        gradient.colors = [UIColor(rgbHex: 0x3A4F63).cgColor, UIColor(rgbHex: 0x14202B).cgColor]
        gradient.frame = CGRect(x: 0, y: 0, width: 600, height: 1200)
        view.layer.addSublayer(gradient)
        view.clipsToBounds = true
        return view
    }

    func startPreview() {
        starts += 1
    }

    func stopPreview() {
        stops += 1
    }
}

private final class FakeApprovalDataSource: AttachmentApprovalViewControllerDataSource {
    var attachmentApprovalTextInputContextIdentifier: String? { nil }
    var attachmentApprovalRecipientNames: [String] { ["Alice"] }

    func attachmentApprovalMentionableAcis(tx: DBReadTransaction) -> [Aci] { [] }

    func attachmentApprovalMentionCacheInvalidationKey() -> String { "tellomi-photo-picker-tests" }
}
