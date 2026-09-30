//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// §4.3「本机可达性记录」：一次抓取在**网络层**失败（DNS 失败、TCP 连接超时或被重置、TLS 握手失败；HTTP 状态码不算），
/// 就记下「这个 host 在当前网络不可达」，之后同一 host 的步骤直接跳过、不发请求。
///
/// - **只在内存**：不落盘、不上报，不会变成一份「用户所在网络能访问什么」的记录；
/// - 系统网络变化时（`SSKReachability.owsReachabilityDidChange`）或记下 30 分钟后失效；
/// - 只决定「发不发请求」，结果永远是降级，不是报错。
public final class TellomiLinkReachability: @unchecked Sendable {
    public static let memoLifetime: TimeInterval = 30 * 60

    public static let shared = TellomiLinkReachability(clearsOnNetworkChange: true)

    private let lock = NSLock()
    private var unreachableSince = [String: Date]()
    private let lifetime: TimeInterval
    private let now: @Sendable () -> Date
    private var observer: NSObjectProtocol?
    private let notificationCenter: NotificationCenter

    public init(
        lifetime: TimeInterval = TellomiLinkReachability.memoLifetime,
        now: @escaping @Sendable () -> Date = { Date() },
        clearsOnNetworkChange: Bool = false,
        notificationCenter: NotificationCenter = .default,
    ) {
        self.lifetime = lifetime
        self.now = now
        self.notificationCenter = notificationCenter
        if clearsOnNetworkChange {
            observer = notificationCenter.addObserver(
                forName: SSKReachability.owsReachabilityDidChange,
                object: nil,
                queue: nil,
            ) { [weak self] _ in
                self?.clear()
            }
        }
    }

    deinit {
        if let observer {
            notificationCenter.removeObserver(observer)
        }
    }

    public func isKnownUnreachable(host rawHost: String?) -> Bool {
        guard let host = Self.key(rawHost) else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard let since = unreachableSince[host] else { return false }
        if now().timeIntervalSince(since) >= lifetime {
            unreachableSince[host] = nil
            return false
        }
        return true
    }

    /// 现在记着不可达（还没过期）的 host；发送端把它交给 rust/links，它就不会去请求这些 host。
    public func unreachableHosts() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let current = now()
        unreachableSince = unreachableSince.filter { current.timeIntervalSince($0.value) < lifetime }
        return unreachableSince.keys.sorted()
    }

    public func recordNetworkFailure(host rawHost: String?) {
        guard let host = Self.key(rawHost) else { return }
        lock.lock()
        defer { lock.unlock() }
        unreachableSince[host] = now()
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        unreachableSince.removeAll()
    }

    private static func key(_ host: String?) -> String? {
        return host?.lowercased().nilIfEmpty
    }
}
