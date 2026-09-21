//
// Copyright 2021 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import CFNetwork
import Foundation
import LibSignalClient

/// This extension sacrifices Dictionary performance in order to ignore http
/// header case and should not be generally used. Since the number of http
/// headers is generally small, this is an acceptable tradeoff for this use case
/// but may not be for other use cases.
private extension Dictionary where Key == String {
    subscript(header header: String) -> Value? {
        get {
            if let key = keys.first(where: { $0.caseInsensitiveCompare(header) == .orderedSame }) {
                return self[key]
            }
            return nil
        }
        set {
            if let key = keys.first(where: { $0.caseInsensitiveCompare(header) == .orderedSame }) {
                self[key] = newValue
            } else {
                self[header] = newValue
            }
        }
    }
}

public class HTTPUtils {
    public static func preprocessMainServiceHTTPError(
        requestUrl: URL,
        responseStatus: Int,
        responseHeaders: HttpHeaders,
        responseData: Data?,
    ) async -> OWSHTTPError {
        let httpError: OWSHTTPError
        if responseStatus == 0 {
            httpError = .networkFailure(.invalidResponseStatus)
        } else {
            httpError = .serviceResponse(.init(
                requestUrl: requestUrl,
                responseStatus: responseStatus,
                responseHeaders: responseHeaders,
                responseData: responseData,
            ))
        }

        await applyHTTPError(httpError)
        return httpError
    }

    public static func applyHTTPError(_ httpError: OWSHTTPError) async {
        if httpError.isNetworkFailureImpl || httpError.isTimeoutImpl {
            OutageDetection.shared.reportConnectionFailure()
        }

        if httpError.responseStatusCode == AppExpiry.appExpiredStatusCode {
            let appExpiry = DependenciesBridge.shared.appExpiry
            let db = DependenciesBridge.shared.db
            await appExpiry.setHasAppExpiredAtCurrentVersion(db: db)
        }
    }

    public static func retryDelayNanoSeconds(_ response: HTTPResponse, defaultRetryTime: TimeInterval = 15) -> UInt64 {
        return (response.headers.retryAfterTimeInterval ?? defaultRetryTime).clampedNanoseconds
    }
}

// MARK: -

public extension Error {
    var httpRetryAfterDate: Date? {
        guard let httpError = self as? OWSHTTPError else {
            return nil
        }

        return httpError.responseHeaders?.retryAfterDate
    }

    var httpResponseData: Data? {
        guard let httpError = self as? OWSHTTPError else {
            return nil
        }

        return httpError.responseBodyData
    }

    var httpStatusCode: Int? {
        guard
            let httpError = self as? OWSHTTPError,
            httpError.responseStatusCode > 0
        else {
            return nil
        }

        return httpError.responseStatusCode
    }

    var httpResponseHeaders: HttpHeaders? {
        guard let error = self as? OWSHTTPError else {
            return nil
        }
        return error.responseHeaders
    }

    var isCancellation: Bool {
        switch self {
        case is CancellationError: true
        case URLError.cancelled: true
        default: false
        }
    }

    /// Does this error represent a transient networking issue?
    ///
    /// a.k.a. "the internet gave up" (see also `isTimeout`)
    var isNetworkFailure: Bool {
        switch self as any Error {
        case URLError.cannotConnectToHost: return true
        case URLError.networkConnectionLost: return true
        case URLError.dnsLookupFailed: return true
        case URLError.notConnectedToInternet: return true
        case URLError.secureConnectionFailed: return true
        case URLError.cannotLoadFromNetwork: return true
        case URLError.cannotFindHost: return true
        case URLError.badURL: return true
        case POSIXError.EPROTO: return true
        case let httpError as OWSHTTPError: return httpError.isNetworkFailureImpl
        case SignalError.chatServiceInactive: return true
        case SignalError.connectionFailed: return true
        case SignalError.connectionInvalidated: return true
        case SignalError.ioError: return true
        case SignalError.possibleCaptiveNetwork: return true
        case SignalError.webSocketError: return true
        case Upload.Error.networkError: return true
        default: return false
        }
    }

