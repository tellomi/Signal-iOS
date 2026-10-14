//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// Tellomi（tellomi/tellomi#1522 E-4）：图片编辑器文字的对齐与半透明底（照 Telegram 两端文字的对齐键、`.semi` 样式）。
final class TellomiImageEditorTextTests: SignalBaseTest {

    /// 对齐按 左 → 中 → 右 → 左 循环，默认居中。
    func testAlignmentCyclesLeftCenterRight() {
        XCTAssertEqual(ImageEditorViewController.nextTextAlignment(after: .center), .right)
        XCTAssertEqual(ImageEditorViewController.nextTextAlignment(after: .right), .left)
        XCTAssertEqual(ImageEditorViewController.nextTextAlignment(after: .left), .center)
        XCTAssertEqual(TextStylingToolbar().textAlignment, .center)
        XCTAssertNil(TextStylingToolbar().alignmentButton, "快拍的文字没有对齐键")
        XCTAssertNotNil(TextStylingToolbar(showsAlignment: true).alignmentButton)
    }

    /// 样式顺序：无、白底、彩底、半透明底、下划线，再回到无；描边不在里面（上游本来就跳过）。
    func testDecorationCycleHasTheSemiTransparentBackground() {
        var style = MediaTextView.DecorationStyle.none
        var seen = [style]
        for _ in 0..<5 {
            style = ImageEditorViewController.nextDecorationStyle(after: style)
            seen.append(style)
        }
        XCTAssertEqual(seen, [.none, .whiteBackground, .coloredBackground, .semiTransparentBackground, .underline, .none])
    }

    /// 半透明底：字是选的颜色；亮的字配 75% 黑底，暗的字配 75% 白底。
    func testSemiTransparentBackgroundColors() {
        let onWhiteText = item(color: .white, decorationStyle: .semiTransparentBackground)
        XCTAssertEqual(onWhiteText.textForegroundColor, .white)
        XCTAssertEqual(onWhiteText.textBackgroundColor, UIColor.black.withAlphaComponent(0.75))
        XCTAssertNil(onWhiteText.textDecorationColor)

        let onBlackText = item(color: .black, decorationStyle: .semiTransparentBackground)
        XCTAssertEqual(onBlackText.textBackgroundColor, UIColor.white.withAlphaComponent(0.75))
    }

    /// 改别的属性时对齐跟着走。
    func testCopiesKeepTheAlignment() {
        let left = item(color: .white, decorationStyle: .none, textAlignment: .left)
        XCTAssertEqual(left.with(fontSize: 20).textAlignment, .left)
        XCTAssertEqual(left.with(text: "b", color: .black).textAlignment, .left)
        XCTAssertEqual(left.with(unitWidth: 0.5).textAlignment, .left)
        XCTAssertEqual(left.with(textStyle: .bold, decorationStyle: .none, textAlignment: .right).textAlignment, .right)
        XCTAssertNotEqual(left, left.with(textStyle: left.textStyle, decorationStyle: left.decorationStyle, textAlignment: .right))
    }

    /// 画出来的文字图层照对齐排。
    @MainActor
    func testCanvasTextLayerFollowsTheAlignment() throws {
        let model = try ImageEditorModel(normalizedImage: NormalizedImage.forImage(UIImage.image(color: .gray, size: CGSize(square: 400))))
        let viewSize = CGSize(square: 400)
        for (alignment, mode) in [(NSTextAlignment.left, CATextLayerAlignmentMode.left), (.center, .center), (.right, .right)] {
            let textItem = item(color: .white, decorationStyle: .semiTransparentBackground, textAlignment: alignment)
            let layer = try XCTUnwrap(ImageEditorCanvasView.textLayerForTesting(item: textItem, model: model, viewSize: viewSize))
            XCTAssertEqual(layer.alignmentMode, mode)
        }
    }

    private func item(
        color: UIColor,
        decorationStyle: MediaTextView.DecorationStyle,
        textAlignment: NSTextAlignment = .center,
    ) -> ImageEditorTextItem {
        ImageEditorTextItem(
            text: "Hello\nTellomi text",
            color: color == .white ? .white : .black,
            fontSize: ImageEditorTextItem.defaultFontSize,
            decorationStyle: decorationStyle,
            textAlignment: textAlignment,
            fontReferenceImageWidth: 400,
        )
    }
}
