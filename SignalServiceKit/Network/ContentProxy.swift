//
// Copyright 2019 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import Network

public enum ContentProxy {

    /// Tellomi（#1110）：编译期回落值。上游写死的是 Signal 自己的内容代理。
    static let defaultEndpoint = Endpoint(host: "contentproxy.tellomi.app", port: 443)

    struct Endpoint: Equatable {
        let host: String
        let port: Int
    }

    public static func sessionConfiguration() -> URLSessionConfiguration {
        return sessionConfiguration(endpoint: endpoint(remoteProxyUrl: RemoteConfig.current.gifProxyUrl))
    }

    /// 拆出来是为了能在测试里直接构造：`RemoteConfig.current` 要整个 SSKEnvironment 才读得到。
    static func sessionConfiguration(endpoint: Endpoint) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral

        if #available(iOS 17.0, *) {
            // Tellomi（#1110）：先和代理做 TLS，再在里面发 CONNECT。
            //
            // connectionProxyDictionary 的 HTTPS 代理项是对代理发**明文** CONNECT：目标主机名（api.giphy.com）
            // 和隧道里 TLS 的 SNI 都在明文里，从大陆出发会被墙 reset——换成我们自己的代理也一样
            // （2026-09-23 实测，细节见 tellomi/Signal-Android#11）。香港那台的 nginx 按 SNI 分流：
            // SNI = contentproxy.tellomi.app 的进 TLS 终结再交给 tinyproxy，所以外层 TLS 之后墙上只看得到我们自己的域名。
            // TLS 选项用默认的：SNI 与证书校验都按 endpoint 的主机名。
            let proxy = NWEndpoint.hostPort(
                host: NWEndpoint.Host(endpoint.host),
                port: NWEndpoint.Port(rawValue: UInt16(clamping: endpoint.port)) ?? 443,
            )
            configuration.proxyConfigurations = [
                ProxyConfiguration(httpCONNECTProxy: proxy, tlsOptions: NWProtocolTLS.Options()),
            ]
        } else {
            // iOS 15 / 16 没有「和代理之间先做 TLS」的 API，只能保留上游的明文 CONNECT：境外能用，大陆不通。
            configuration.connectionProxyDictionary = [
                "HTTPEnable": 1,
                "HTTPProxy": endpoint.host,
                "HTTPPort": endpoint.port,
                "HTTPSEnable": 1,
                "HTTPSProxy": endpoint.host,
                "HTTPSPort": endpoint.port,
            ]
        }
        return configuration
    }

    /// Tellomi（#1110，ADR-0064 §4.4）：服务端下发的 `global.gif.proxyUrl`（形如 `https://contentproxy.tellomi.app:443`）
    /// 能用就用，否则回落到 ``defaultEndpoint``。有了它，备案之后换成 `contentproxy.tellomi.cn` 不用发版。
    ///
    /// **只认 https**：和代理之间必须先做 TLS，下发一个 `http://` 进来等于让服务端一行配置就把所有客户端
    /// 降回明文 CONNECT——那在大陆直接不通，所以宁可回落。和 Android 的 `ContentProxySelector.parseProxyUrl`
    /// （tellomi/Signal-Android#12）同口径。
    static func endpoint(remoteProxyUrl: String?) -> Endpoint {
        guard
            let remoteProxyUrl,
            let components = URLComponents(string: remoteProxyUrl.trimmingCharacters(in: .whitespacesAndNewlines)),
            components.scheme?.lowercased() == "https",
            let host = components.host,
            !host.isEmpty
        else {
            if let remoteProxyUrl, !remoteProxyUrl.isEmpty {
                Logger.warn("Ignoring global.gif.proxyUrl, not an https:// URL with a host. Falling back to the build-time proxy.")
            }
            return defaultEndpoint
        }
        return Endpoint(host: host, port: components.port ?? 443)
    }

    public static func configureProxiedRequest(request: inout URLRequest) -> Bool {
        request.setValue(
            OWSURLSession.userAgentHeaderValueSignalIos,
            forHTTPHeaderField: HttpHeaders.userAgentHeaderKey,
        )

        padRequestSize(request: &request)

        return request.url?.scheme?.lowercased() == "https"
    }

    public static func padRequestSize(request: inout URLRequest) {
        let paddingLength = Int.random(in: 1...64)
        let padding = self.padding(withLength: paddingLength)
        assert(padding.count == paddingLength)
        request.setValue(padding, forHTTPHeaderField: "X-SignalPadding")
    }

    private static func padding(withLength length: Int) -> String {
        var result = ""
        for _ in 1...length {
            let value = UInt8.random(in: 48...122)
            result += String(UnicodeScalar(value))
        }
        return result
    }
}
