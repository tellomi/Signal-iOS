//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest
@testable import SignalServiceKit

/// tellomi/tellomi#1056：区域表与 RegionProfile 契约 v2（超级仓库 docs/signal/REGION_PROFILE.md）的不变量。
class TellomiRegionsTest: XCTestCase {
    private let global = TellomiRegions.global
    private let cn = TellomiRegions.cn

    func testGlobalRegionIsExactlyTheContractTable() {
        XCTAssertEqual(global.id, .global)
        XCTAssertTrue(global.enabled)
        XCTAssertEqual(global.chat, "https://chat.tellomi.app")
        XCTAssertEqual(global.grpcChatHost, "grpc.chat.tellomi.app")
        XCTAssertEqual(global.storage, "https://storage.tellomi.app")
        XCTAssertEqual(global.cdn0, "https://cdn.tellomi.app")
        XCTAssertEqual(global.cdn2, "https://cdn2.tellomi.app")
        XCTAssertEqual(global.cdn3, "https://cdn3.tellomi.app")
        XCTAssertEqual(global.updates, "https://updates.tellomi.app")
        XCTAssertEqual(global.contentProxyHost, "contentproxy.tellomi.app")
        XCTAssertEqual(global.contentProxyPort, 443)
        XCTAssertEqual(global.captchaRegistration, "https://chat.tellomi.app/captcha-tellomi/registration/generate.html")
        XCTAssertEqual(global.captchaChallenge, "https://chat.tellomi.app/captcha-tellomi/challenge/generate.html")
        XCTAssertEqual(global.sfu, "https://chat.tellomi.app/callingService")
        XCTAssertEqual(global.uptimeHost, "uptime.tellomi.app")
        XCTAssertEqual(global.debugLog, "https://chat.tellomi.app/debuglogs")
    }

    func testTheTellomiConstantsAreReadFromTheGlobalRegion() {
        // 契约第五节第 5 条「端点只从 profile 取」：所有构建默认用的 TSConstantsStaging 和原来写死的回落地址都指到表里
        let constants = TSConstantsStaging()
        XCTAssertEqual(constants.mainServiceURL, global.chat)
        XCTAssertEqual(constants.customServerChatHostname, global.grpcChatHost)
        XCTAssertEqual(constants.storageServiceURL, global.storage)
        XCTAssertEqual(constants.textSecureCDN0ServerURL, global.cdn0)
        XCTAssertEqual(constants.textSecureCDN2ServerURL, global.cdn2)
        XCTAssertEqual(constants.textSecureCDN3ServerURL, global.cdn3)
        XCTAssertEqual(constants.updatesURL, global.updates)
        XCTAssertEqual(constants.updates2URL, global.updates)
        XCTAssertEqual(constants.registrationCaptchaURL, global.captchaRegistration)
        XCTAssertEqual(constants.challengeCaptchaURL, global.captchaChallenge)
        XCTAssertEqual(constants.sfuURL, global.sfu)
        XCTAssertEqual(constants.sfuTestURL, global.sfu)
        XCTAssertEqual(ContentProxy.defaultEndpoint.host, global.contentProxyHost)
        XCTAssertEqual(ContentProxy.defaultEndpoint.port, global.contentProxyPort)
    }

    func testCnRegionOnlySwapsTheHostIntoTellomiCn() {
        XCTAssertEqual(cn.id, .cn)
        XCTAssertFalse(cn.enabled)
        XCTAssertEqual(cn.chat, "https://chat.tellomi.cn")
        XCTAssertEqual(cn.grpcChatHost, "grpc.chat.tellomi.cn")
        XCTAssertEqual(cn.captchaRegistration, "https://chat.tellomi.cn/captcha-tellomi/registration/generate.html")
        XCTAssertEqual(cn.sfu, "https://chat.tellomi.cn/callingService")
        XCTAssertEqual(cn.contentProxyHost, "contentproxy.tellomi.cn")
        XCTAssertEqual(cn.contentProxyPort, 443)
        XCTAssertEqual(cn.debugLog, "https://chat.tellomi.cn/debuglogs")

        // App 备案要填运行时连接的全部域名：CN 档一条都不能留在 tellomi.app
        XCTAssertFalse(cn.endpoints.contains { $0.contains("tellomi.app") })
        // 整张核（不只抽查）：今天 global 的端点路径里都不含 tellomi.app，所以整串替换就是正确答案
        XCTAssertEqual(cn.endpoints, global.endpoints.map { $0.replacingOccurrences(of: ".tellomi.app", with: ".tellomi.cn") })
    }

