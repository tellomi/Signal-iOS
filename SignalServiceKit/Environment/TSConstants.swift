//
// Copyright 2019 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

// MARK: -

import Foundation
public import LibSignalClient

public class TSConstants {

    private enum Environment {
        case production
        case staging
    }

    private static let environment: Environment = {
        // Tellomi：**所有构建都默认连我们自己的服务端**（`.staging` = 香港那套；
        // `.production` 在这个 fork 里指的仍然是 **Signal 官方**的服务器）。
        //
        // 上游的写法是「Debug 看 USE_STAGING，其余一律 production」。照搬会出两种事故，
        // 2026-09-22 两种都真的发生了：
        //   1. `USE_STAGING` 是启动参数带的，从桌面点图标打开时没有 —— 同一个 App，
        //      命令行启动连香港、用户点图标连 Signal 生产。
        //   2. 换成 `Testable Release` 给 owner 装真机之后，整段 `#if DEBUG` 直接失效，
        //      于是那个包全程在连 Signal 官方服务器（owner 当场发现「登不上去了」）。
        //
        // 在我们自己的生产环境存在之前，「Tellomi 的包去连 Signal 官方服务器」
        // 没有任何合理用途，所以不区分构建配置，一律 staging。
        // 要故意连上游（比如对照上游行为排查）时设 `USE_PRODUCTION=1`。
        if ProcessInfo.processInfo.environment["USE_PRODUCTION"] == "1" {
            return .production
        }
        return .staging
    }()

    public static var isUsingProductionService: Bool {
        return environment == .production
    }

    // Never instantiate this class.
    private init() {}

    public static let legalTermsUrl = URL(string: "https://tellomi.app/legal/")!
    public static let donateUrl = URL(string: "https://signal.org/donate/")!
    public static let appStoreUrl = URL(string: "https://itunes.apple.com/us/app/signal-private-messenger/id874139669?mt=8")!

    public static var mainServiceURL: String { shared.mainServiceURL }

    public static var textSecureCDN0ServerURL: String { shared.textSecureCDN0ServerURL }
    public static var textSecureCDN2ServerURL: String { shared.textSecureCDN2ServerURL }
    public static var textSecureCDN3ServerURL: String { shared.textSecureCDN3ServerURL }
    public static var storageServiceURL: String { shared.storageServiceURL }
    public static var sfuURL: String { shared.sfuURL }
    public static var sfuTestURL: String { shared.sfuTestURL }
    public static var svr2URL: String { shared.svr2URL }
    public static var registrationCaptchaURL: String { shared.registrationCaptchaURL }
    public static var challengeCaptchaURL: String { shared.challengeCaptchaURL }
    public static var kUDTrustRoots: [String] { shared.kUDTrustRoots }
    public static var updatesURL: String { shared.updatesURL }
    public static var updates2URL: String { shared.updates2URL }

    public static var censorshipFReflectorHost: String { shared.censorshipFReflectorHost }
    public static var censorshipGReflectorHost: String { shared.censorshipGReflectorHost }

    public static var serviceCensorshipPrefix: String { shared.serviceCensorshipPrefix }
    public static var cdn0CensorshipPrefix: String { shared.cdn0CensorshipPrefix }
    public static var cdn2CensorshipPrefix: String { shared.cdn2CensorshipPrefix }
    public static var cdn3CensorshipPrefix: String { shared.cdn3CensorshipPrefix }
    public static var storageServiceCensorshipPrefix: String { shared.storageServiceCensorshipPrefix }
    public static var svr2CensorshipPrefix: String { shared.svr2CensorshipPrefix }

    static var svr2Enclaves: [MrEnclave] { shared.svr2Enclaves }

    public static var applicationGroup: String { shared.applicationGroup }
    public static var customServerChatHostname: String? { shared.customServerChatHostname }
    public static var svrEnclaveAvailable: Bool { shared.svrEnclaveAvailable }
    public static var cdsiAvailable: Bool { shared.cdsiAvailable }
    public static var keyTransparencyAvailable: Bool { shared.keyTransparencyAvailable }

