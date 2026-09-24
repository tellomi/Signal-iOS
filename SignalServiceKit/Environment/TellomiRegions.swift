//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Tellomi：区域 id（RegionProfile 契约 v2 第二节，超级仓库 `docs/signal/REGION_PROFILE.md`；tellomi/tellomi#1056）。
/// 和 Desktop、Android、ADR-0062 / ADR-0064、policy 引擎的 `Region::{Global, Cn}` 是同一套取值。
public enum TellomiRegionId: String, CaseIterable, Sendable {
    case global
    case cn
}

/// 一个区域 = 一组端点 + 一个 `enabled` 位（契约第一、三节）。
/// 客户端连的每一个服务端地址都属于且只属于一个区域；各字段对应契约第三节表里的一行。
/// URL 字段带 scheme；名字以 `Host` 结尾的只写主机名。
///
/// 不进区域的：`svr2` / `cdsi`（没有自建，见 `ENCLAVES.md`）、zk 参数、UD 信任根、CA——两个区连的是同一套服务端。
/// 契约第三节的 staticIps 只有 Android 有；iOS 没有静态 IP 回落。
public struct TellomiRegionProfile: Equatable, Sendable {
    public let id: TellomiRegionId
    public let enabled: Bool
    /// REST + WebSocket（`TSConstants.mainServiceURL`）。captcha 页、`/callingService`、`/debuglogs` 也挂在这台主机上。
    public let chat: String
    /// libsignal `Net` 的 custom server（`TSConstants.customServerChatHostname`），只写主机名。
    public let grpcChatHost: String
    public let storage: String
    /// 头像 / 群头像 / 贴纸。
    public let cdn0: String
    /// 遗留；客户端配置校验要求它存在。
    public let cdn2: String
    /// 附件；每个区恰好一个（契约第五节第 3 条）。iOS 这里本来就只有一个字符串。
    public let cdn3: String
    /// 动态资源、自动更新（`updatesURL` / `updates2URL` 同值）。
    public let updates: String
    /// GIF 内容代理（`ContentProxy.defaultEndpoint`，服务端下发的地址优先）。
    public let contentProxyHost: String
    public let contentProxyPort: Int
    public let captchaRegistration: String
    public let captchaChallenge: String
    /// 群通话会合点（`sfuURL`，`sfuTestURL` 同值）。两个区的入口可以不同，会合点只能有一个（契约第五节第 6 条）。
    public let sfu: String
    /// 只做 DNS 解析，不连接（#1101，`OutageDetection`）。
    public let uptimeHost: String
    /// 调试日志上传（#931，`DebugLogUploader`）。
    public let debugLog: String

    /// 这个区所有的端点（URL 或主机名），校验和测试用。
    public var endpoints: [String] {
        [
            chat,
            grpcChatHost,
            storage,
            cdn0,
            cdn2,
            cdn3,
            updates,
            contentProxyHost,
            captchaRegistration,
            captchaChallenge,
            sfu,
            uptimeHost,
            debugLog,
        ]
    }
}

/// 编进包里的区域表，和当前区。
///
/// global 档就是今天的常量（逐字节一致），CN 档按契约第四节生成、`enabled = false`。
/// 各调用点在**用的时候**取 `current()`（`TSConstantsStaging` 的端点、内容代理 / uptime / 调试日志），
/// 不在启动时存下来，这样以后切区（#1056 第三刀：重建 `Net`）之后新建的连接就用新区，不会「半切换」。
/// 现在 CN 关着，所以当前区恒为 global，行为不变。
public enum TellomiRegions {
    static let globalDomain = ".tellomi.app"
    static let cnDomain = ".tellomi.cn"

    /// global 档 = 今天的常量（契约第五节第 1 条）。
    public static let global = TellomiRegionProfile(
        id: .global,
        enabled: true,
        chat: "https://chat.tellomi.app",
        grpcChatHost: "grpc.chat.tellomi.app",
        storage: "https://storage.tellomi.app",
        cdn0: "https://cdn.tellomi.app",
        cdn2: "https://cdn2.tellomi.app",
        cdn3: "https://cdn3.tellomi.app",
        updates: "https://updates.tellomi.app",
        contentProxyHost: "contentproxy.tellomi.app",
        contentProxyPort: 443,
        captchaRegistration: "https://chat.tellomi.app/captcha-tellomi/registration/generate.html",
        captchaChallenge: "https://chat.tellomi.app/captcha-tellomi/challenge/generate.html",
        sfu: "https://chat.tellomi.app/callingService",
        uptimeHost: "uptime.tellomi.app",
        debugLog: "https://chat.tellomi.app/debuglogs",
    )

