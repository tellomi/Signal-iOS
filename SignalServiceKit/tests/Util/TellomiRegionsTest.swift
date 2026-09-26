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
