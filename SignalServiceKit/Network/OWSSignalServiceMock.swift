//
// Copyright 2022 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

#if TESTABLE_BUILD

public class OWSSignalServiceMock: OWSSignalServiceProtocol {
    public func warmCaches() {}

    public var isCensorshipCircumventionActive: Bool = false

    public var hasCensoredPhoneNumber: Bool = false

    public var isCensorshipCircumventionManuallyActivated: Bool = false

    public var isCensorshipCircumventionManuallyDisabled: Bool = false

    public var manualCensorshipCircumventionCountryCode: String?

    public func updateHasCensoredPhoneNumberDuringProvisioning(_ e164: E164) {}
    public func resetHasCensoredPhoneNumberFromProvisioning() {}

    public var urlEndpointBuilder: ((SignalServiceInfo) -> OWSURLSessionEndpoint)?

    public func buildUrlEndpoint(for signalServiceInfo: SignalServiceInfo) -> OWSURLSessionEndpoint {
        return urlEndpointBuilder?(signalServiceInfo) ?? OWSURLSessionEndpoint(
            baseUrl: signalServiceInfo.baseUrl,
            frontingInfo: nil,
            securityPolicy: .systemDefault,
            extraHeaders: [:],
        )
    }

    public var mockUrlSessionBuilder: ((SignalServiceInfo, OWSURLSessionEndpoint, URLSessionConfiguration?) -> BaseOWSURLSessionMock)?

    public func buildUrlSession(
        for signalServiceInfo: SignalServiceInfo,
        endpoint: OWSURLSessionEndpoint,
        configuration: URLSessionConfiguration?,
    ) -> OWSURLSessionProtocol {
        return mockUrlSessionBuilder?(signalServiceInfo, endpoint, configuration) ?? BaseOWSURLSessionMock(
            endpoint: endpoint,
            configuration: .default,
        )
    }

    public var mockCDNUrlSessionBuilder: ((_ cdnNumber: UInt32) -> BaseOWSURLSessionMock)?

    /// Tellomi（#1056 第三刀）：记下每次要的 CDN 地址，测试用来核「钉住开始时的区」。
    public private(set) var requestedCdnBaseUrls = [URL]()

    public func sharedUrlSessionForCdn(cdnNumber: UInt32) async -> OWSURLSessionProtocol {
        let baseUrl: URL
        switch cdnNumber {
        case 0:
            baseUrl = URL(string: TSConstants.textSecureCDN0ServerURL)!
        case 3:
            baseUrl = URL(string: TSConstants.textSecureCDN3ServerURL)!
        default:
            baseUrl = URL(string: TSConstants.textSecureCDN2ServerURL)!
        }
        return await sharedUrlSessionForCdn(cdnNumber: cdnNumber, baseUrl: baseUrl)
    }

    public func sharedUrlSessionForCdn(cdnNumber: UInt32, baseUrl: URL) async -> OWSURLSessionProtocol {
        requestedCdnBaseUrls.append(baseUrl)
        return mockCDNUrlSessionBuilder?(cdnNumber) ?? BaseOWSURLSessionMock(
            endpoint: OWSURLSessionEndpoint(
                baseUrl: baseUrl,
                frontingInfo: nil,
                securityPolicy: .systemDefault,
                extraHeaders: [:],
            ),
            configuration: .default,
        )
    }
}

#endif
