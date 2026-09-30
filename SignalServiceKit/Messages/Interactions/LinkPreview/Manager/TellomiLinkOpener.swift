//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// rust/links 的 `open_plan`（ADR-0063 §4.9、§5.5、§6.1）：点卡片和点正文里的链接怎么打开。
/// 目标永远是消息里那条 URL（不是 `canonical_url`），计划只说怎么交出去、按什么顺序试。
/// 与 Android `TellomiLinkOpener.kt`、Desktop `linkOpen.main.ts` 同一套。
public struct TellomiOpenPlan: Equatable, Sendable {

    public struct Step: Equatable, Sendable {
        /// `in_app`（Tellomi 自己的路由）、`installed_app_only`（只交给已装的 App）、`scheme`（注册表里的 App scheme）、
        /// `browser`（显式浏览器）、`copy_link`（都不行时复制并提示）。
        public var type: String
        public var url: String

        public init(type: String, url: String) {
            self.type = type
            self.url = url
        }
    }

    /// 空：什么都不打开（不是 http(s)：`intent:`、`javascript:`、`data:`、`file:` 永远不是目标）。
    public var steps: [Step]
    /// 域名冒充这个知名域名：打开前先问一次（§6.1）。
    public var lookalike: String?

    public init(steps: [Step], lookalike: String? = nil) {
        self.steps = steps
        self.lookalike = lookalike
    }

    private struct Wire: Decodable {
        struct WireStep: Decodable {
            let type: String
            let url: String
        }

        let steps: [WireStep]
        let lookalike: String?
    }

    public static func parse(_ json: String) -> TellomiOpenPlan? {
        guard
            let data = json.data(using: .utf8),
            let wire = try? JSONDecoder().decode(Wire.self, from: data)
        else {
            return nil
        }
        return TellomiOpenPlan(steps: wire.steps.map { Step(type: $0.type, url: $0.url) }, lookalike: wire.lookalike)
    }
}

/// 每一步怎么试；接住了返回 true。都在主线程：要碰 UIApplication、显示浏览器、弹提示。
@MainActor
public protocol TellomiLinkLauncher {
    func inApp(_ url: URL) async -> Bool
    func installedAppOnly(_ url: URL) async -> Bool
    func scheme(_ url: URL) async -> Bool
    func browser(_ url: URL) async -> Bool
    func copyLink(_ url: URL) async -> Bool
}

public enum TellomiLinkOpener {

    public enum Decision: Equatable {
        /// 没有注册表（没装上、解不开）或它出错了：照 Signal 原样打开。
        case signalDefault
        /// 计划是空的：什么都不打开。
        case openNothing
        case open(TellomiOpenPlan)
        /// 域名冒充知名域名：先问一次，可以继续打开。
        case confirmThenOpen(TellomiOpenPlan, lookalike: String)
    }

    public static func decide(url: String, classifier: TellomiLinkClassifier) -> Decision {
        guard let plan = classifier.openPlan(forUrl: url) else {
            return .signalDefault
        }
        if plan.steps.isEmpty {
            return .openNothing
        }
        if let lookalike = plan.lookalike {
            return .confirmThenOpen(plan, lookalike: lookalike)
        }
        return .open(plan)
    }

    /// 按顺序试，返回接住链接的那一步的类型；都没接住是 nil。认不出的步骤和打不开的 URL 不交给 launcher。
    @MainActor
    public static func run(steps: [TellomiOpenPlan.Step], launcher: any TellomiLinkLauncher) async -> String? {
        for step in steps {
            guard let url = URL(string: step.url), !step.url.isEmpty else {
                continue
            }
            let took: Bool
            switch step.type {
            case "in_app": took = await launcher.inApp(url)
            case "installed_app_only": took = await launcher.installedAppOnly(url)
            case "scheme": took = await launcher.scheme(url)
            case "browser": took = await launcher.browser(url)
            case "copy_link": took = await launcher.copyLink(url)
            default: took = false
            }
            if took {
                return step.type
            }
        }
        return nil
    }
}