    /// Does this error represent a self-induced timeout?
    ///
    /// a.k.a. "we gave up" (see also `isNetworkFailure`)
    var isTimeout: Bool {
        switch self as any Error {
        case URLError.timedOut: return true
        case let httpError as OWSHTTPError: return httpError.isTimeoutImpl
        case GroupsV2Error.timeout: return true
        case PaymentsError.timeout: return true
        case SignalError.connectionTimeoutError: return true
        case SignalError.requestTimeoutError: return true
        case Upload.Error.networkTimeout: return true
        default: return false
        }
    }

    var isNetworkFailureOrTimeout: Bool {
        return isNetworkFailure || isTimeout
    }

    var is5xxServiceResponse: Bool {
        switch self as? OWSHTTPError {
        case .serviceResponse(let serviceResponse):
            return serviceResponse.is5xx
        case nil, .wrappedFailure, .networkFailure:
            return false
        }
    }
}

// MARK: -

@inlinable
public func owsFailDebugUnlessNetworkFailure(
    _ error: Error,
    file: String = #file,
    function: String = #function,
    line: Int = #line,
) {
    if error.isNetworkFailureOrTimeout {
        // Log but otherwise ignore network failures.
        Logger.warn("Error: \(error)", file: file, function: function, line: line)
    } else if error.isServiceUnimplementedOrUnavailable {
        // Tellomi：见 isServiceUnimplementedOrUnavailable 的说明。
        Logger.warn("Service not available in this deployment: \(error)", file: file, function: function, line: line)
    } else {
        owsFailDebug("Error: \(error)", file: file, function: function, line: line)
    }
}

extension Error {
    /// Tellomi：服务端**还没接这个服务**（而不是客户端发错了）。
    ///
    /// 上游的 `owsFailDebugUnlessNetworkFailure` 只放过「网络不通」，其余一律按客户端 bug
    /// 断言掉——在 Debug 构建上就是杀进程。这个前提对上游成立（他们的服务端什么都实现了），
    /// 对我们不成立：香港那套是自建的，很多端点要么没接、要么下发的是上游测试数据。
    ///
    /// 2026-09-22 一天之内在 iPhone 真机上撞了三次，每次都是同一形状：
    /// 捐赠配置解析失败、捐赠页第二层、`GET v2/calling/relays` 返回 503 拨号即杀进程。
    ///
    /// 所以这里只放过「服务端说它没有/不可用」这一类：**5xx** 与 **404 / 501**。
    /// 4xx 里的 400 / 403 / 409 这些「客户端发错了」仍然断言——那正是这条断言的价值，
    /// 我们同样需要它继续抓真正的客户端 bug。等服务端把对应服务补齐，这里不用改回去：
    /// 服务正常返回 200 时本来就走不到这个分支。
    public var isServiceUnimplementedOrUnavailable: Bool {
        guard let httpError = self as? OWSHTTPError else {
            return false
        }
        let code = httpError.responseStatusCode
        return code >= 500 || code == 404
    }
}

@inlinable
public func owsFailBetaUnlessNetworkFailure(
    _ error: Error,
    file: String = #file,
    function: String = #function,
    line: Int = #line,
) {
    if error.isNetworkFailureOrTimeout {
        // Log but otherwise ignore network failures.
        Logger.warn("Error: \(error)", file: file, function: function, line: line)
    } else {
        owsFailBeta("Error: \(error)", file: file, function: function, line: line)
    }
}

// MARK: -

extension HttpHeaders {

    public var retryAfterTimeInterval: TimeInterval? {
        return retryAfterStringValue.flatMap(TimeInterval.init(_:))
    }

    public var retryAfterDate: Date? {
        guard let retryAfterStringValue else {
            return nil
        }

        if let date = Date.ows_parseFromHTTPDateString(retryAfterStringValue) {
            return date
        } else if let date = Date.ows_parseFromISO8601String(retryAfterStringValue) {
            return date
        } else if let retryAfterTimeInterval {
            return Date().addingTimeInterval(retryAfterTimeInterval)
        } else {
            owsAssertDebug(
                CurrentAppContext().isRunningTests,
                "Failed to parse retry-after string: \(String(describing: retryAfterStringValue))",
            )
            return nil
        }
    }

    private var retryAfterStringValue: String? {
        return value(forHeader: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }
}
