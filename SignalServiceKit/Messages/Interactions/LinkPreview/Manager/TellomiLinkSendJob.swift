//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// rust/links 的作业（`LinkJob`）里客户端要用到的那几个动作。抽出来是为了不依赖原生库也能测，和 Android `TellomiLinkSendJob.Job` 一样。
public protocol TellomiSendJob: AnyObject {
    func nextRequest() throws -> String?
    func onResponse(id: UInt32, status: UInt32, finalUrl: String, contentType: String, location: String?, body: Data) throws
    func onNetworkError(id: UInt32) throws
    func onFailure(id: UInt32) throws
    func onFirstParty(id: UInt32, result: String) throws
    func onImage(id: UInt32, ok: Bool) throws
    func finish() throws -> String
}

/// rust/links 提出的一个请求。`timeoutMs` 已经裁到这条链接剩下的预算以内。
public enum TellomiSendRequest: Equatable, Sendable {
    /// 只读第一个 `Location`，不跟随、不读正文。
    case expand(id: UInt32, url: String, timeoutMs: Int64)
    case fetch(
        id: UInt32,
        url: String,
        accept: String,
        contentTypes: [String],
        maxBytes: Int64,
        maxRedirects: Int,
        timeoutMs: Int64,
    )
    /// tell.cc 的对象（群、贴纸包、通话），用客户端自己现成的查法。
    case firstParty(id: UInt32, kind: String)
    case image(id: UInt32, url: String, maxRedirects: Int, timeoutMs: Int64)

    public var id: UInt32 {
        switch self {
        case .expand(let id, _, _), .fetch(let id, _, _, _, _, _, _), .firstParty(let id, _), .image(let id, _, _, _):
            return id
        }
    }
}

/// 一次抓取回报给 rust/links 的结果。
public enum TellomiSendExchange: Equatable, Sendable {
    case response(status: UInt32, finalUrl: String, contentType: String, location: String?, body: Data)
    /// DNS / TCP / TLS：和对方网站什么都没交换过。rust/links 会把这个 host 记成不可达。
    case networkError
    /// 其余的：连上以后超时、太大、被拒的一跳、取消……
    case failure
}

/// 客户端对 tell.cc 对象的查询结果。`invalid`：这个群邀请链接肯定没激活。
public struct TellomiSendFirstPartyResult: Codable, Equatable, Sendable {
    public var ok: Bool
    public var invalid: Bool?
    public var title: String?
    public var memberCount: Int?
    public var stickerCount: Int?

    public init(ok: Bool, invalid: Bool? = nil, title: String? = nil, memberCount: Int? = nil, stickerCount: Int? = nil) {
        self.ok = ok
        self.invalid = invalid
        self.title = title
        self.memberCount = memberCount
        self.stickerCount = stickerCount
    }

    private enum CodingKeys: String, CodingKey {
        case ok
        case invalid
        case title
        case memberCount = "member_count"
        case stickerCount = "sticker_count"
    }
}

public protocol TellomiSendDeps: AnyObject {
    func fetch(_ request: TellomiSendRequest) async -> TellomiSendExchange
    /// 抓预览图，并像 Signal 那样校验 / 重新编码；不能用就是 false。
    func image(_ request: TellomiSendRequest) async -> Bool
    func firstParty(kind: String) async -> TellomiSendFirstPartyResult
    func now() -> Date
    var isCancelled: Bool { get }
}

/// ADR-0063 §4.2 / §4.4 / §5.2，发送端：rust/links 决定抓什么，客户端抓、把结果喂回去，rust/links 拼出预览（快照 + `Preview.rich`）。
/// 这里驱动一条链接的作业：begin → 下一个请求 → 做 → 喂回 → …… → finish，每条链接 10 秒预算。
/// 与 Android `TellomiLinkSendJob.kt`、Desktop `linkSendJob.std.ts` 同一个循环；请求由 `TellomiLinkFetcher` 去做。
public enum TellomiLinkSendJob {

    public static let linkBudget: TimeInterval = 10

    public struct Outcome: Decodable, Equatable, Sendable {
        public var level: String
        public var provider: String?
        public var route: String?
        public var kind: String?
        public var preview: Preview?
        public var groupLinkInvalid: Bool
        public var lookalike: String?
        public var newlyUnreachableHosts: [String]
        public var failures: [String]

        private enum CodingKeys: String, CodingKey {
            case level
            case provider
            case route
            case kind
            case preview
            case lookalike
            case failures
            case groupLinkInvalid = "group_link_invalid"
            case newlyUnreachableHosts = "newly_unreachable_hosts"
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            level = try container.decode(String.self, forKey: .level)
            provider = try container.decodeIfPresent(String.self, forKey: .provider)
            route = try container.decodeIfPresent(String.self, forKey: .route)
            kind = try container.decodeIfPresent(String.self, forKey: .kind)
            preview = try container.decodeIfPresent(Preview.self, forKey: .preview)
            groupLinkInvalid = try container.decodeIfPresent(Bool.self, forKey: .groupLinkInvalid) ?? false
            lookalike = try container.decodeIfPresent(String.self, forKey: .lookalike)
            newlyUnreachableHosts = try container.decodeIfPresent([String].self, forKey: .newlyUnreachableHosts) ?? []
            failures = try container.decodeIfPresent([String].self, forKey: .failures) ?? []
        }
    }