    /// CN 档：`enabled = false`，直到备案完成（契约第五节第 2 条）。
    public static let cn = cnOf(global)

    /// 包内区域表。首次访问时核一遍：坏了是构建缺陷，拒绝启动（契约第五节第 8 条，和 Desktop 启动时抛同一语义）。
    public static let all: [TellomiRegionProfile] = {
        let all = [global, cn]
        let broken = problems(all)
        guard broken.isEmpty else {
            owsFail("packaged region table is broken: \(broken)")
        }
        return all
    }()

    /// 本进程用的区域表：provider 的 `profiles` 和 `current()` 都按它。一般就是 `all`；
    /// 测试构建里带 `TELLOMI_TEST_REGION_DOMAIN` 启动时，CN 档换成一个开着的测试区（`testRegionProfiles`）。
    public static let processProfiles: [TellomiRegionProfile] = {
#if TESTABLE_BUILD
        return testRegionProfiles(environment: ProcessInfo.processInfo.environment)
#else
        return all
#endif
    }()

    /// 当前区（契约第六节 `currentRegion()`）。记在 app group 的 UserDefaults 里，主 App 和 NSE 读同一份。
    /// 没有记录、不认识、那个区关着、读不出来，一律回落 global，绝不抛（契约第五节第 8 条）。
    public static func current(store: TellomiRegionStore = .appGroup) -> TellomiRegionProfile {
        resolve(storedId: store.storedRegionId(), profiles: processProfiles)
    }

    /// 本进程生效的区（#1056 第三刀）：provider 装上以后以它为准——它和 libsignal `Net` 在同一个原子状态里，
    /// REST（`TSConstants`）和 libsignal 两侧在进程内同时切；装上之前（`AppSetup` 建 `Net` 时、启动失败页）回落记住的区。
    public static func active() -> TellomiRegionProfile {
        TellomiNetProvider.installed?.activeRegion ?? current()
    }

    /// 本进程认识的区：装上的 provider 带的表；没装上时是本进程的表。
    public static func known() -> [TellomiRegionProfile] {
        TellomiNetProvider.installed?.profiles ?? processProfiles
    }

    /// 记住的区 id → 区。回落规则是纯函数，单测直接测它。
    static func resolve(storedId: String?, profiles: [TellomiRegionProfile] = all) -> TellomiRegionProfile {
        profiles.first { $0.id.rawValue == storedId && $0.enabled } ?? global
    }

    /// 契约第四节：同名标签挂到 `tellomi.cn`。scheme、端口、路径都不变，只把主机名里的 `.tellomi.app` 换成 `.tellomi.cn`。
    /// 这样 CN 档的每一个主机都在 `tellomi.cn` 下（App 备案要填运行时连接的全部域名，漏一条就是漏报）。
    /// `domain` / `enabled` 只有测试区会改（`testRegionProfiles`）。
    static func cnOf(_ global: TellomiRegionProfile, domain: String = cnDomain, enabled: Bool = false) -> TellomiRegionProfile {
        let rehost = { toCnHost($0, domain: domain) }
        return TellomiRegionProfile(
            id: .cn,
            enabled: enabled,
            chat: rehost(global.chat),
            grpcChatHost: rehost(global.grpcChatHost),
            storage: rehost(global.storage),
            cdn0: rehost(global.cdn0),
            cdn2: rehost(global.cdn2),
            cdn3: rehost(global.cdn3),
            updates: rehost(global.updates),
            contentProxyHost: rehost(global.contentProxyHost),
            contentProxyPort: global.contentProxyPort,
            captchaRegistration: rehost(global.captchaRegistration),
            captchaChallenge: rehost(global.captchaChallenge),
            sfu: rehost(global.sfu),
            uptimeHost: rehost(global.uptimeHost),
            debugLog: rehost(global.debugLog),
        )
    }

    /// URL 或主机名 → 主机名（去掉 scheme、端口、路径）。
    static func hostOf(_ urlOrHost: String) -> String {
        var rest = Substring(urlOrHost)
        if let schemeEnd = rest.range(of: "://") {
            rest = rest[schemeEnd.upperBound...]
        }
        if let end = rest.firstIndex(where: { "/:?#".contains($0) }) {
            rest = rest[..<end]
        }
        return String(rest)
    }

