//
// Copyright 2026 Tellomi
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Tellomi 的链接 / scheme 形状（`docs/signal/LINKS_AND_SCHEMES.md`，与 Android `util/TellomiLinks.kt`、Desktop `signalRoutes.std.ts` 同一张表）：
///
///   `sgnl://` → `tellomi://`，`signalcaptcha://` → `tellomicaptcha://`，
///   `signal.me | .group | .art | .link` → `tell.cc/u | g | s | call`。
///
/// 两阶段迁移里这是**接受**半边：新旧形状同时认，各端独立上线。做法不是把 `||` 散进十几个解析器，
/// 而是在入口把 Tellomi 形状**换算成上游解析器认得的旧形状**（`legacyEquivalent`），旧解析器一行不动；
/// 唯一上游没有的新能力是 `tell.cc/u#u/<明文用户名>`（t.me 式，owner 要的形状；落地页把 `tell.cc/<username>` 改写成它），
/// 由 `plainUsername` 单独取出，App 自己拿用户名问服务端要 ACI（不经 CDSI）。
///
/// tell.cc 一个域名承载四种用途，**必须连路径一起判**：只看 host 会把 `tell.cc/u#p/…` 当群邀请去 Base64 解片段（Android #973 实测撞过）。
public enum TellomiLinks {
    public static let scheme = "tellomi"
    public static let legacyScheme = "sgnl"
    public static let captchaScheme = "tellomicaptcha"
    public static let legacyCaptchaScheme = "signalcaptcha"
    public static let host = "tell.cc"

    /// tell.cc 的路径命名空间（新增用途先在文档那张表登记）。`/i`（邀请下载）预留：只登记，不解析、不声明。
    public enum Path {
        public static let contact = "/u"     // `#p/<E164>` · `#eu/<加密用户名链接>` · `#u/<明文用户名>`
        public static let group = "/g"       // `#<invite>`
        public static let sticker = "/s"     // `#pack_id=…&pack_key=…`
        public static let call = "/call"     // `#key=…`
        public static let inviteReserved = "/i"
    }

    /// 是不是 Tellomi 自己的形状（`tellomi://…`、`tellomicaptcha://…`、`{https,tellomi}://tell.cc/…`）。
    public static func isTellomiUrl(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        if scheme == self.scheme || scheme == captchaScheme { return true }
        return scheme == "https" && url.host?.lowercased() == host
    }

    /// 把 Tellomi 形状换算成上游解析器认得的旧形状；不是 Tellomi 形状的原样返回。
    ///
    /// - `tellomi://X` → `sgnl://X`（linkdevice / joingroup / addstickers … 全部走这一条）
    /// - `{https,tellomi}://tell.cc/u#p/…|#eu/…` → `https://signal.me/#…`
    /// - `…/g#…` → `https://signal.group/#…`
    /// - `…/s#…` → `https://signal.art/addstickers/#…`
    /// - `…/call#…` → `https://signal.link/call/#…`
    /// - `tellomicaptcha://<token>` → `signalcaptcha://<token>`
    /// `tell.cc/u#u/<username>` 不在这里（上游没有等价形状），用 `plainUsername`。
    public static func legacyEquivalent(of url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        let scheme = components.scheme?.lowercased()

        if scheme == captchaScheme {
            components.scheme = legacyCaptchaScheme
            return components.url ?? url
        }

        let isTellCC = (scheme == self.scheme || scheme == "https") && components.host?.lowercased() == host
        if isTellCC {
            let path = components.path.hasSuffix("/") && components.path.count > 1 ? String(components.path.dropLast()) : components.path
            let fragment = components.percentEncodedFragment ?? ""
            let legacy: (host: String, path: String)?
            switch path {
            case Path.contact:
                // `#u/` 是新能力，不换算；`#p/` `#eu/` 换成 signal.me
                legacy = fragment.hasPrefix("u/") ? nil : ("signal.me", "/")
            case Path.group:
                legacy = ("signal.group", "/")
            case Path.sticker:
                legacy = ("signal.art", "/addstickers/")
            case Path.call:
                legacy = ("signal.link", "/call/")
            default:
                legacy = nil
            }
            guard let legacy else { return url }
            components.scheme = "https"
            components.host = legacy.host
            components.path = legacy.path
            return components.url ?? url
        }

        if scheme == self.scheme {
            components.scheme = legacyScheme
            return components.url ?? url
        }
        return url
    }

    /// 内部形状 `tell.cc/u#u/<username>`（落地页唤起 App 用）。
    private static let plainUsernamePattern = try! NSRegularExpression(
        pattern: "^(?:https|tellomi)://tell\\.cc/u/?#u/([a-zA-Z0-9_.]+)$",
        options: [.caseInsensitive],
    )
    /// 裸形状 `tell.cc/<username>`（owner 要的、用户会去分享的 t.me 式；与 Android 对齐）。第一段路径不能是命名空间里的保留字。
    private static let bareUsernamePattern = try! NSRegularExpression(
        pattern: "^(?:https|tellomi)://tell\\.cc/([a-zA-Z0-9_]+\\.[0-9]+)/?(?:[?#].*)?$",
        options: [.caseInsensitive],
    )

    /// `{https,tellomi}://tell.cc/u#u/<username>` 或 `{https,tellomi}://tell.cc/<username>` 里的明文用户名（如 `ceshi.57`），
    /// 不是这两种形状返回 nil。裸形状要求用户名带 `.<数字>` 判别位（Signal 用户名的固定形状），所以不会和 `/u` `/g` `/s` `/call` `/i` 撞。
    public static func plainUsername(in url: URL) -> String? {
        let s = url.absoluteString
        for pattern in [plainUsernamePattern, bareUsernamePattern] {
            if let m = pattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
               let r = Range(m.range(at: 1), in: s) {
                return String(s[r])
            }
        }
        return nil
    }

    /// captcha 回跳：新旧 scheme 都认（`CaptchaView` 用）。
    public static func isCaptchaCallback(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == captchaScheme || scheme == legacyCaptchaScheme
    }
}