    /// Tellomi：阶段一**不做捐赠**（owner 2026-09-22 定）。
    ///
    /// 为 false 时隐藏所有用户能点到的捐赠入口。这不是「部署差异」而是产品阶段决定，
    /// 所以放在这里而不是 prod / staging 两个档里——要做的时候翻成 true 即可，
    /// 上游的捐赠代码原样留着，没有删。
    ///
    /// 背景：我们既没有支付通道（Apple Pay 商户号、支付处理方都没有），服务端下发的
    /// 也还是上游的测试配置（`/v1/subscription/configuration` 里 `xts` 测试币、
    /// `example.svg` 徽章，客户端解析不了）。而且这些页面上还写着「Proudly Nonprofit」
    /// 「Signal is a 501c3 nonprofit」这类**对 Tellomi 不成立**的资质说法。
    public static let donationsEnabled = false


    public static var serverPublicParams: Data { shared.serverPublicParams }
    public static var callLinkPublicParams: Data { shared.callLinkPublicParams }
    public static var backupServerPublicParams: Data { shared.backupServerPublicParams }

    public static let shared: TSConstantsProtocol = {
        switch environment {
        case .production:
            return TSConstantsProduction()
        case .staging:
            return TSConstantsStaging()
        }
    }()

    public static let libSignalEnv: Net.Environment = {
        switch environment {
        case .production:
            return .production
        case .staging:
            return .staging
        }
    }()
}

// MARK: -

public protocol TSConstantsProtocol: AnyObject {
    var mainServiceURL: String { get }
    var textSecureCDN0ServerURL: String { get }
    var textSecureCDN2ServerURL: String { get }
    var textSecureCDN3ServerURL: String { get }
    var storageServiceURL: String { get }
    var sfuURL: String { get }
    var sfuTestURL: String { get }
    var svr2URL: String { get }
    var registrationCaptchaURL: String { get }
    var challengeCaptchaURL: String { get }
    var kUDTrustRoots: [String] { get }
    var updatesURL: String { get }
    var updates2URL: String { get }

    var censorshipFReflectorHost: String { get }
    var censorshipGReflectorHost: String { get }

    var serviceCensorshipPrefix: String { get }
    var cdn0CensorshipPrefix: String { get }
    var cdn2CensorshipPrefix: String { get }
    var cdn3CensorshipPrefix: String { get }
    var storageServiceCensorshipPrefix: String { get }
    var svr2CensorshipPrefix: String { get }

    var svr2Enclaves: [MrEnclave] { get }
    var activeSvr2EnclaveCount: Int { get }

    var applicationGroup: String { get }

    /// Tellomi: 自建服务端的 libsignal（Omnibus）主机名；`nil` = 用 Signal 官方环境。
    /// libsignal-net 把官方 staging / prod 的域名与根证书编译在 Rust 里，客户端侧覆盖不了，
    /// 所以连自建服务端只能走 `Net(customServerHostname:)`（tellomi/libsignal 的 tellomi-0.102.0 分支）。
    var customServerChatHostname: String? { get }

    /// Tellomi：这套部署有没有 SVR（Secure Value Recovery）enclave。
    ///
    /// SVR2 是 Intel SGX enclave，客户端握手要校验 Intel 根证书签的 DCAP quote 与 mrenclave
    /// 白名单（libsignal `rust/attest`），**没有真 SGX 机器就通不过**，没有绕过开关。自建服务端
    /// （香港）现在没有，所以注册末尾「创建 PIN」必然超时，而注册流程里那一页在新账号路径上
    /// 没有跳过入口，用户就卡死在那里。
    ///
    /// 为 false 时：注册流程把 PIN 那一步当作「已跳过」（走上游自己的 `hasSkippedPinEntry`，
    /// 不碰 enclave）。以后真装了 enclave，把这个值翻回 true 就恢复上游行为。
    /// 细节与阶段一决定见 `docs/signal/ENCLAVES.md`。
    var svrEnclaveAvailable: Bool { get }

    /// Tellomi：这套部署有没有 CDSI（按手机号找人）的 enclave。与 svrEnclaveAvailable 同理。
    var cdsiAvailable: Bool { get }

    /// Tellomi：这套部署有没有 key transparency 服务（独立的 key-transparency-server）。
    /// 没有时服务端只能回 500，而客户端把任何非 200 都当错误、几秒一次地重试。
    var keyTransparencyAvailable: Bool { get }

    var serverPublicParams: Data { get }
    var callLinkPublicParams: Data { get }
    var backupServerPublicParams: Data { get }
}

public struct MrEnclave: Equatable {
    public let dataValue: Data
    public let stringValue: String

    init(_ stringValue: StaticString) {
        self.stringValue = String(describing: stringValue)
        // This is a constant -- it should never fail to parse.
        self.dataValue = Data.data(fromHex: self.stringValue)!
        // All of our MrEnclave values are currently 32 bytes.
        owsPrecondition(self.dataValue.count == 32)
    }