    /// 只换主机部分；主机不在 `tellomi.app` 下的原样返回，由 `problems` 挑出来。
    static func toCnHost(_ urlOrHost: String, domain: String = cnDomain) -> String {
        let host = hostOf(urlOrHost)
        guard host.hasSuffix(globalDomain), let range = urlOrHost.range(of: host) else {
            return urlOrHost
        }
        let cnHost = String(host.dropLast(globalDomain.count)) + domain
        return urlOrHost.replacingCharacters(in: range, with: cnHost)
    }

    /// 包内区域表的不变量（契约第四节，第五节第 2、4 条）。空数组 = 合法。
    /// 表是编进包里的，不合法是构建缺陷，由单测把关。
    static func problems(_ profiles: [TellomiRegionProfile]) -> [String] {
        var problems = [String]()

        let ids = profiles.map(\.id)
        if Set(ids).count != ids.count {
            problems.append("duplicate region ids: \(ids.map(\.rawValue))")
        }

        if let global = profiles.first(where: { $0.id == .global }) {
            if !global.enabled {
                problems.append("the global region must be enabled")
            }
        } else {
            problems.append("missing the global region")
        }

        if let cn = profiles.first(where: { $0.id == .cn }) {
            if cn.enabled {
                problems.append("the cn region must stay disabled until the ICP filing is done")
            }
            for endpoint in cn.endpoints where !hostOf(endpoint).hasSuffix(cnDomain) {
                problems.append("cn endpoint outside tellomi.cn: \(endpoint)")
            }
        }

        return problems
    }

#if TESTABLE_BUILD

    // MARK: - 测试区（只在测试构建里；#1056 第三刀提交 E）

    /// 启动环境变量，值是一个域名，例如 `tellomi.test`。
    static let testRegionDomainKey = "TELLOMI_TEST_REGION_DOMAIN"

    /// 带 `TELLOMI_TEST_REGION_DOMAIN` 启动时，CN 档换成一个**开着的**测试区：同名标签挂到那个域下
    /// （`chat.<域>`、`grpc.chat.<域>`、`cdn3.<域>`…，路径和端口不变）。用来在 CN 保持关闭、`tellomi.cn` 下
    /// 没有任何 DNS 记录的前提下验切区（#1056 判据 1、2）。
    ///
    /// 只换本进程的表，不改 `all`，所以 `problems(all)` 和第二刀的门禁照旧。NSE、分享扩展由系统启动，
    /// 没有这个变量：store 里记的 `cn` 在那边按规则回落 global。值不像域名就当没设。
    static func testRegionProfiles(environment: [String: String]) -> [TellomiRegionProfile] {
        guard let domain = environment[testRegionDomainKey], isPlausibleTestDomain(domain) else {
            return all
        }
        let testRegion = cnOf(global, domain: "." + domain, enabled: true)
        return all.map { $0.id == .cn ? testRegion : $0 }
    }

    private static func isPlausibleTestDomain(_ domain: String) -> Bool {
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy { label in
            !label.isEmpty && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }
#endif
}

/// 当前区记在哪（契约第六节）。
///
/// 存两样：记住的区 id，和上一次切区的时间（「驻留时间从哪算起」要持久化，没有记录 = 视为已满足）。
/// 放 app group 的 UserDefaults：NSE 是独立进程，要读同一份（契约第六节 iOS 那条）。
/// 写入（`record`）由第三刀的切区调用；这一刀只读。
public struct TellomiRegionStore {
    static let regionIdKey = "TellomiRegion.currentId"
    static let lastSwitchAtKey = "TellomiRegion.lastSwitchAt"

    private let userDefaults: () -> UserDefaults?

    public init(userDefaults: @escaping () -> UserDefaults?) {
        self.userDefaults = userDefaults
    }

    /// 主 App 与 NSE 共用的那一份（和 `MainAppContext` / `NSEContext` 的 `appUserDefaults()` 同一个 suite）。
    public static let appGroup = TellomiRegionStore(userDefaults: { UserDefaults(suiteName: TSConstants.applicationGroup) })

    public func storedRegionId() -> String? {
        userDefaults()?.string(forKey: Self.regionIdKey)
    }

    /// nil = 没有记录。
    public func lastSwitchAt() -> Date? {
        userDefaults()?.object(forKey: Self.lastSwitchAtKey) as? Date
    }

    public func record(_ id: TellomiRegionId, at date: Date) {
        guard let userDefaults = userDefaults() else {
            return
        }
        userDefaults.set(id.rawValue, forKey: Self.regionIdKey)
        userDefaults.set(date, forKey: Self.lastSwitchAtKey)
    }
}
