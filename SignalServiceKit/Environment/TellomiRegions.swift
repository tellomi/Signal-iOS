//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Tellomi：区域 id（RegionProfile 契约 v2 第二节，超级仓库 `docs/signal/REGION_PROFILE.md`；tellomi/tellomi#1056）。
/// 和 Desktop、Android、ADR-0062 / ADR-0064、policy 引擎的 `Region::{Global, Cn}` 是同一套取值。
public enum TellomiRegionId: String, CaseIterable {
    case global
    case cn
}

/// 一个区域 = 一组端点 + 一个 `enabled` 位（契约第一、三节）。
/// 客户端连的每一个服务端地址都属于且只属于一个区域；各字段对应契约第三节表里的一行。
/// URL 字段带 scheme；名字以 `Host` 结尾的只写主机名。
///
/// 不进区域的：`svr2` / `cdsi`（没有自建，见 `ENCLAVES.md`）、zk 参数、UD 信任根、CA——两个区连的是同一套服务端。
/// 契约第三节的 staticIps 只有 Android 有；iOS 没有静态 IP 回落。
public struct TellomiRegionProfile: Equatable {
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

/// 编进包里的区域表。
///
/// 这一刀只把表立起来、把不变量钉成测试，行为不变：global 档就是今天的常量（逐字节一致），
/// `TSConstantsStaging` 和原来写死在使用处的三个地址（内容代理、uptime、调试日志）都改成从这里取；
/// CN 档按契约第四节生成、`enabled = false`。
/// 当前区、切区（重建 `Net`、`TSConstants.shared` 按区取）在 #1056 的后面几刀。
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

    public static let all: [TellomiRegionProfile] = [global, cn]

    /// 契约第四节：同名标签挂到 `tellomi.cn`。scheme、端口、路径都不变，只把主机名里的 `.tellomi.app` 换成 `.tellomi.cn`。
    /// 这样 CN 档的每一个主机都在 `tellomi.cn` 下（App 备案要填运行时连接的全部域名，漏一条就是漏报）。
    static func cnOf(_ global: TellomiRegionProfile) -> TellomiRegionProfile {
        TellomiRegionProfile(
            id: .cn,
            enabled: false,
            chat: toCnHost(global.chat),
            grpcChatHost: toCnHost(global.grpcChatHost),
            storage: toCnHost(global.storage),
            cdn0: toCnHost(global.cdn0),
            cdn2: toCnHost(global.cdn2),
            cdn3: toCnHost(global.cdn3),
            updates: toCnHost(global.updates),
            contentProxyHost: toCnHost(global.contentProxyHost),
            contentProxyPort: global.contentProxyPort,
            captchaRegistration: toCnHost(global.captchaRegistration),
            captchaChallenge: toCnHost(global.captchaChallenge),
            sfu: toCnHost(global.sfu),
            uptimeHost: toCnHost(global.uptimeHost),
            debugLog: toCnHost(global.debugLog),
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
    static func toCnHost(_ urlOrHost: String) -> String {
        let host = hostOf(urlOrHost)
        guard host.hasSuffix(globalDomain), let range = urlOrHost.range(of: host) else {
            return urlOrHost
        }
        let cnHost = String(host.dropLast(globalDomain.count)) + cnDomain
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
}