    func testHostRewriteKeepsEverythingButTheHost() {
        XCTAssertEqual(TellomiRegions.toCnHost("https://updates.tellomi.app/ios/manifest.json"), "https://updates.tellomi.cn/ios/manifest.json")
        XCTAssertEqual(TellomiRegions.toCnHost("contentproxy.tellomi.app:443"), "contentproxy.tellomi.cn:443")
        XCTAssertEqual(
            TellomiRegions.toCnHost("https://chat.tellomi.app:8443/x.tellomi.app/y?q=z.tellomi.app#f.tellomi.app"),
            "https://chat.tellomi.cn:8443/x.tellomi.app/y?q=z.tellomi.app#f.tellomi.app",
        )
        // 别的域名、顶级域本身都不动（由 problems 挑出来）
        XCTAssertEqual(TellomiRegions.toCnHost("https://api.stripe.com/v1"), "https://api.stripe.com/v1")
        XCTAssertEqual(TellomiRegions.toCnHost("https://tellomi.app/download"), "https://tellomi.app/download")
        XCTAssertEqual(TellomiRegions.toCnHost("wss://svr2.staging.signal.org"), "wss://svr2.staging.signal.org")

        XCTAssertEqual(TellomiRegions.hostOf("https://chat.tellomi.app/callingService"), "chat.tellomi.app")
        XCTAssertEqual(TellomiRegions.hostOf("grpc.chat.tellomi.app"), "grpc.chat.tellomi.app")
        XCTAssertEqual(TellomiRegions.hostOf("contentproxy.tellomi.app:443"), "contentproxy.tellomi.app")
    }

    func testPackagedRegionsSatisfyTheInvariants() {
        XCTAssertEqual(TellomiRegions.problems(TellomiRegions.all), [])
        XCTAssertEqual(TellomiRegions.all.map(\.id), [.global, .cn])
    }

    func testInvariantCheckCatchesABrokenTable() {
        let disabledGlobal = TellomiRegionProfile(copying: global, enabled: false)
        XCTAssertFalse(TellomiRegions.problems([disabledGlobal, cn]).isEmpty)

        XCTAssertFalse(TellomiRegions.problems([cn]).isEmpty)

        let enabledCn = TellomiRegionProfile(copying: cn, enabled: true)
        XCTAssertFalse(TellomiRegions.problems([global, enabledCn]).isEmpty)

        // CN 漏换一个主机
        let leakyCn = TellomiRegionProfile(copying: cn, uptimeHost: global.uptimeHost)
        XCTAssertEqual(TellomiRegions.problems([global, leakyCn]), ["cn endpoint outside tellomi.cn: uptime.tellomi.app"])

        XCTAssertFalse(TellomiRegions.problems([global, cn, cn]).isEmpty)
    }

    // MARK: - 当前区（#1056 第二刀）

    func testCurrentRegionFallsBackToGlobalForAnythingUnusable() {
        // 契约第五节第 8 条：没有记录、不认识、那个区关着，一律回落 global
        for storedId in [nil, "global", "cn", "unknown", "", "GLOBAL"] {
            XCTAssertEqual(TellomiRegions.resolve(storedId: storedId).id, .global, String(describing: storedId))
        }
        // CN 打开以后才认 "cn"
        let cnOn = TellomiRegionProfile(copying: cn, enabled: true)
        XCTAssertEqual(TellomiRegions.resolve(storedId: "cn", profiles: [global, cnOn]).id, .cn)
        XCTAssertEqual(TellomiRegions.resolve(storedId: "global", profiles: [global, cnOn]).id, .global)
    }

    func testCurrentRegionReadsTheSharedStoreAndNeverThrows() {
        let defaults = TestUtils.userDefaults()
        let store = TellomiRegionStore(userDefaults: { defaults })
        XCTAssertNil(store.storedRegionId())
        XCTAssertNil(store.lastSwitchAt())
        XCTAssertEqual(TellomiRegions.current(store: store), global)

        let switchedAt = Date(timeIntervalSince1970: 1_790_000_000)
        store.record(.cn, at: switchedAt)
        XCTAssertEqual(store.storedRegionId(), "cn")
        XCTAssertEqual(store.lastSwitchAt(), switchedAt)
        // CN 关着：记住了也回落 global
        XCTAssertEqual(TellomiRegions.current(store: store), global)

        // 读不出来（suite 建不起来）：回落 global，写入也不崩
        let unavailable = TellomiRegionStore(userDefaults: { nil })
        XCTAssertEqual(TellomiRegions.current(store: unavailable), global)
        unavailable.record(.cn, at: switchedAt)
        XCTAssertNil(unavailable.storedRegionId())
    }

