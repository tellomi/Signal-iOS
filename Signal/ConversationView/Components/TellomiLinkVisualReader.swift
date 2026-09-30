//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import CoreGraphics
import Foundation
import SignalServiceKit
import SignalUI

/// 卡片版式和染色在数据层的落点（card-visual §3.2 / §3.3，tellomi/tellomi#1423）：版式和颜色都由 rust/links 定，
/// 这里只做两件事——把卡片显示的那张图缩成 32×32 的 RGBA 交给它，再把结果按附件缓存起来（同一张图不重复解码）。
/// 图还没下载完时不读像素：先只有版式，图到了以后消息重新构建，再有颜色。
enum TellomiLinkVisualReader {

    private final class CachedVisual {
        let visual: TellomiLinkVisual.Visual
        init(_ visual: TellomiLinkVisual.Visual) { self.visual = visual }
    }

    private static let cache: NSCache<NSString, CachedVisual> = {
        let cache = NSCache<NSString, CachedVisual>()
        cache.countLimit = 300
        return cache
    }()

    /// `attachment`：卡片显示的预览图（用户卡等不显示图的卡，传了也不会用）。品牌壳的“图”是随包图标（card-visual §3.9），
    /// 不看发送端的图；`icon` 是它，没有（注册表没给、包里没有、解不开）就是 nil，卡片只出平台名 + 域名。
    static func visual(
        card: TellomiLinkCard,
        attachment: ReferencedAttachment?,
        imagePixelSize: CGSize,
        icon: TellomiLinkIcon.Icon? = nil,
        bridge: any TellomiLinkVisual.Bridge = TellomiLinkVisual.Native(),
    ) -> TellomiLinkVisual.Visual {
        if card.level == .brand {
            return brandVisual(card: card, icon: icon, bridge: bridge)
        }
        let width = Int(imagePixelSize.width.rounded())
        let height = Int(imagePixelSize.height.rounded())
        let stream = card.showImage ? attachment?.attachment.asStream() : nil

        // 缓存键包含决定用到的一切：哪张图、多大、什么 kind / 级别、染不染。
        let key: NSString? = stream.map {
            [
                String($0.id),
                "\(width)x\(height)",
                card.kind ?? "-",
                card.level.rawValue,
                card.tintable ? "t" : "-",
                card.payment ? "p" : "-",
            ].joined(separator: "|") as NSString
        }
        if let key, let cached = cache.object(forKey: key) {
            return cached.visual
        }

        let visual = TellomiLinkVisual.decide(
            bridge: bridge,
            card: card,
            imageWidth: width,
            imageHeight: height,
            readPixels: { stream.flatMap { pixels(of: $0) } },
        )
        // 只缓存读到了图的结果；没读到（还没下载完）下次还要再试。
        if let key, stream != nil {
            cache.setObject(CachedVisual(visual), forKey: key)
        }
        return visual
    }

    /// 品牌壳：版式按随包图标的尺寸问 rust/links，要染色时把图标缩成 32×32 交给它；没有图标就是 0 × 0（无图卡，和以前一样）。
    private static func brandVisual(
        card: TellomiLinkCard,
        icon: TellomiLinkIcon.Icon?,
        bridge: any TellomiLinkVisual.Bridge,
    ) -> TellomiLinkVisual.Visual {
        let key = [
            "icon",
            icon?.name ?? "-",
            card.kind ?? "-",
            card.tintable ? "t" : "-",
            card.payment ? "p" : "-",
        ].joined(separator: "|") as NSString
        if let cached = cache.object(forKey: key) {
            return cached.visual
        }
        let visual = TellomiLinkVisual.decide(
            bridge: bridge,
            card: card,
            imageWidth: icon?.pixelWidth ?? 0,
            imageHeight: icon?.pixelHeight ?? 0,
            readPixels: { icon.flatMap { pixels(of: $0.image) } },
        )
        cache.setObject(CachedVisual(visual), forKey: key)
        return visual
    }

    /// 缩成 32×32 的 R G B A（不预乘），原点在左上——`Links.tint` 的大图卡取的是最下面那一条。
    private static func pixels(of stream: AttachmentStream) -> Data? {
        guard let image = stream.thumbnailImageSync(quality: .small)?.cgImage else {
            return nil
        }
        return pixels(of: image)
    }

    static func pixels(of image: CGImage) -> Data? {
        let size = Int(TellomiLinkVisual.tintSize)
        var buffer = [UInt8](repeating: 0, count: size * size * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard
                let context = CGContext(
                    data: raw.baseAddress,
                    width: size,
                    height: size,
                    bitsPerComponent: 8,
                    bytesPerRow: size * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
                )
            else {
                return false
            }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard drawn else {
            return nil
        }
        // 预乘 → 不预乘：半透明像素的颜色不能被 alpha 压暗（rust/links 会丢掉 alpha < 128 的像素，其余按原色算）。
        for index in stride(from: 0, to: buffer.count, by: 4) {
            let alpha = Int(buffer[index + 3])
            guard alpha > 0, alpha < 255 else {
                continue
            }
            for channel in 0..<3 {
                buffer[index + channel] = UInt8(min(255, Int(buffer[index + channel]) * 255 / alpha))
            }
        }
        return Data(buffer)
    }
}