    public static func ==(lhs: Self, rhs: Self) -> Bool {
        return lhs.dataValue == rhs.dataValue
    }
}

// MARK: - Production

public class TSConstantsProduction: TSConstantsProtocol {

    public init() {}

    public let customServerChatHostname: String? = nil
    public let svrEnclaveAvailable: Bool = true
    public let cdsiAvailable: Bool = true
    public let keyTransparencyAvailable: Bool = true

    public let mainServiceURL = "https://chat.signal.org"
    public let textSecureCDN0ServerURL = "https://cdn.signal.org"
    public let textSecureCDN2ServerURL = "https://cdn2.signal.org"
    public let textSecureCDN3ServerURL = "https://cdn3.signal.org"
    public let storageServiceURL = "https://storage.signal.org"
    public let sfuURL = "https://sfu.voip.signal.org"
    public let sfuTestURL = "https://sfu.test.voip.signal.org"
    public let svr2URL = "wss://svr2.signal.org"
    public let registrationCaptchaURL = "https://signalcaptchas.org/registration/generate.html"
    public let challengeCaptchaURL = "https://signalcaptchas.org/challenge/generate.html"
    public let kUDTrustRoots = ["BXu6QIKVz5MA8gstzfOgRQGqyLqOwNKHL6INkv3IHWMF", "BUkY0I+9+oPgDCn4+Ac6Iu813yvqkDr/ga8DzLxFxuk6"]
    public let updatesURL = "https://updates.signal.org"
    public let updates2URL = "https://updates2.signal.org"

    public let censorshipFReflectorHost = "reflector-signal.global.ssl.fastly.net"
    public let censorshipGReflectorHost = "reflector-nrgwuv7kwq-uc.a.run.app"

    public let serviceCensorshipPrefix = "service"
    public let cdn0CensorshipPrefix = "cdn"
    public let cdn2CensorshipPrefix = "cdn2"
    public let cdn3CensorshipPrefix = "cdn3"
    public let storageServiceCensorshipPrefix = "storage"
    public let svr2CensorshipPrefix = "svr2"

    // An array of enclaves that we should try and restore key material from
    // during registration. These must be ordered from newest to oldest, so we
    // check the latest enclaves before checking earlier enclaves.
    //
    // When backing up, we attempt to back up to the first
    // `activeSvr2EnclaveCount` elements of this array. We typically set it to
    // two for a brief time after adding a new enclave.
    public let svr2Enclaves = [
        MrEnclave("ced8217b26228e4b210c985786999d095c4958a94faf37b14acaf25c4cbb02a4"),
        MrEnclave("1240acbd4aa26974184844c8a46b1022d3957ac8a76c1fd8f5b1a15141ee0708"),
    ]

    public let activeSvr2EnclaveCount: Int = 1

    public let applicationGroup = "group." + Bundle.main.bundleIdPrefix + ".group"

    /// We *might* need to clear credentials (or perform some other migration)
    /// when this value changes, depending on how it's changing. If you do need
    /// to perform a migration, check out `ZkParamsMigrator`.
    public let serverPublicParams = Data(base64Encoded: "AMhf5ywVwITZMsff/eCyudZx9JDmkkkbV6PInzG4p8x3VqVJSFiMvnvlEKWuRob/1eaIetR31IYeAbm0NdOuHH8Qi+Rexi1wLlpzIo1gstHWBfZzy1+qHRV5A4TqPp15YzBPm0WSggW6PbSn+F4lf57VCnHF7p8SvzAA2ZZJPYJURt8X7bbg+H3i+PEjH9DXItNEqs2sNcug37xZQDLm7X36nOoGPs54XsEGzPdEV+itQNGUFEjY6X9Uv+Acuks7NpyGvCoKxGwgKgE5XyJ+nNKlyHHOLb6N1NuHyBrZrgtY/JYJHRooo5CEqYKBqdFnmbTVGEkCvJKxLnjwKWf+fEPoWeQFj5ObDjcKMZf2Jm2Ae69x+ikU5gBXsRmoF94GXTLfN0/vLt98KDPnxwAQL9j5V1jGOY8jQl6MLxEs56cwXN0dqCnImzVH3TZT1cJ8SW1BRX6qIVxEzjsSGx3yxF3suAilPMqGRp4ffyopjMD1JXiKR2RwLKzizUe5e8XyGOy9fplzhw3jVzTRyUZTRSZKkMLWcQ/gv0E4aONNqs4P+NameAZYOD12qRkxosQQP5uux6B2nRyZ7sAV54DgFyLiRcq1FvwKw2EPQdk4HDoePrO/RNUbyNddnM/mMgj4FW65xCoT1LmjrIjsv/Ggdlx46ueczhMgtBunx1/w8k8V+l8LVZ8gAT6wkU5J+DPQalQguMg12Jzug3q4TbdHiGCmD9EunCwOmsLuLJkz6EcSYXtrlDEnAM+hicw7iergYLLlMXpfTdGxJCWJmP4zqUFeTTmsmhsjGBt7NiEB/9pFFEB3pSbf4iiUukw63Eo8Aqnf4iwob6X1QviCWuc8t0LUlT9vALgh/f2DPVOOmR0RW6bgRvc7DSF20V/omg+YBw==")!

