//
// Copyright 2026 Tellomi
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

/// Tellomi：界面上不能再出现 Signal 的标（「Signal」是注册商标，CLAUDE.md 许可证红线）。
/// 这里钉住上游合并时容易被悄悄换回去的图。
final class TellomiBrandAssetsTest: XCTestCase {

    /// 「外观 → App 图标」里「默认」那一项的预览（`AppearanceSettingsTableViewController` 显示当前图标的那一行也用它）。
    /// 上游这张是 Signal 的蓝底标；换成的是 `AppIcon.icon` 用 Icon Composer（ictool）导出的 180px 图，深色底 + Tellomi 标。
    /// 取左上角、图标圆角以内、标的圆环以外的一点：Tellomi 是深色，Signal 是蓝色。
    func testDefaultAppIconPreviewIsNotTheSignalMark() throws {
        let image = UIImage(resource: AppIcon.default.previewImageResource)
        let pixel = try XCTUnwrap(rgba(of: image, atRelativeX: 0.15, relativeY: 0.15))
        XCTAssertEqual(pixel.alpha, 1, accuracy: 0.01)
        XCTAssertLessThan(max(pixel.red, pixel.green, pixel.blue), 0.35, "预览不是深色底：\(pixel)")
        XCTAssertLessThan(pixel.blue - pixel.red, 0.1, "预览像 Signal 的蓝底：\(pixel)")
    }

    private func rgba(of image: UIImage, atRelativeX x: CGFloat, relativeY y: CGFloat) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)? {
        guard let cgImage = image.cgImage else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
            ) else {
                return false
            }
            // 把要取的那一点对到 1×1 画布的原点（CoreGraphics 的 y 轴朝上）
            let width = CGFloat(cgImage.width)
            let height = CGFloat(cgImage.height)
            context.draw(cgImage, in: CGRect(x: -x * width, y: -(1 - y) * height, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let alpha = CGFloat(bytes[3]) / 255
        guard alpha > 0 else { return (0, 0, 0, 0) }
        return (CGFloat(bytes[0]) / 255 / alpha, CGFloat(bytes[1]) / 255 / alpha, CGFloat(bytes[2]) / 255 / alpha, alpha)
    }
}
