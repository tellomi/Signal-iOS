//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
public import LibSignalClient

extension Notification.Name {
    public static let isCensorshipCircumventionActiveDidChange = Notification.Name("NSNotificationNameIsCensorshipCircumventionActiveDidChange")
}

public class OWSSignalService: OWSSignalServiceProtocol {
    private let keyValueStore = KeyValueStore(collection: "kTSStorageManager_OWSSignalService")
    /// Tellomi（#1056 第三刀）：`Net` 从 provider 现取，不存（切区时换掉的旧实例要放得掉）。
    private let netProvider: TellomiNetProvider?
    private var libsignalNet: Net? { netProvider?.current }

    @Atomic public private(set) var isCensorshipCircumventionActive: Bool = false {
        didSet {
            guard isCensorshipCircumventionActive != oldValue else {
                return
            }

            // Update libsignal's Net instance first, so that connections can be recreated by notification observers.
            libsignalNet?.setCensorshipCircumventionEnabled(isCensorshipCircumventionActive)

            NotificationCenter.default.postOnMainThread(
                name: .isCensorshipCircumventionActiveDidChange,
                object: nil,
                userInfo: nil,
            )
        }
    }

    @Atomic public private(set) var hasCensoredPhoneNumber: Bool = false

    private let isCensorshipCircumventionManuallyActivatedLock = UnfairLock()

    public var isCensorshipCircumventionManuallyActivated: Bool {
        get {
            isCensorshipCircumventionManuallyActivatedLock.withLock {
                readIsCensorshipCircumventionManuallyActivated()
            }
        }
        set {
            isCensorshipCircumventionManuallyActivatedLock.withLock {
                writeIsCensorshipCircumventionManuallyActivated(newValue)
            }
            updateIsCensorshipCircumventionActive()
        }
    }

    private let isCensorshipCircumventionManuallyDisabledLock = UnfairLock()

    public var isCensorshipCircumventionManuallyDisabled: Bool {
        get {
            isCensorshipCircumventionManuallyDisabledLock.withLock {
                readIsCensorshipCircumventionManuallyDisabled()
            }
        }
        set {
            isCensorshipCircumventionManuallyDisabledLock.withLock {
                writeIsCensorshipCircumventionManuallyDisabled(newValue)
            }
            updateIsCensorshipCircumventionActive()
        }
    }

    private let manualCensorshipCircumventionCountryCodeLock = UnfairLock()

    public var manualCensorshipCircumventionCountryCode: String? {
        get {
            manualCensorshipCircumventionCountryCodeLock.withLock {
                readCensorshipCircumventionCountryCode()
            }
        }
        set {
            manualCensorshipCircumventionCountryCodeLock.withLock {
                writeManualCensorshipCircumventionCountryCode(newValue)
            }
        }
    }

    // Tellomi（#1025）：上游在这里把「规避模式」翻译成一份域名前置配置
    // （CensorshipConfigurationParams → OWSCensorshipConfiguration），结果是把请求前置到 Google、
    // Host 头填 Signal 的 reflector、并钉死 Google 的证书链——也就是一按下设置里那个开关，
    // 客户端就改去连 Signal 的基础设施。整段连同下面 buildUrlEndpoint 里的前置分支一起删了。
    //
    // 现在规避模式**继续用我们自己的端点**，只是 isCensorshipCircumventionActive 这个标记还在，
    // 依赖它的地方（设置项、OWSChatConnection 的取数策略）行为不变。
    // 与 Android 的 c0b20cf2 是同一个决定：留标记、不留上游的主机。

    public func buildUrlEndpoint(for signalServiceInfo: SignalServiceInfo) -> OWSURLSessionEndpoint {
        return buildUrlEndpoint(
            baseUrl: signalServiceInfo.baseUrl,
            shouldUseSignalCertificate: signalServiceInfo.shouldUseSignalCertificate,
        )
    }

    private func buildUrlEndpoint(
        baseUrl: URL,
        shouldUseSignalCertificate: Bool,
    ) -> OWSURLSessionEndpoint {
        let securityPolicy: HttpSecurityPolicy
        if shouldUseSignalCertificate {
            securityPolicy = OWSURLSession.signalServiceSecurityPolicy
        } else {
            securityPolicy = OWSURLSession.defaultSecurityPolicy
        }
        return OWSURLSessionEndpoint(
            baseUrl: baseUrl,
            frontingInfo: nil,
            securityPolicy: securityPolicy,
            extraHeaders: [:],
        )
    }

    public func buildUrlSession(
        for signalServiceInfo: SignalServiceInfo,
        endpoint: OWSURLSessionEndpoint,
        configuration: URLSessionConfiguration?,
    ) -> OWSURLSessionProtocol {
        return buildUrlSession(
            endpoint: endpoint,
            configuration: configuration,
            assumesHTTP3Capable: signalServiceInfo.assumesHTTP3Capable,
            shouldHandleRemoteDeprecation: signalServiceInfo.shouldHandleRemoteDeprecation,
            onFailureCallback: nil,
        )
    }