    public struct Preview: Decodable, Equatable, Sendable {
        public var url: String
        public var title: String?
        public var description: String?
        public var imageUrl: String?
        /// 毫秒时间戳。
        public var date: Int64?
        public var richHex: String?

        private enum CodingKeys: String, CodingKey {
            case url
            case title
            case description
            case date
            case imageUrl = "image_url"
            case richHex = "rich_hex"
        }
    }

    // MARK: - 编码 / 解码

    /// 交给 `begin` 的上下文：区域先验、本机记着不可达的 host、要不要展开短链、界面语言。
    public static func contextJson(unreachableHosts: [String], expandShortLinks: Bool, locale: Locale) -> String {
        let object: [String: Any] = [
            "region": "global",
            "unreachable_hosts": unreachableHosts,
            "expand_short_links": expandShortLinks,
            "locale": languageTag(for: locale),
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// `zh_Hans_CN@calendar=chinese` → `zh-Hans-CN`（BCP 47；`identifier(.bcp47)` 要 iOS 16）。
    static func languageTag(for locale: Locale) -> String {
        let base = locale.identifier.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? locale.identifier
        return base.replacingOccurrences(of: "_", with: "-")
    }

    public static func parseOutcome(_ json: String) -> Outcome? {
        return try? JSONDecoder().decode(Outcome.self, from: Data(json.utf8))
    }

    /// rust/links 写的一个请求；本版不认识的返回 nil（这条链接就不出预览，不猜）。
    public static func parseRequest(_ json: String, remainingMs: Int64) -> TellomiSendRequest? {
        guard
            let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
            let id = (object["id"] as? NSNumber)?.uint32Value,
            let type = object["type"] as? String
        else {
            return nil
        }
        func string(_ key: String) -> String? { object[key] as? String }
        func int64(_ key: String) -> Int64? { (object[key] as? NSNumber)?.int64Value }
        func timeout() -> Int64? { int64("timeout_ms").map { min($0, remainingMs) } }

        switch type {
        case "expand_short_link":
            guard let url = string("url"), let timeout = timeout() else { return nil }
            return .expand(id: id, url: url, timeoutMs: timeout)
        case "fetch":
            guard
                let url = string("url"),
                let accept = string("accept"),
                let contentTypes = object["content_types"] as? [String],
                let maxBytes = int64("max_bytes"),
                let maxRedirects = int64("max_redirects"),
                let timeout = timeout()
            else {
                return nil
            }
            return .fetch(
                id: id,
                url: url,
                accept: accept,
                contentTypes: contentTypes.map { $0.lowercased() },
                maxBytes: maxBytes,
                maxRedirects: Int(maxRedirects),
                timeoutMs: timeout,
            )
        case "first_party":
            guard let kind = string("kind") else { return nil }
            return .firstParty(id: id, kind: kind)
        case "image":
            guard let url = string("url"), let maxRedirects = int64("max_redirects"), let timeout = timeout() else { return nil }
            return .image(id: id, url: url, maxRedirects: Int(maxRedirects), timeoutMs: timeout)
        default:
            return nil
        }
    }

    // MARK: - 循环

    /// 把作业跑到底。nil：取消了，或 rust/links 要了本版不懂的东西（那就没有预览，不猜）。
    /// `onRequest` 看得到每个请求的原文（测试用）。
    public static func run(
        job: any TellomiSendJob,
        deps: any TellomiSendDeps,
        onRequest: ((String) -> Void)? = nil,
    ) async throws -> Outcome? {
        let deadline = deps.now().addingTimeInterval(linkBudget)

        while true {
            if deps.isCancelled {
                return nil
            }
            let remaining = deadline.timeIntervalSince(deps.now())
            if remaining <= 0 {
                break // 预算用完：就用已经知道的（§5.2）。
            }
            guard let json = try job.nextRequest() else {
                break
            }
            onRequest?(json)

            guard let request = parseRequest(json, remainingMs: Int64(remaining * 1000)) else {
                return nil
            }
            switch request {
            case .expand(let id, _, _), .fetch(let id, _, _, _, _, _, _):
                try feed(job: job, id: id, exchange: await deps.fetch(request))
            case .firstParty(let id, let kind):
                let result = await deps.firstParty(kind: kind)
                let data = (try? JSONEncoder().encode(result)) ?? Data("{\"ok\":false}".utf8)
                try job.onFirstParty(id: id, result: String(decoding: data, as: UTF8.self))
            case .image(let id, _, _, _):
                try job.onImage(id: id, ok: await deps.image(request))
            }
        }

        if deps.isCancelled {
            return nil
        }
        return parseOutcome(try job.finish())
    }

    private static func feed(job: any TellomiSendJob, id: UInt32, exchange: TellomiSendExchange) throws {
        switch exchange {
        case .response(let status, let finalUrl, let contentType, let location, let body):
            try job.onResponse(id: id, status: status, finalUrl: finalUrl, contentType: contentType, location: location, body: body)
        case .networkError:
            try job.onNetworkError(id: id)
        case .failure:
            try job.onFailure(id: id)
        }
    }
}