    public let callLinkPublicParams = Data(base64Encoded: "AeCO67P9mIv1yUHkdeZ9JF789GDbox61GvTqq3S4kYc1ADUWxWHQygU390tv1oRWt9WjkdZlU7mKkifF59ftjE+2ZlMmxns6I+ySiLpR8FEmfu+TGpVp3zYTjNV93obJJTyBCCsSHVETCyQRbKdCyb5TMa6LGrvcZaX0Q/VAavhuNA/m4kSiRMgSnYrUjGhVekdDnF+7xioo4wvFnxjIDh7uJQrYOWD6MloNGX7St5gbysTuQQ7i/HI38b9V8x8mKazuDSXxB//BKGZx/XHkK8cHX+QK1MPxYUVM1/CBI5oW")!

    public let backupServerPublicParams = Data(base64Encoded: "AZwNSU55fsFCbgaxGRD11wO1juAs8Yr5GF8FPlGzzvdJJIKH5/4CC7ZJSOe3yL2vturVaRU2Cx0n751Vt8wkj1Y4pyiScu0/S10n647ipo+iq97JZQv+UOlwH8ThyNlGT5DfxXCwTqivxHuXvZpuezPgHk5Gxl5aC6xuNxOnwmFlmu4CeSgdhW8+Pp0vAJOQ1MsU2D0+/kzI+tU94nB3tybY/Ao1AcGW2q41uKQbnOJUWwmQaFT6s+xTISgzsg7CPox6oORGX8rnyk/9lic3DbGsUHctIVpMAl/ogJBb4aYC")!
}

// MARK: - Staging

public class TSConstantsStaging: TSConstantsProtocol {

    public init() {}

    /// Tellomi 自建服务端（香港）。REST 与 libsignal 是两个主机，见 docs/signal/CLIENT_LOCAL_SERVER.md 第四节。
    ///
    /// 注意：下面的 base64 公钥**必须带足 `=` 填充**。Swift 的 `Data(base64Encoded:)` 是严格的，
    /// 少填充会返回 nil 然后在这里强解包崩溃；而 Android 侧的 Java 解码器是宽松的，同一个值在那边不报错。
    /// 2026-09-21 踩过一次：`serverPublicParams` 从文档里抄来时少了结尾的 `==`。
    public let customServerChatHostname: String? = "grpc.chat.tellomi.app"
    public let svrEnclaveAvailable: Bool = false
    public let cdsiAvailable: Bool = false
    public let keyTransparencyAvailable: Bool = false

    public let mainServiceURL = "https://chat.tellomi.app"
    public let textSecureCDN0ServerURL = "https://cdn.tellomi.app"
    public let textSecureCDN2ServerURL = "https://cdn2.tellomi.app"
    public let textSecureCDN3ServerURL = "https://cdn3.tellomi.app"
    public let storageServiceURL = "https://storage.tellomi.app"
    public let sfuURL = "https://sfu.staging.voip.signal.org"
    public let svr2URL = "wss://svr2.staging.signal.org"
    // 自建服务端：香港 nginx 上的 captcha 页（Cloudflare Turnstile，#930；通过后跳 tellomicaptcha://turnstile.<siteKey>.<action>.<token>，
    // CaptchaView 新旧 scheme 都认）。/captcha/ 那份回旧的 signalcaptcha://，两阶段迁移完成后下线。
    public let registrationCaptchaURL = "https://chat.tellomi.app/captcha-tellomi/registration/generate.html"
    public let challengeCaptchaURL = "https://chat.tellomi.app/captcha-tellomi/challenge/generate.html"
    // There's no separate test SFU for staging.
    public let sfuTestURL = "https://sfu.test.voip.signal.org"
    public let kUDTrustRoots = ["BcLYlMOrgCUTLuLXSvW5I1FiBAub5uoawfHDNzrzyNg3"]
    // There's no separate updates endpoint for staging.
    public let updatesURL = "https://updates.signal.org"
    public let updates2URL = "https://updates2.signal.org"