    private func buildUrlSession(
        endpoint: OWSURLSessionEndpoint,
        configuration: URLSessionConfiguration?,
        assumesHTTP3Capable: Bool,
        shouldHandleRemoteDeprecation: Bool,
        onFailureCallback: ((any Error) -> Void)?,
    ) -> OWSURLSessionProtocol {
        let urlSession = OWSURLSession(
            endpoint: endpoint,
            configuration: configuration ?? OWSURLSession.defaultConfigurationWithoutCaching,
            canUseSignalProxy: endpoint.frontingInfo == nil,
            onFailureCallback: onFailureCallback,
        )
        urlSession.assumesHTTP3Capable = assumesHTTP3Capable
        urlSession.shouldHandleRemoteDeprecation = shouldHandleRemoteDeprecation
        return urlSession
    }

    // MARK: - CDN

    private actor CDNSessionCache {
        // Tellomi（#1025）：上游这个 key 里还有一个规避配置参数，为的是规避开关/国家变化时
        // 换一个新会话去重新随机 SNI 头。前置整套删掉之后没有 SNI 头可换，key 只按 CDN 编号即可。
        // Tellomi（#1056 第三刀）：再加上会话的地址。切区后按当前区解析出来的地址变了，自然落到新 key、建新会话；
        // 旧区的会话留在缓存里，给钉住旧区的在途上传用，所以切区时不用 reset（每个区最多 3 个会话）。
        struct Key: Hashable {
            let cdnNumber: UInt32
            let baseUrl: String
        }

        private var cache = [Key: OWSURLSessionProtocol]()

        func getOrBuildSession(
            key: Key,
            buildFn: () -> OWSURLSessionProtocol,
        ) -> OWSURLSessionProtocol {
            if let cached = cache[key] {
                return cached
            }
            let session = buildFn()
            cache[key] = session
            return session
        }

        func invalidate(key: Key) {
            cache[key] = nil
        }

        func reset() {
            cache.removeAll()
        }
    }

    private let cdnSessionCache = CDNSessionCache()

    public func sharedUrlSessionForCdn(cdnNumber: UInt32) async -> OWSURLSessionProtocol {
        // Tellomi（#1056 第三刀）：用的时候按本进程生效区解析出地址，再按地址查缓存
        await sharedUrlSessionForCdn(cdnNumber: cdnNumber, baseUrl: Self.cdnBaseUrl(cdnNumber: cdnNumber))
    }

    /// 生效区里这个 CDN 的地址。
    static func cdnBaseUrl(cdnNumber: UInt32) -> URL {
        switch cdnNumber {
        case 0:
            return URL(string: TSConstants.textSecureCDN0ServerURL)!
        case 2:
            return URL(string: TSConstants.textSecureCDN2ServerURL)!
        case 3:
            return URL(string: TSConstants.textSecureCDN3ServerURL)!
        default:
            owsFailDebug("Unrecognized CDN number configuration requested: \(cdnNumber)")
            // Fallback to cdn2
            return URL(string: TSConstants.textSecureCDN2ServerURL)!
        }
    }

    /// 指定地址的 CDN 会话（#1056 第三刀：钉住开始时那个区的在途上传用这一个）。
    public func sharedUrlSessionForCdn(cdnNumber: UInt32, baseUrl: URL) async -> OWSURLSessionProtocol {
        let cacheKey = CDNSessionCache.Key(cdnNumber: cdnNumber, baseUrl: baseUrl.absoluteString)
        return await cdnSessionCache.getOrBuildSession(
            key: cacheKey,
            buildFn: {
                let urlSessionConfiguration = OWSURLSession.defaultConfigurationWithoutCaching
                urlSessionConfiguration.timeoutIntervalForRequest = 600

                return self.buildUrlSession(
                    endpoint: self.buildUrlEndpoint(
                        baseUrl: baseUrl,
                        shouldUseSignalCertificate: true,
                    ),
                    configuration: urlSessionConfiguration,
                    // Optimistically attempt HTTP/3 (QUIC) for CDN requests.
                    // CDN endpoints (Cloudflare) advertise h3 via Alt-Svc, but
                    // ephemeral sessions don't persist the Alt-Svc cache. This
                    // enables QUIC racing from the first request.
                    assumesHTTP3Capable: true,
                    shouldHandleRemoteDeprecation: false,
                    onFailureCallback: { [weak self] error in
                        Task {
                            if error.isNetworkFailure {
                                // Invalidate the cache on any network failure so
                                // that next time we create a new session.
                                // （Tellomi #1025：上游这里说的是「重新随机 SNI 头」，
                                //   前置删掉之后没有 SNI 头了，但失败后换新会话本身仍然有意义。）
                                await self?.cdnSessionCache.invalidate(key: cacheKey)
                            }
                        }
                    },
                )
            },
        )
    }

    // MARK: - Internal Implementation