    func testStagingEndpointsAreReadAtUseTimeNotOnce() {
        // #1056 交接评论第二处：TSConstants.shared 是 static let，端点要是在初始化时存下来，
        // 以后切区只重建了 Net，REST 侧还连旧区（半切换）。这里切换当前区，同一个实例取到的端点要跟着变。
        var region = global
        let constants = TSConstantsStaging(region: { region })
        XCTAssertEqual(constants.mainServiceURL, "https://chat.tellomi.app")

        region = cn
        XCTAssertEqual(constants.mainServiceURL, cn.chat)
        XCTAssertEqual(constants.customServerChatHostname, cn.grpcChatHost)
        XCTAssertEqual(constants.storageServiceURL, cn.storage)
        XCTAssertEqual(constants.textSecureCDN0ServerURL, cn.cdn0)
        XCTAssertEqual(constants.textSecureCDN2ServerURL, cn.cdn2)
        XCTAssertEqual(constants.textSecureCDN3ServerURL, cn.cdn3)
        XCTAssertEqual(constants.updatesURL, cn.updates)
        XCTAssertEqual(constants.updates2URL, cn.updates)
        XCTAssertEqual(constants.registrationCaptchaURL, cn.captchaRegistration)
        XCTAssertEqual(constants.challengeCaptchaURL, cn.captchaChallenge)
        XCTAssertEqual(constants.sfuURL, cn.sfu)
        XCTAssertEqual(constants.sfuTestURL, cn.sfu)
    }

    // MARK: - 门禁：端点只从区域表取（契约第五节第 5 条）

    /// 区域表里的端点主机。别的源文件再写这些主机的字面量，就绕过了区域表：切区时它还连旧区，CN 档备案也会漏报。
    /// 官网（tellomi.app 本身）、tell.cc 不分区，不在单子里。
    private static let endpointHosts = [
        "chat.tellomi.app",
        "grpc.chat.tellomi.app",
        "storage.tellomi.app",
        "cdn.tellomi.app",
        "cdn2.tellomi.app",
        "cdn3.tellomi.app",
        "updates.tellomi.app",
        "contentproxy.tellomi.app",
        "uptime.tellomi.app",
    ]

    private static let regionTableFile = "SignalServiceKit/Environment/TellomiRegions.swift"

    /// 扫各个 App 目标的源码（不含测试），返回「相对路径:行号: 内容」。注释行不算。
    private func endpointLiterals() throws -> [String] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Util
            .deletingLastPathComponent() // tests
            .deletingLastPathComponent() // SignalServiceKit
            .deletingLastPathComponent() // 仓库根
            .resolvingSymlinksInPath() // 本机 /tmp 是 /private/tmp 的链接，枚举出来的是解析后的路径，两边要一致
        var hits = [String]()
        for target in ["Signal", "SignalServiceKit", "SignalUI", "SignalNSE", "SignalShareExtension"] {
            let dir = root.appendingPathComponent(target)
            guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else {
                XCTFail("can't read \(dir.path)")
                continue
            }
            for case let url as URL in enumerator {
                if ["test", "tests", "TestUtils"].contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                    continue
                }
                guard url.pathExtension == "swift" else {
                    continue
                }
                let path = url.resolvingSymlinksInPath().path
                guard path.hasPrefix(root.path + "/") else {
                    XCTFail("\(path) is outside \(root.path)")
                    continue
                }
                let relativePath = String(path.dropFirst(root.path.count + 1))
                let text = try String(contentsOf: url, encoding: .utf8)
                for (index, line) in text.components(separatedBy: "\n").enumerated() {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
                        continue
                    }
                    if Self.endpointHosts.contains(where: { line.contains($0) }) {
                        hits.append("\(relativePath):\(index + 1): \(trimmed)")
                    }
                }
            }
        }
        return hits
    }

    func testEndpointsAreReadOnlyFromTheRegionTable() throws {
        let outside = try endpointLiterals().filter { !$0.hasPrefix(Self.regionTableFile + ":") }
        XCTAssertEqual(outside, [], "端点主机只许写在区域表里，其余地方从 TellomiRegions.current() 取")
    }

    func testTheEndpointScanActuallyReadsTheSources() throws {
        // 正对照：区域表文件本身命中十几处，证明扫描确实读到了源码，上面那条「没找到」不是空断言
        let inTable = try endpointLiterals().filter { $0.hasPrefix(Self.regionTableFile + ":") }
        XCTAssertGreaterThanOrEqual(inTable.count, Self.endpointHosts.count)
    }
}

private extension TellomiRegionProfile {
    /// 测试里造坏表用：只改给出的字段。
    init(copying other: TellomiRegionProfile, enabled: Bool? = nil, uptimeHost: String? = nil) {
        self.init(
            id: other.id,
            enabled: enabled ?? other.enabled,
            chat: other.chat,
            grpcChatHost: other.grpcChatHost,
            storage: other.storage,
            cdn0: other.cdn0,
            cdn2: other.cdn2,
            cdn3: other.cdn3,
            updates: other.updates,
            contentProxyHost: other.contentProxyHost,
            contentProxyPort: other.contentProxyPort,
            captchaRegistration: other.captchaRegistration,
            captchaChallenge: other.captchaChallenge,
            sfu: other.sfu,
            uptimeHost: uptimeHost ?? other.uptimeHost,
            debugLog: other.debugLog,
        )
    }
}
