//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Tellomi（#1025）：上游用这个枚举挑「域名前置」的前置域名（www.google.com / pinterest.com 之类）、
/// 对应的证书钉扎策略、以及 Host 头要填的 Signal reflector。那三样连同 PinningPolicy 一起删了——
/// 规避模式现在继续走我们自己的端点，见 OWSSignalService.buildUrlEndpoint()。
///
/// 枚举本体留着：OWSCountryMetadata 按国家存了它（~250 行），而且将来自建规避入口时
/// 「哪些国家要走特殊通道」这份信息还用得上。现在它只是个标记，不再决定连哪台机器。
enum OWSFrontingHost {
    case fastly
    case googleEgypt
    case googleUae
    case googleOman
    case googlePakistan
    case googleQatar
    case googleUzbekistan
    case googleVenezuela
    case `default`
}

struct OWSCensorshipConfiguration {

    // Tellomi（#1025）：上游这里还有 domainFrontBaseUrl / domainFrontSecurityPolicy / host /
    // reflectorHost() 和两个 censorshipConfiguration(...) 工厂方法，拼出来的是
    // 「前置到 Google、Host 头填 Signal 的 reflector、并钉死 Google 的证书链」。全删了。
    // 保留下面这份国家表与 isCensored()：设置里的开关、OWSChatConnection 的取数策略都依赖它，
    // 删掉会连带改掉一堆和本条无关的行为（和 Android 的 c0b20cf2 保留 censored 标记同一个理由）。

    static func isCensored(e164: String) -> Bool {
        censoredCountryCode(e164: e164) != nil
    }

    /// 这些国家会自动把「审查规避」标记打开。
    ///
    /// Tellomi（#1025）：上游这段原文写的是「想用别的前置域名就在 OWSCountryMetadata 里指定，
    /// 并确保 securityPolicyForDomain: 里有对应的证书策略」——那套机制已经删掉了，照做会扑空。
    /// 现在打开这个标记**不会改变连哪台机器**（仍然是我们自己的端点），只影响依赖
    /// isCensorshipCircumventionActive 的那些行为。注意这张表里**没有中国**：+86 不会自动进这条路，
    /// 真正会走到的是用户手动去按设置里那个开关。
    private static let censoredCountryCodes: [String: String] = [
        // Egypt
        "+20": "EG",
        // Oman
        "+968": "OM",
        // Qatar
        "+974": "QA",
        // UAE
        "+971": "AE",
        // Cuba
        "+53": "CU",
        // Venezuela
        "+58": "VE",
        // Uzbekistan,
        "+998": "UZ",
        // Pakistan
        "+92": "PK",
    ]

    /// Returns nil if the phone number is not known to be censored
    private static func censoredCountryCode(e164: String) -> String? {
        for (key: callingCode, value: countryCode) in censoredCountryCodes {
            if e164.hasPrefix(callingCode) {
                return countryCode
            }
        }

        return nil
    }
}