    public let censorshipFReflectorHost = "reflector-staging-signal.global.ssl.fastly.net"
    public let censorshipGReflectorHost = "reflector-nrgwuv7kwq-uc.a.run.app"

    public let serviceCensorshipPrefix = "service-staging"
    public let cdn0CensorshipPrefix = "cdn-staging"
    public let cdn2CensorshipPrefix = "cdn2-staging"
    public let cdn3CensorshipPrefix = "cdn3-staging"
    public let storageServiceCensorshipPrefix = "storage-staging"
    public let svr2CensorshipPrefix = "svr2-staging"

    public let svr2Enclaves = [
        MrEnclave("3c699f4975aaa3d172c0aad042f94f031b2b03e10b9c19a45116a01693d83302"),
        MrEnclave("97f151f6ed078edbbfd72fa9cae694dcc08353f1f5e8d9ccd79a971b10ffc535"),
        MrEnclave("a75542d82da9f6914a1e31f8a7407053b99cc99a0e7291d8fbd394253e19b036"),
    ]

    public let activeSvr2EnclaveCount: Int = 1

    public let applicationGroup = "group." + Bundle.main.bundleIdPrefix + ".group.staging"

    /// We *might* need to clear credentials (or perform some other migration)
    /// when this value changes, depending on how it's changing. If you do need
    /// to perform a migration, check out `ZkParamsMigrator`.
    public let serverPublicParams = Data(base64Encoded: "ADKO0hJxgxBky6XbESgxS+kxUo0+0fZinOfVIZfT+Chs1lBx0vRYvMzp+gUsbOpVRfsRMfdSwHq4GdExEyIMDhwamT0uT7OyL25KHXgAUXu56vWApb8c1mgdsd6GbfyfAOqGNAR7e8emQLSivHo+oYJVciuQVAznjbWdtjpvXMs3QMxitzmOcxhskuV+E6Md8BNIIqK6kviBf6GTVVJRIGr655FBcPf89L6Iva9ZEirT0pzQPBcGZ7mkzq56khyHLVxx3VzxCDjEUhPrco1Y4yfNqE7WA8JKi8dXA3pEslk8ztjXZ2C3nOIl1DnsaOJytFo14Gjri895dlDHCvY0s25sJlep3NrCO6U4imVVFhmc77y0dbn2FTwnOwefltRFQxz5yVvD4y50n8f6zZblT6u6w7YSdkf9glpzJOSYMdxPnHtWzzgQxPfqms2JYimZRakIqPcfnb3JIFTJqFITI3/E966PuFsB2kgZUNa+L9WUnhEw9utSJeFGltuX4IYIPPIWe1htCnrAyQgmpSoEwHseozG+FPol+YF4Hqd/WyA0DrPNr1749cXRkfwM+dNwrE59LkBf8Fp5UhtlyUW21E6wA4MLRAc2uoPXRUFzTcVykb42EYI/sAOWIfT103RvUhQfSBDYCj8uMYOonZ9fpkIL0u6zLt8zUE4CwjfbLAZ0bkKdS/baN5UMlq8cd3HZa09mvvLuL0Grl5mqRIRhUD4EhX8sVZHOzbof0Rc5JL4GvI4QOCObatrKg73D5prfLqyaJPb0TxuACl2S5fnNHs5FmqkDEw62yiUsrw5f8XYUTq5Y85s9MXBSjMUCGg+davkwDlmm1A4gqHuTzbcgGBRIh1iqWJ93cBq+uWsnMhSSdPbv4l8FUJwpruaZEj6FSw==")!

