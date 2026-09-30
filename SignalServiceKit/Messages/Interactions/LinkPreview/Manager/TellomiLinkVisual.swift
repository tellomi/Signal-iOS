//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

public import Foundation
import LibSignalClient

/// card-visual §3.2 / §3.3 / §3.8（tellomi/tellomi#1423）：卡片的版式，以及从卡片自己的图取的颜色，都由 rust/links 定
/// （`layout` / `tint`，三端答案一样）；这里只读结果、不自己算。与 Android `TellomiLinkVisual.kt`、Desktop `linkCardVisual.std.ts` 同一套。
public enum TellomiLinkVisual {

    /// rust/links 要的图：32×32、每像素 R G B A 一字节。
    public static let tintSize: UInt32 = 32

    public enum Layout: String, Equatable, Sendable {
        case firstParty = "first_party"
        case largeImage = "large_image"
        case icon
        case noImage = "no_image"
    }

    public struct RGB: Equatable, Sendable {
        public let red: UInt8
        public let green: UInt8
        public let blue: UInt8

        public init(red: UInt8, green: UInt8, blue: UInt8) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    public struct Colors: Equatable, Sendable {
        public let background: RGB
        public let text: RGB

        public init(background: RGB, text: RGB) {
            self.background = background
            self.text = text
        }
    }

    public struct Tint: Equatable, Sendable {
        public let tinted: Bool
        public let light: Colors?
        public let dark: Colors?

        public init(tinted: Bool, light: Colors? = nil, dark: Colors? = nil) {
            self.tinted = tinted
            self.light = light
            self.dark = dark
        }

        /// nil：这张卡保持默认颜色。
        public func colors(isDark: Bool) -> Colors? {
            guard tinted else {
                return nil
            }
            return isDark ? dark : light
        }
    }

    /// 数据层给一张卡定下的：版式（nil：没有决定，照原样显示）和图的颜色（nil：默认颜色）。
    public struct Visual: Equatable, Sendable {
        public let layout: Layout?
        public let tint: Tint?

        public init(layout: Layout?, tint: Tint?) {
            self.layout = layout
            self.tint = tint
        }

        public static let none = Visual(layout: nil, tint: nil)
    }

    /// 两个原生调用；留一道缝，好在没有原生库时测读结果和缩图这部分。
    public protocol Bridge {
        func layout(imageWidth: UInt32, imageHeight: UInt32, kind: String, level: String) throws -> String
        func tint(layout: String, width: UInt32, height: UInt32, rgba: Data) throws -> String
    }

    public struct Native: Bridge {
        public init() {}

        public func layout(imageWidth: UInt32, imageHeight: UInt32, kind: String, level: String) throws -> String {
            try Links.layout(imageWidth: imageWidth, imageHeight: imageHeight, kind: kind, level: level)
        }

        public func tint(layout: String, width: UInt32, height: UInt32, rgba: Data) throws -> String {
            try Links.tint(layout: layout, width: width, height: height, rgba: rgba)
        }
    }

    private struct WireColors: Decodable {
        let background: String
        let text: String
    }

    private struct WireTint: Decodable {
        let tinted: Bool
        let light: WireColors?
        let dark: WireColors?
    }

    /// 四种版式之外（新版 rust/links 多出来的）一律当没有决定。
    public static func parseLayout(_ text: String) -> Layout? {
        return Layout(rawValue: text)
    }

    public static func parseTint(_ text: String) -> Tint? {
        guard
            let data = text.data(using: .utf8),
            let wire = try? JSONDecoder().decode(WireTint.self, from: data)
        else {
            return nil
        }
        guard wire.tinted else {
            return Tint(tinted: false)
        }
        guard
            let light = wire.light.flatMap(colors(from:)),
            let dark = wire.dark.flatMap(colors(from:))
        else {
            return nil
        }
        return Tint(tinted: true, light: light, dark: dark)
    }

    /// §3.3：消息请求里不染，第一方和支付卡不染，只有带图（图标卡、大图卡）才有颜色可取。
    public static func shouldTint(card: TellomiLinkCard?, layout: Layout?, isMessageRequest: Bool) -> Bool {
        guard let card, !isMessageRequest, card.tintable, !card.payment else {
            return false
        }
        return layout == .icon || layout == .largeImage
    }

    /// nil：没有决定（桥失败），卡片照没有版式之前的样子显示。不显示图的卡问的时候没有图。
    public static func layout(bridge: any Bridge, card: TellomiLinkCard, imageWidth: Int, imageHeight: Int) -> Layout? {
        let showsImage = card.showImage
        do {
            let text = try bridge.layout(
                imageWidth: showsImage ? UInt32(clamping: max(imageWidth, 0)) : 0,
                imageHeight: showsImage ? UInt32(clamping: max(imageHeight, 0)) : 0,
                kind: showsImage ? (card.kind ?? "") : "",
                level: card.level.rawValue,
            )
            return parseLayout(text)
        } catch {
            return nil
        }
    }

    /// `rgba` 必须是 32×32 的 R G B A 像素（缩图在界面层做）；别的大小不交给 rust/links。
    public static func tint(bridge: any Bridge, layout: Layout, rgba: Data) -> Tint? {
        guard rgba.count == Int(tintSize * tintSize * 4) else {
            return nil
        }
        do {
            return parseTint(try bridge.tint(layout: layout.rawValue, width: tintSize, height: tintSize, rgba: rgba))
        } catch {
            return nil
        }
    }

    /// 在数据层（工作线程）跟卡一起定：版式，以及要染色时图的颜色。
    /// `readPixels` 读出卡显示的那张图缩成 32×32 的 RGBA；图还没下载完时给 nil。
    /// 要不要用、用浅色还是深色那套，绑定视图时再定（消息请求里不用）；颜色本身两种情况一样。
    public static func decide(
        bridge: any Bridge,
        card: TellomiLinkCard?,
        imageWidth: Int,
        imageHeight: Int,
        readPixels: () -> Data?,
    ) -> Visual {
        guard let card, let layout = layout(bridge: bridge, card: card, imageWidth: imageWidth, imageHeight: imageHeight) else {
            return .none
        }
        guard shouldTint(card: card, layout: layout, isMessageRequest: false), let pixels = readPixels() else {
            return Visual(layout: layout, tint: nil)
        }
        let tint = tint(bridge: bridge, layout: layout, rgba: pixels)
        return Visual(layout: layout, tint: tint.flatMap { $0.tinted ? $0 : nil })
    }

    private static func colors(from wire: WireColors) -> Colors? {
        guard let background = rgb(from: wire.background), let text = rgb(from: wire.text) else {
            return nil
        }
        return Colors(background: background, text: text)
    }

    /// 只认 `#RRGGBB`。
    private static func rgb(from hex: String) -> RGB? {
        let digits = Array(hex.utf8)
        guard digits.count == 7, digits[0] == UInt8(ascii: "#") else {
            return nil
        }
        var value: UInt32 = 0
        for digit in digits.dropFirst() {
            let nibble: UInt32
            switch digit {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): nibble = UInt32(digit - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): nibble = UInt32(digit - UInt8(ascii: "a")) + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): nibble = UInt32(digit - UInt8(ascii: "A")) + 10
            default: return nil
            }
            value = value << 4 | nibble
        }
        return RGB(red: UInt8(value >> 16 & 0xFF), green: UInt8(value >> 8 & 0xFF), blue: UInt8(value & 0xFF))
    }
}