    public init(netProvider: TellomiNetProvider?) {
        self.netProvider = netProvider
        observeNotifications()
    }

    // MARK: Setup

    public func warmCaches() {
        updateHasCensoredPhoneNumber()
    }

    private func observeNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(registrationStateDidChange(_:)),
            name: .registrationStateDidChange,
            object: nil,
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(localNumberDidChange(_:)),
            name: .localNumberDidChange,
            object: nil,
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(isSignalProxyReadyDidChange),
            name: .isSignalProxyReadyDidChange,
            object: nil,
        )
    }

    private func updateHasCensoredPhoneNumber() {
        updateHasCensoredPhoneNumber(DependenciesBridge.shared.tsAccountManager.localIdentifiersWithMaybeSneakyTransaction?.phoneNumber)
    }

    public func updateHasCensoredPhoneNumberDuringProvisioning(_ e164: E164) {
        updateHasCensoredPhoneNumber(e164.stringValue)
    }

    public func resetHasCensoredPhoneNumberFromProvisioning() {
        self.hasCensoredPhoneNumber = false
        updateIsCensorshipCircumventionActive()
    }

    private func updateHasCensoredPhoneNumber(_ localNumber: String?) {
        if let localNumber {
            self.hasCensoredPhoneNumber = OWSCensorshipConfiguration.isCensored(e164: localNumber)
        } else {
            self.hasCensoredPhoneNumber = false
        }

        updateIsCensorshipCircumventionActive()
    }

    private func updateIsCensorshipCircumventionActive() {
        if SignalProxy.isEnabled {
            self.isCensorshipCircumventionActive = false
        } else if self.isCensorshipCircumventionManuallyDisabled {
            self.isCensorshipCircumventionActive = false
        } else if self.isCensorshipCircumventionManuallyActivated {
            self.isCensorshipCircumventionActive = true
        } else if self.hasCensoredPhoneNumber {
            self.isCensorshipCircumventionActive = true
        } else {
            self.isCensorshipCircumventionActive = false
        }
    }

    // MARK: - Database operations

    private func readIsCensorshipCircumventionManuallyActivated() -> Bool {
        return SSKEnvironment.shared.databaseStorageRef.read { transaction in
            return self.keyValueStore.getBool(
                Constants.isCensorshipCircumventionManuallyActivatedKey,
                defaultValue: false,
                transaction: transaction,
            )
        }
    }

    private func writeIsCensorshipCircumventionManuallyActivated(_ value: Bool) {
        SSKEnvironment.shared.databaseStorageRef.write { transaction in
            self.keyValueStore.setBool(
                value,
                key: Constants.isCensorshipCircumventionManuallyActivatedKey,
                transaction: transaction,
            )
        }
    }

    private func readIsCensorshipCircumventionManuallyDisabled() -> Bool {
        return SSKEnvironment.shared.databaseStorageRef.read { transaction in
            return self.keyValueStore.getBool(
                Constants.isCensorshipCircumventionManuallyDisabledKey,
                defaultValue: false,
                transaction: transaction,
            )
        }
    }

    private func writeIsCensorshipCircumventionManuallyDisabled(_ value: Bool) {
        SSKEnvironment.shared.databaseStorageRef.write { transaction in
            self.keyValueStore.setBool(
                value,
                key: Constants.isCensorshipCircumventionManuallyDisabledKey,
                transaction: transaction,
            )
        }
    }

    private func readCensorshipCircumventionCountryCode() -> String? {
        return SSKEnvironment.shared.databaseStorageRef.read { transaction in
            return self.keyValueStore.getString(
                Constants.manualCensorshipCircumventionCountryCodeKey,
                transaction: transaction,
            )
        }
    }

    private func writeManualCensorshipCircumventionCountryCode(_ value: String?) {
        SSKEnvironment.shared.databaseStorageRef.write { transaction in
            self.keyValueStore.setString(
                value,
                key: Constants.manualCensorshipCircumventionCountryCodeKey,
                transaction: transaction,
            )
        }
    }

    // MARK: - Events

    @objc
    private func registrationStateDidChange(_ notification: NSNotification) {
        self.updateHasCensoredPhoneNumber()
    }

    @objc
    private func localNumberDidChange(_ notification: NSNotification) {
        self.updateHasCensoredPhoneNumber()
    }

    @objc
    private func isSignalProxyReadyDidChange() {
        self.updateIsCensorshipCircumventionActive()
        Task {
            await cdnSessionCache.reset()
        }
    }

    // MARK: - Constants

    private enum Constants {
        static let isCensorshipCircumventionManuallyActivatedKey = "kTSStorageManager_isCensorshipCircumventionManuallyActivated"
        static let isCensorshipCircumventionManuallyDisabledKey = "kTSStorageManager_isCensorshipCircumventionManuallyDisabled"
        static let manualCensorshipCircumventionCountryCodeKey = "kTSStorageManager_ManualCensorshipCircumventionCountryCode"
    }
}