    // Tellomi：#877 之前香港的 calling zk secret 是独立生成的，这里曾经是那把派生出来的公钥
    // （AYhaw…）。#877 把三个 generic secret 统一成 chatZkConfig 的之后它就废了，而群凭证响应里的
    // call link 凭证是用统一后的那把签的 —— iOS 验到这一项就报 Verification failure in zkgroup，
    // 表现为「新建群组点完就闪退」（owner 2026-09-22 真机）。taishi 用离线验签定位到这一行（#909）。
    // 这一串与 docs/signal/CLIENT_LOCAL_SERVER.md 第 126 行、Desktop、Android staging 一致（225 字节）。
    public let callLinkPublicParams = Data(base64Encoded: "AP56nq1D39Uj1w+IDJCLdI4Eu9oqaEVKGELsl9HUlLxsflrRKB+gotelWnixnUDG+8yux4794uDsyWQlGKp1xHq2UH8NB+3VDJWJ1TC0Dp9TaBv3Mm8u09WiycRRslZjQ8qr62rztIru/9qbgsm9nbsgnlu4eKIBSG0BTeNN+MEC0jzZyDBNeG+liynQyFBCAhgzT1Q9a4iBr451Su97P1hO4IQmKDPNwQtulriKtlLBXkqFmzL8GlZpyX1x0NRZDsimO8t+kEmovoAf+Ybbhe12PMQfVWS9IB+kJrOs+00r")!

    public let backupServerPublicParams = Data(base64Encoded: "AXYrGb9IfugAAJiPKp+mdXUx+OL9zBolPYHYQz6GI1gWjpEu5me3zVNSvmYY4zWboZHif+HG1sDHSuvwFd0QszS6h3nZ6vRdM/IYGK+cLynw3ucWo7idf3zjOG3b6JnGT/z7XYCr6HuOGkWH4DQWCH98hxVZMGOgmT8DCQoqebQb3oK1yrwEglRWmtI01KhRg9RGUKoQiwuej1JZEY8uaG4Uz9n1cVODJ1iuByhNqGHo+KfI4iWhjtx2AnhYqHViQ3CMd4ASGBJtic9UTFVk/4vegVIy0wfYsAmViftzK6t4")!

}

#if TESTABLE_BUILD

public class TSConstantsMock: TSConstantsProtocol {

    public init() {}

    private let defaultValues = TSConstantsProduction()

    public lazy var mainServiceURL = defaultValues.mainServiceURL

    public lazy var textSecureCDN0ServerURL = defaultValues.textSecureCDN0ServerURL

    public lazy var textSecureCDN2ServerURL = defaultValues.textSecureCDN2ServerURL

    public lazy var textSecureCDN3ServerURL = defaultValues.textSecureCDN3ServerURL

    public lazy var storageServiceURL = defaultValues.storageServiceURL

    public lazy var sfuURL = defaultValues.sfuURL

    public lazy var sfuTestURL = defaultValues.sfuTestURL

    public lazy var svr2URL = defaultValues.svr2URL

    public lazy var registrationCaptchaURL = defaultValues.registrationCaptchaURL

    public lazy var challengeCaptchaURL = defaultValues.challengeCaptchaURL

    public lazy var kUDTrustRoots = defaultValues.kUDTrustRoots

    public lazy var updatesURL = defaultValues.updatesURL

    public lazy var updates2URL = defaultValues.updates2URL

    public lazy var censorshipFReflectorHost = defaultValues.censorshipFReflectorHost
    public lazy var censorshipGReflectorHost = defaultValues.censorshipGReflectorHost

    public lazy var serviceCensorshipPrefix = defaultValues.serviceCensorshipPrefix

    public lazy var cdn0CensorshipPrefix = defaultValues.cdn0CensorshipPrefix

    public lazy var cdn2CensorshipPrefix = defaultValues.cdn2CensorshipPrefix

    public lazy var cdn3CensorshipPrefix = defaultValues.cdn3CensorshipPrefix

    public lazy var storageServiceCensorshipPrefix = defaultValues.storageServiceCensorshipPrefix

    public lazy var svr2CensorshipPrefix = defaultValues.svr2CensorshipPrefix

    public lazy var svr2Enclaves = defaultValues.svr2Enclaves

    public lazy var activeSvr2EnclaveCount = defaultValues.activeSvr2EnclaveCount

    public lazy var applicationGroup = defaultValues.applicationGroup

    public lazy var customServerChatHostname: String? = defaultValues.customServerChatHostname
    public lazy var svrEnclaveAvailable: Bool = defaultValues.svrEnclaveAvailable
    public lazy var cdsiAvailable: Bool = defaultValues.cdsiAvailable
    public lazy var keyTransparencyAvailable: Bool = defaultValues.keyTransparencyAvailable

    public lazy var serverPublicParams = defaultValues.serverPublicParams

    public lazy var callLinkPublicParams = defaultValues.callLinkPublicParams

    public lazy var backupServerPublicParams = defaultValues.backupServerPublicParams
}

#endif
