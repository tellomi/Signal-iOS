//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest
@testable import Signal

/// Do we correctly compute "centered deadzones" of images?
class BitmapsImageCenteredDeadzoneTest: XCTestCase {
    func testCenteredDeadzones() {
        for testCase in TestCase.all {
            XCTAssertEqual(
                testCase.image.centeredDeadzone(
                    dimensionPercentage: testCase.percentage,
                    paddingPoints: testCase.paddingPoints,
                ),
                testCase.expectedRect,
            )
        }
    }
}

private struct TestCase {
    let image: Bitmaps.Image
    let percentage: CGFloat
    let paddingPoints: Int
    let expectedRect: Bitmaps.Rect

    static let all: [TestCase] = [
        .usernameLinkQRCodeSize,
        .evenRemainder,
        .oddRemainder,
    ]

    static let usernameLinkQRCodeSize = TestCase(
        image: Bitmaps.Image(width: 39, height: 39, rawBytes: []),
        percentage: 1 / 3,
        paddingPoints: 0,
        expectedRect: Bitmaps.Rect(x: 13, y: 13, width: 13, height: 13),
    )

    static let evenRemainder = TestCase(
        image: Bitmaps.Image(width: 30, height: 30, rawBytes: []),
        percentage: 1 / 3,
        paddingPoints: 0,
        expectedRect: Bitmaps.Rect(x: 10, y: 10, width: 10, height: 10),
    )

    static let evenRemainderWithPadding = TestCase(
        image: Bitmaps.Image(width: 30, height: 30, rawBytes: []),
        percentage: 1 / 3,
        paddingPoints: 1,
        expectedRect: Bitmaps.Rect(x: 9, y: 9, width: 11, height: 11),
    )

    static let oddRemainder = TestCase(
        image: Bitmaps.Image(width: 30, height: 41, rawBytes: []),
        percentage: 0.25,
        paddingPoints: 0,
        expectedRect: Bitmaps.Rect(x: 11, y: 15, width: 8, height: 11),
    )
}

/// Tellomi（tellomi/tellomi#947）：默认样式不带中心标，生成的码要能被解出原文。
/// 带标样式为什么不用，见 `QRCodeGenerator.StylingMode.tellomiDefault` 的注释。
class QRCodeTellomiDefaultStylingTest: XCTestCase {
    func testDefaultStylingHasNoCenterMark() {
        XCTAssertEqual(QRCodeGenerator.StylingMode.tellomiDefault, .brandedWithoutLogo)
    }

    /// 和真实设备关联码长度相近的链接，生成 30 次，全部要能解出原文。
    func testDefaultStylingDecodes() throws {
        let detector = try XCTUnwrap(CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh],
        ))

        for _ in 0..<30 {
            let pubKey = (0..<33).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
            let url = try XCTUnwrap(URL(string: "sgnl://linkdevice?uuid=\(UUID().uuidString)&pub_key=\(pubKey)"))

            let image = try XCTUnwrap(QRCodeGenerator().generateQRCode(url: url))

            // 生成的码是黑色前景、透明背景；先铺白底再解。
            let flattened = UIGraphicsImageRenderer(size: image.size).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: image.size))
                image.draw(at: .zero)
            }
            let ciImage = try XCTUnwrap(CIImage(image: flattened))
            let decoded = (detector.features(in: ciImage).first as? CIQRCodeFeature)?.messageString

            XCTAssertEqual(decoded, url.absoluteString)
        }
    }
}
