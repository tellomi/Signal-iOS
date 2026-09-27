//
// Copyright 2026 重庆半格智能科技有限公司
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
        // ADR-0063 §4.8 / ADR-0066 §五：预留给以后的对象，今天不是对象（不抓取、不出卡片）
        public static let messageReserved = "/m"
        public static let eventReserved = "/e"
        public static let reservedA = "/a"
        public static let appReserved = "/app"
        public static let reservedB = "/b"
    }

    /// tell.cc 的一级路径与预留路径（ADR-0063 §4.8、ADR-0066 §五：都进了用户名保留词）。
    /// 与超级仓库 `docs/adr/0063/registry/providers/first-party/tellomi.toml` 的 `reserved_paths`、Android `TellomiLinks.kt`
    /// 的 `RESERVED_FIRST_LEVEL_PATHS`、落地页、policy `reserved-system.toml` 是同一张表（L19 一致性测试对照这五处）。
    /// 保留路径表只增不减（§7.5）。
    public static let reservedFirstLevelPaths: [String] = ["u", "g", "s", "call", "i", "m", "e", "a", "app", "b"]

    /// tell.cc 链接按 ADR-0063 §4.8 的匹配顺序认出来的形状。
    public enum FirstPartyShape: Equatable, Sendable {
        /// `/<nickname>` · `/<nickname>.<数字>` · `/u#u/<username>`；值是协议层的完整用户名（裸 nickname 补 `.01`）
        case user(username: String)
        /// `/u#eu/<加密用户名链接>`
        case userEncryptedLink
        /// `/u#p/<E.164>`
        case userPhoneNumber
        /// `/g#<invite>`
        case group
        /// `/call#key=…`
        case call
        /// `/s#pack_id=…&pack_key=…`
        case stickerPack
        /// 预留的一级路径（`/i` `/m` `/e` `/a` `/app` `/b`）：以后的对象，今天不是
        case reservedPath(String)
        /// 两条都不是（根路径、`/.well-known/`、多段路径、一级路径带了不认识的片段、不合用户名语法）：
        /// **不是 Tellomi 对象，不抓取、不出卡片**——tell.cc 不放网页，抓回来只会是落地页自己的 OG（§4.8 第 3 条）
        case notAnObject
    }

    /// `https://tell.cc/…`（或 `tellomi://tell.cc/…`）的形状；不是 tell.cc 返回 nil。
    ///
    /// 匹配顺序（ADR-0063 §4.8，ADR-0066 之后）：① 一级路径优先，`/.well-known/` 不是对象；② 其余单段路径按用户名；③ 都不是 → `.notAnObject`。
    public static func firstPartyShape(of url: URL) -> FirstPartyShape? {
        let scheme = url.scheme?.lowercased()
        guard scheme == "https" || scheme == self.scheme, url.host?.lowercased() == host else {
            return nil
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .notAnObject
        }
        var path = components.percentEncodedPath
        if path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        let fragment = components.percentEncodedFragment ?? ""
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard segments.count == 1, let firstSegment = segments.first.map(String.init), !firstSegment.isEmpty else {
            // 根路径、多段路径（含 `/.well-known/…`）
            return .notAnObject
        }

        switch "/" + firstSegment {
        case Path.contact:
            if fragment.hasPrefix("u/") {
                return plainUsername(in: url).map { .user(username: $0) } ?? .notAnObject
            }
            if fragment.hasPrefix("eu/"), fragment.count > 3 {
                return .userEncryptedLink
            }
            if fragment.hasPrefix("p/"), fragment.count > 2 {
                return .userPhoneNumber
            }
            return .notAnObject
        case Path.group:
            return fragment.isEmpty ? .notAnObject : .group
        case Path.call:
            return fragment.hasPrefix("key=") ? .call : .notAnObject
        case Path.sticker:
            return fragment.contains("pack_id=") && fragment.contains("pack_key=") ? .stickerPack : .notAnObject
        default:
            break
        }
        // 一级路径大小写不敏感地挡在用户名前面（`tell.cc/CALL` 不是用户名）
        if reservedFirstLevelPaths.contains(firstSegment.lowercased()) {
            return .reservedPath(firstSegment.lowercased())
        }
        if let username = plainUsername(in: url) {
            return .user(username: username)
        }
        return .notAnObject
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
    /// 用户名是带后缀的旧形状，或 3–32 位、首字符为字母 / 下划线的裸 nickname（tellomi/tellomi#1106，ADR-0066）。
    private static let bareUsernamePattern = try! NSRegularExpression(
        pattern: "^(?:https|tellomi)://tell\\.cc/([a-zA-Z0-9_]+\\.[0-9]+|[a-zA-Z_][a-zA-Z0-9_]{2,31})/?(?:[?#].*)?$",
        options: [.caseInsensitive],
    )

    /// ADR-0066：Tellomi 新建用户名时判别位固定为 `01`，界面只露 nickname。
    public static let fixedUsernameDiscriminator = "01"

    /// 用户输入 / 链接里的名字 → 协议层的完整用户名（与 Android `TellomiUsernames.toProtocolUsername` 同一套规则）：
    /// 去掉首尾空白和前导 `@`；**没有 `.` 就补 `.01`**（`kaixin` → `kaixin.01`）；已带后缀的原样保留（`kaixin.57` 这类旧账号按全名找）。
    /// 不做合法性校验：不合法的交给 `Usernames.HashedUsername` / 服务端去拒。
    public static func protocolUsername(_ input: String) -> String {
        var trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("@") {
            trimmed.removeFirst()
        }
        return trimmed.contains(".") ? trimmed : "\(trimmed).\(fixedUsernameDiscriminator)"
    }

    /// 协议层的完整用户名 → 界面上显示的样子（与 Android `TellomiUsernames.toDisplayUsername` 同一套规则，ADR-0066 §六「显示」）：
    /// **只有 `.01` 结尾的去掉后缀**（`kaixin.01` → `kaixin`）；别的后缀**完整显示**（`kaixin.57` 原样）——
    /// §九的反向用例：别人用 `kaixin.57` 注册，官方客户端必须显示 `kaixin.57`，不能显示成 `kaixin`，否则就是冒充。
    /// **一律显示小写**（§6.1b，owner 2026-09-27）：老数据里的大写（`KaiXin.01`）只在显示时转，不迁移——唯一性本来就不分大小写。
    /// 只用在给人看的字符串上；存储、查找、链接、hash 仍用完整用户名。
    public static func displayUsername(_ username: String) -> String {
        let suffix = ".\(fixedUsernameDiscriminator)"
        guard username.hasSuffix(suffix) else {
            return lowercasedUsername(username)
        }
        return lowercasedUsername(String(username.dropLast(suffix.count)))
    }

    /// ADR-0066 §6.1b（owner 2026-09-27）：用户名一律小写。**只转 ASCII 的 A–Z**：用户名只认 `a-z 0-9 _`，
    /// `İ`、全角 `Ａ` 这类转了也不合规，原样留给校验去报（不能让 `İ` 变成 `i̇` 混过去）。长度（UTF-16 / 标量）不变。
    public static func lowercasedUsername(_ username: String) -> String {
        guard containsUppercaseAsciiLetter(username) else {
            return username
        }
        var scalars = String.UnicodeScalarView()
        for scalar in username.unicodeScalars {
            if isUppercaseAsciiLetter(scalar), let lowercased = Unicode.Scalar(scalar.value + 0x20) {
                scalars.append(lowercased)
            } else {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    public static func containsUppercaseAsciiLetter(_ string: String) -> Bool {
        return string.unicodeScalars.contains(where: isUppercaseAsciiLetter)
    }

    private static func isUppercaseAsciiLetter(_ scalar: Unicode.Scalar) -> Bool {
        return ("A"..."Z").contains(scalar)
    }

    /// ADR-0066 §6.2：换用户名之后 30 天内不能再换（服务端 `USERNAME_CHANGE_COOLDOWN`，tellomi/Signal-Server#4；首次设置不计）。
    /// 只用在改名前的提醒；还剩多久永远以服务端 429 的 `Retry-After` 为准。
    public static let renameCooldownDays = 30

    /// reserve 回 429 时分辨「改名冷却」和普通限流：限流桶（`usernameReserve`，100 次 / 15 分钟）的 `Retry-After` 是秒级，
    /// 冷却的是天级，**超过一小时就是冷却**。与 Desktop `isRenameCooldown`、Android `TellomiUsernames.isRenameCooldown` 同一条线。
    public static func isRenameCooldown(retryAfter: TimeInterval) -> Bool {
        return retryAfter > 3600
    }

    /// 冷却还剩几天：向上取整、至少 1（刚改完的 `Retry-After` 2591999 秒是 30 天，还剩两小时是 1 天）。三端同一算法。
    public static func renameCooldownDaysLeft(retryAfter: TimeInterval) -> Int {
        return max(1, Int((retryAfter / 86400).rounded(.up)))
    }

    /// `{https,tellomi}://tell.cc/u#u/<username>` 或 `{https,tellomi}://tell.cc/<username>` 里的用户名，不是这两种形状返回 nil。
    ///
    /// **返回的总是协议层的完整用户名**（tellomi/tellomi#1106）：裸 nickname 补 `.01`（`tell.cc/kaixin` → `kaixin.01`），
    /// 已带后缀的原样（`ceshi.57`），调用方可以直接拿去查。原来靠「必须带 `.<数字>`」挡保留路径，放开裸 nickname 之后改成：
    /// 1–2 位的 `/u` `/g` `/s` `/i` … 被长度规则挡住；3 位以上的 `call`、`app` 显式排除（大小写不敏感）。
    public static func plainUsername(in url: URL) -> String? {
        let s = url.absoluteString
        for pattern in [plainUsernamePattern, bareUsernamePattern] {
            if let m = pattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
               let r = Range(m.range(at: 1), in: s) {
                let raw = String(s[r])
                // 1–2 位的一级路径已被长度规则挡住；3 位以上的（`call`、`app`）在这里显式排除
                if !raw.contains("."), reservedFirstLevelPaths.contains(raw.lowercased()) {
                    return nil
                }
                return protocolUsername(raw)
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
