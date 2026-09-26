//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import GRDB
public import LibSignalClient

public final class KeyTransparencyManager {
    private static let logger = PrefixedLogger(prefix: "[KT]")
    private var logger: PrefixedLogger { Self.logger }

    private let apiClient: KeyTransparencyApiClient
    private let dateProvider: DateProvider
    private let db: DB
    private let identityManager: OWSIdentityManager
    private let isConservativeSelfCheck: Bool
    private let keyTransparencyStore: KeyTransparencyStore
    private let localUsernameManager: LocalUsernameManager
    private let messageProcessor: Shims.MessageProcessor
    private let recipientDatabaseTable: RecipientDatabaseTable
    private let storageServiceManager: StorageServiceManager
    private let tsAccountManager: TSAccountManager
    private let udManager: OWSUDManager

    private let taskQueue: KeyedConcurrentTaskQueue<Aci>

    init(
        apiClient: KeyTransparencyApiClient,
        dateProvider: @escaping DateProvider,
        db: DB,
        identityManager: OWSIdentityManager,
        isConservativeSelfCheck: Bool,
        keyTransparencyStore: KeyTransparencyStore,
        localUsernameManager: LocalUsernameManager,
        messageProcessor: Shims.MessageProcessor,
        recipientDatabaseTable: RecipientDatabaseTable,
        storageServiceManager: StorageServiceManager,
        tsAccountManager: TSAccountManager,
        udManager: OWSUDManager,
    ) {
        self.apiClient = apiClient
        self.dateProvider = dateProvider
        self.db = db
        self.identityManager = identityManager
        self.isConservativeSelfCheck = isConservativeSelfCheck
        self.keyTransparencyStore = keyTransparencyStore
        self.localUsernameManager = localUsernameManager
        self.messageProcessor = messageProcessor
        self.recipientDatabaseTable = recipientDatabaseTable
        self.storageServiceManager = storageServiceManager
        self.tsAccountManager = tsAccountManager
        self.udManager = udManager

        self.taskQueue = KeyedConcurrentTaskQueue(concurrentLimitPerKey: 1)
    }

    // MARK: Opt-out

    public func isEnabled(tx: DBReadTransaction) -> Bool {
        return keyTransparencyStore.isEnabled(tx: tx)
    }

    public func setIsEnabled(
        _ value: Bool,
        updateStorageService: Bool,
        tx: DBWriteTransaction,
    ) {
        logger.info("\(value)")
        keyTransparencyStore.setIsEnabled(value, tx: tx)

        if updateStorageService {
            tx.addSyncCompletion { [self] in
                storageServiceManager.recordPendingLocalAccountUpdates()
            }
        }
    }

    // MARK: - Key Transparency Checks

    /// Parameters required to do a Key Transparency check.
    public struct CheckParams {
        fileprivate let aciInfo: KeyTransparency.AciInfo
        fileprivate let e164Info: KeyTransparency.E164Info?
        fileprivate let username: Username?
        fileprivate let localIdentifiers: LocalIdentifiers

        fileprivate var isLocalUser: Bool {
            localIdentifiers.contains(serviceId: aciInfo.aci)
        }
    }

    /// Prepare to perform a Key Transparency check for a contact.
    /// - Important
    /// Must not be called for the local user. See `prepareAndPerformSelfCheck`.
    /// - Returns
    /// Params required for the KT check, or `nil` if a check cannot be
    /// performed.
    public func prepareCheck(
        aci: Aci,
        localIdentifiers: LocalIdentifiers,
        tx: DBReadTransaction,
    ) -> CheckParams? {
        let logger = logger.suffixed(with: "[\(aci)]")
        logger.info("")

        if localIdentifiers.contains(serviceId: aci) {
            logger.warn("ACI is local user.")
            return nil
        }

        if !keyTransparencyStore.isEnabled(tx: tx) {
            logger.warn("Is opted out.")
            return nil
        }

        let aciInfo: KeyTransparency.AciInfo
        if let identityKey = try? identityManager.identityKey(for: aci, tx: tx) {
            aciInfo = KeyTransparency.AciInfo(
                aci: aci,
                identityKey: identityKey,
            )
        } else {
            logger.warn("Missing AciInfo.")
            return nil
        }

        let e164Info: KeyTransparency.E164Info
        if
            let recipient = recipientDatabaseTable.fetchRecipient(
                serviceId: aci,
                transaction: tx,
            ),
            let e164 = recipient.phoneNumber?.stringValue,
            let uak = udManager.udAccessKey(for: aci, tx: tx)
        {
            e164Info = KeyTransparency.E164Info(
                e164: e164,
                unidentifiedAccessKey: uak.keyData,
            )
        } else {
            logger.warn("Missing E164Info.")
            return nil
        }

        // We don't currently use the username when checking other users.
        let username: Username? = nil

        return CheckParams(
            aciInfo: aciInfo,
            e164Info: e164Info,
            username: username,
            localIdentifiers: localIdentifiers,
        )
    }

    /// Perform a Key Transparency check with the given validated parameters.
    ///
    /// Errors are retried internally. Throwing indicates a non-transient
    /// failure.
    public func performCheck(params: CheckParams) async throws {
        try await taskQueue.runWithThrowingTask(forKey: params.aciInfo.aci) {
            let logger = logger.suffixed(with: "[\(params.aciInfo.aci)]")

            do {
                // We want to retry network errors indefinitely, as we don't
                // want them to suggest that KT has failed.
                try await Retry.performWithBackoff(
                    maxAttempts: .max,
                    preferredBackoffBlock: { error -> TimeInterval? in
                        switch error {
                        case SignalError.rateLimitedError(let retryAfter, message: _):
                            return retryAfter
                        default:
                            return nil
                        }
                    },
                    isRetryable: { error in
                        switch error {
                        case SignalError.rateLimitedError: true
                        // isRetryable covers network errors.
                        case _ where error.isRetryable: true
                        default: false
                        }
                    },
                    block: {
                        try await _performCheck(params: params, logger: logger)
                    },
                )

                logger.info("Success!")
            } catch {
                logger.warn("Failure! \(error)")
                throw error
            }
        }
    }

    private func _performCheck(
        params: CheckParams,
        logger: PrefixedLogger,
    ) async throws {
        if params.isLocalUser {
            let isDiscoverable = db.read { tx in
                return tsAccountManager.phoneNumberDiscoverability(tx: tx).orDefault.isDiscoverable
            }
            logger.info("Checking for self.")
            try await apiClient.check(
                for: .self(isE164Discoverable: isDiscoverable),
                aciInfo: params.aciInfo,
                e164Info: params.e164Info,
                usernameHash: params.username?.hash,
            )
        } else {
            let selfCheckState = db.read { tx in
                return keyTransparencyStore.selfCheckState(tx: tx)
            }

            // Require a self-check to succeed before checking others.
            switch selfCheckState {
            case nil:
                logger.info("Running KT self-check as prerequisite!")
                try await prepareAndPerformSelfCheck(localIdentifiers: params.localIdentifiers)
            case .succeeded:
                break
            case .failedOnce, .failedRepeatedly, .failedRepeatedlyAndWarned:
                throw OWSGenericError("Cannot check other with failed self-check.")
            }

            logger.info("Checking for other.")
            try await apiClient.check(
                for: .contact,
                aciInfo: params.aciInfo,
                e164Info: params.e164Info,
                usernameHash: nil,
            )
        }
    }

    // MARK: - Self-check

    /// When the value of an `AccountDataField` identifier for the local user
    /// changes, we need to inform LibSignal so it can update internal state.
    /// Use `Cron` to periodically perform a Key Transparency validation on the
    /// local user.
    public func registerSelfCheckForCron(cron: Cron) {
        cron.scheduleFrequently(
            mustBeRegistered: true,
            mustBeConnected: true,
            isRetryable: { _ in
                // This manager retries internally.
                return false
            },
            operation: { [self] () async throws -> Void in
                let isEnabled: Bool
                let isTimeForSelfCheck: Bool
                let registeredState: RegisteredState?
                (
                    isEnabled,
                    isTimeForSelfCheck,
                    registeredState,
                ) = db.read { tx in
                    return (
                        keyTransparencyStore.isEnabled(tx: tx),
                        keyTransparencyStore.getIsTimeForSelfCheckCronJob(now: dateProvider(), tx: tx),
                        try? tsAccountManager.registeredState(tx: tx),
                    )
                }

                // Tellomi：上游这里三个条件一起静默 return，于是「KT 已关掉」在日志里
                // 没有任何正面痕迹，只能靠「搜不到 KT 请求」反证。那个反证其实**是成立的**
                // （`rust/net/chat/src/ws.rs:139/:152` 会以 INFO/WARN 打出
                // `[kt ….] GET /v1/key-transparency/distinguished?`，红控制实测：
                // 开着 184 行命中 8 次、关着 1466 行命中 0 次），但缺席判据读起来总要多绕一圈，
                // 而且容易被 `keytrans` 这种会命中建表迁移日志的关键词带偏。
                // 拆出 isEnabled 单独打一行，把它变成正面断言。
                guard isEnabled else {
                    logger.info("Skipping KT self-check: opted out.")
                    return
                }

                guard
                    isTimeForSelfCheck,
                    let registeredState
                else {
                    return
                }

                logger.info("Running KT self-check for Cron!")
                try await prepareAndPerformSelfCheck(localIdentifiers: registeredState.localIdentifiers)
            },
        )
    }

    /// Perform a one-off self-check on demand, e.g. when triggered manually
    /// from Internal Settings rather than by the scheduled `Cron` job.
    public func performSelfCheckOnDemand() async throws {
        let registeredState = try tsAccountManager.registeredStateWithMaybeSneakyTransaction()
        logger.info("Running KT self-check on-demand!")
        try await prepareAndPerformSelfCheck(localIdentifiers: registeredState.localIdentifiers)
    }

    private enum PrepareSelfCheckResult {
        case success(CheckParams)
        case selfCheckUnavailable
        case failure(OWSAssertionError)
    }

    private func prepareSelfCheck(
        localIdentifiers: LocalIdentifiers,
        tx: DBReadTransaction,
    ) -> PrepareSelfCheckResult {
        let logger = logger.suffixed(with: "[self]")
        logger.info("")

        let aciInfo: KeyTransparency.AciInfo
        if let localIdentityKey = identityManager.identityKeyPair(for: .aci, tx: tx) {
            aciInfo = KeyTransparency.AciInfo(
                aci: localIdentifiers.aci,
                identityKey: localIdentityKey.identityKeyPair.identityKey,
            )
        } else {
            return .failure(OWSAssertionError("Missing AciInfo.", logger: logger))
        }

        let e164Info: KeyTransparency.E164Info?
        if let uak = udManager.udAccessKey(for: localIdentifiers.aci, tx: tx) {
            if tsAccountManager.phoneNumberDiscoverability(tx: tx).orDefault.isDiscoverable {
                e164Info = KeyTransparency.E164Info(
                    e164: localIdentifiers.phoneNumber,
                    unidentifiedAccessKey: uak.keyData,
                )
            } else {
                // If discoverability is disabled, we still want to do a
                // self-check but won't be able to self-check our E164.
                e164Info = nil
            }
        } else {
            return .failure(OWSAssertionError("Missing E164Info.", logger: logger))
        }

        // Skip self-check if our username is corrupted. We don't want to fail
        // the self-check artificially, but we're unlikely to succeed if we
        // attempt. Since username corruption shows a warning banner, hopefully
        // the user resolves it before our next self-check.
        var username: Username?
        switch localUsernameManager.usernameState(tx: tx) {
        case .unset:
            username = nil
        case .available(let _username, _), .linkCorrupted(let _username):
            do {
                username = try Username(_username)
            } catch {
                logger.warn("Failed to hash local username; self-check unavailable. \(error)")
                return .selfCheckUnavailable
            }
        case .usernameAndLinkCorrupted:
            logger.warn("Local username corrupted; self-check unavailable.")
            return .selfCheckUnavailable
        }

        // We can't self-check our own username until all our devices support
        // UsernameChangeSyncMessage.
        if !keyTransparencyStore.isUsernameChangeSyncMessageCapable(tx: tx) {
            username = nil
        }

        return .success(CheckParams(
            aciInfo: aciInfo,
            e164Info: e164Info,
            username: username,
            localIdentifiers: localIdentifiers,
        ))
    }

    private func prepareAndPerformSelfCheck(
        localIdentifiers: LocalIdentifiers,
    ) async throws {
        do {
            // Self-check also depends on UsernameChangeSyncMessages, so best-
            // effort make sure we've drained our message queue.
            try? await messageProcessor.waitForFetchingAndProcessing()

            // Self-check depends on state that lives in Storage Service (i.e.,
            // our username), so best-effort make sure we're up-to-date.
            try? await storageServiceManager.waitForPendingRestores()

            let prepareSelfCheckResult = db.read { tx in
                return prepareSelfCheck(
                    localIdentifiers: localIdentifiers,
                    tx: tx,
                )
            }

            let selfCheckParams: CheckParams
            switch prepareSelfCheckResult {
            case .success(let _selfCheckParams):
                selfCheckParams = _selfCheckParams
            case .selfCheckUnavailable:
                // If self-check is unavailable, punt for now and schedule
                // another self-check for a day from now. Hopefully by then
                // self-check is available again.
                logger.info("Self-check unavailable; deferring to next Cron.")
                await db.awaitableWrite { tx in
                    keyTransparencyStore.setSelfCheckCronJobCompletedAt(
                        now: dateProvider(),
                        specialIntervalTillNextCron: .day,
                        tx: tx,
                    )
                }
                return
            case .failure(let assertionError):
                throw assertionError
            }

            logger.info("Performing self-check.")
            try await performCheck(params: selfCheckParams)
            logger.info("Self-check success.")

            await db.awaitableWrite { tx in
                keyTransparencyStore.setSelfCheckState(.succeeded, tx: tx)
                keyTransparencyStore.setSelfCheckCronJobCompletedAt(
                    now: dateProvider(),
                    specialIntervalTillNextCron: nil,
                    tx: tx,
                )
            }
        } catch let error as CancellationError {
            throw error
        } catch {
            await db.awaitableWrite { tx in
                recordSelfCheckFailure(tx: tx)
            }
            throw error
        }
    }

    private func recordSelfCheckFailure(tx: DBWriteTransaction) {
        let specialIntervalTillNextCron: TimeInterval?
        let newSelfCheckState: KeyTransparencyStore.SelfCheckState?

        switch keyTransparencyStore.selfCheckState(tx: tx) {
        case nil, .succeeded:
            logger.warn("Self-check first failure.")
            newSelfCheckState = .failedOnce
            specialIntervalTillNextCron = .day

            // A known failure mode is if a linked device changed something
            // KT-related (e.g., a username) and this device hasn't yet learned
            // about it. Kick off a storage service fetch, to try and make sure
            // we're up to date before our next attempt.
            tx.addSyncCompletion { [self] in
                storageServiceManager.restoreOrCreateManifestIfNecessary(
                    authedDevice: .implicit,
                    masterKeySource: .implicit,
                )
            }

        case .failedOnce:
            logger.warn("Self-check second failure.")
            newSelfCheckState = .failedRepeatedly
            specialIntervalTillNextCron = nil

        case .failedRepeatedly:
            logger.warn("Self-check continued failure.")
            newSelfCheckState = nil
            specialIntervalTillNextCron = nil

        case .failedRepeatedlyAndWarned:
            logger.warn("Self-check continued failure, already warned.")
            newSelfCheckState = if isConservativeSelfCheck {
                // Wipe the fact that we've already warned about these
                // continued failures, so we warn again.
                .failedRepeatedly
            } else {
                nil
            }
            specialIntervalTillNextCron = nil
        }

        if let newSelfCheckState {
            keyTransparencyStore.setSelfCheckState(newSelfCheckState, tx: tx)
        }

        keyTransparencyStore.setSelfCheckCronJobCompletedAt(
            now: dateProvider(),
            specialIntervalTillNextCron: specialIntervalTillNextCron,
            tx: tx,
        )
    }

    /// If an `AccountDataField` value changes for the local user, we want to
    /// inform LibSignal so they can adjust state accordingly.
    public static func handleSelfCheckIdentifierChanged(
        accountDataField: KeyTransparency.AccountDataField,
        localAci: Aci,
        tx: DBWriteTransaction,
        db: DB,
        keyTransparencyStore: KeyTransparencyStore,
    ) {
        let libSignalStore = KeyTransparencyStoreForLibSignal(
            db: db,
            keyTransparencyStore: keyTransparencyStore,
        )

        do {
            try KeyTransparency.resetField(
                accountDataField,
                for: localAci,
                store: libSignalStore,
                context: tx,
            )
        } catch {
            // We should only end up here if there's malformed data.
            owsFailDebug("Failed to reset \(accountDataField) for local user! \(error)")
        }
    }
}

// MARK: - KeyTransparencyStore

public struct KeyTransparencyStore {

    /// Keys for `kvStore`.
    /// - Important
    /// If you're adding a new key here, consider whether it should be wiped
    /// when Key Transparency is disabled. See: `setIsEnabled`.
    private enum KVStoreKeys {
        /// Keys to a `Bool` representing whether or not KT is enabled.
        static let isEnabled = "isEnabled"
        /// Keys to a `SelfCheckState`'s raw value.
        static let selfCheckState = "selfCheckState"
        /// Keys to a `Bool` representing whether or not we should show
        /// first-time education about KT.
        static let shouldShowFirstTimeEducation = "shouldShowFirstTimeEducation"
        /// Keys to a `Bool` representing whether or not our account is "KT
        /// capable", as there are some cross-linked-device communications that
        /// all our devices must support before we can start using KT.
        static let isUsernameChangeSyncMessageCapable = "isUsernameChangeSyncMessageCapable"
        /// Keys to an opaque LibSignalClient blob.
        static let distinguishedTreeHead = "distinguishedTreeHead"
    }

    private let cronStore: CronStore
    private let kvStore: NewKeyValueStore
    private let selfCheckCronInterval: TimeInterval
    /// Tellomi：用户没选过时 KT 开不开，看 `keyTransparencyAvailable`。App 里（`init()`）就是 `TSConstants.shared`；
    /// 单测按用例给——上游用例跑上游档，Tellomi 用例跑没有 KT 服务的档（见 KeyTransparencyManagerTest）。
    private let tsConstants: TSConstantsProtocol

    public init() {
        let selfCheckCronInterval: TimeInterval = if BuildFlags.KeyTransparency.conservativeSelfCheck {
            .day
        } else {
            .week
        }

        self.init(selfCheckCronInterval: selfCheckCronInterval, tsConstants: TSConstants.shared)
    }

    init(selfCheckCronInterval: TimeInterval, tsConstants: TSConstantsProtocol) {
        self.cronStore = CronStore(uniqueKey: .keyTransparencySelfCheck)
        self.kvStore = NewKeyValueStore(collection: "KeyTransparency")
        self.selfCheckCronInterval = selfCheckCronInterval
        self.tsConstants = tsConstants
    }

    // MARK: - Opt-out

    fileprivate func isEnabled(tx: DBReadTransaction) -> Bool {
        // Tellomi：这套部署没有 key transparency 服务（那是独立的一个 key-transparency-server），
        // 服务端对 `/v1/key-transparency/distinguished` 只能回 500，而 libsignal 的 keytrans 客户端
        // 把任何非 200 都当错误 —— 服务端没办法回「未启用」让它停，于是真机日志里几秒一次地重试
        // （owner 2026-09-22 的 iPhone 日志）。所以默认关，形状与 svrEnclaveAvailable / cdsiAvailable
        // 一致；以后真上 KT 把 TSConstants 那个常量翻回 true 即可。用户显式开过的以用户的选择为准。
        let userChoice = kvStore.fetchValue(Bool.self, forKey: KVStoreKeys.isEnabled, tx: tx)
        return userChoice ?? tsConstants.keyTransparencyAvailable
    }

    fileprivate func setIsEnabled(_ isEnabled: Bool, tx: DBWriteTransaction) {
        kvStore.writeValue(isEnabled, forKey: KVStoreKeys.isEnabled, tx: tx)

        if !isEnabled {
            kvStore.removeValue(forKey: KVStoreKeys.distinguishedTreeHead, tx: tx)
            kvStore.removeValue(forKey: KVStoreKeys.selfCheckState, tx: tx)
            cronStore.setMostRecentDate(.distantPast, jitter: 0, tx: tx)
            failIfThrows {
                try KeyTransparencyRecord.deleteAll(tx.database)
            }
        }
    }

    // MARK: - Capability

    /// Do all our devices have the `UsernameChangeSyncMessage` capability?
    public func isUsernameChangeSyncMessageCapable(tx: DBReadTransaction) -> Bool {
        return kvStore.fetchValue(Bool.self, forKey: KVStoreKeys.isUsernameChangeSyncMessageCapable, tx: tx) ?? false
    }

    /// Set that all our devices have the `UsernameChangeSyncMessage` capability.
    public func setIsUsernameChangeSyncMessageCapable(tx: DBWriteTransaction) {
        kvStore.writeValue(true, forKey: KVStoreKeys.isUsernameChangeSyncMessageCapable, tx: tx)
    }

    // MARK: - First-time education

    public func shouldShowFirstTimeEducation(tx: DBReadTransaction) -> Bool {
        return kvStore.fetchValue(Bool.self, forKey: KVStoreKeys.shouldShowFirstTimeEducation, tx: tx) ?? true
    }

    public func setShouldShowFirstTimeEducation(_ value: Bool, tx: DBWriteTransaction) {
        kvStore.writeValue(value, forKey: KVStoreKeys.shouldShowFirstTimeEducation, tx: tx)
    }

    // MARK: - SelfCheckState

    enum SelfCheckState: Int64 {
        case succeeded = 1
        case failedOnce = 2
        case failedRepeatedly = 3
        case failedRepeatedlyAndWarned = 4
    }

    func selfCheckState(tx: DBReadTransaction) -> SelfCheckState? {
        return kvStore.fetchValue(
            Int64.self,
            forKey: KVStoreKeys.selfCheckState,
            tx: tx,
        )
        .map { SelfCheckState(rawValue: $0)! }
    }

    fileprivate func setSelfCheckState(_ state: SelfCheckState?, tx: DBWriteTransaction) {
        kvStore.writeValue(state?.rawValue, forKey: KVStoreKeys.selfCheckState, tx: tx)
    }

    public func shouldWarnSelfCheckFailed(tx: DBReadTransaction) -> Bool {
        switch selfCheckState(tx: tx) {
        case .failedRepeatedly:
            return true
        case nil, .succeeded, .failedOnce, .failedRepeatedlyAndWarned:
            return false
        }
    }

    public func setWarnedSelfCheckFailed(tx: DBWriteTransaction) {
        switch selfCheckState(tx: tx) {
        case .failedRepeatedly:
            setSelfCheckState(.failedRepeatedlyAndWarned, tx: tx)
        case nil, .succeeded, .failedOnce, .failedRepeatedlyAndWarned:
            owsFailDebug("Unexpectedly setting warned, but shouldn't have warned?")
        }
    }

    public func wipeSelfCheckState(
        localAci: Aci?,
        tx: DBWriteTransaction,
    ) {
        setSelfCheckState(nil, tx: tx)

        if let localAci {
            failIfThrows {
                try KeyTransparencyRecord.deleteOne(tx.database, key: localAci.rawUUID)
            }
        }
    }

    // MARK: - Self-check and Cron

    func getIsTimeForSelfCheckCronJob(
        now: Date,
        tx: DBReadTransaction,
    ) -> Bool {
        let mostRecentDate = cronStore.mostRecentDate(tx: tx)
        return now > mostRecentDate.addingTimeInterval(selfCheckCronInterval)
    }

    /// Set that the self-check `Cron` job just completed.
    /// - Parameter specialIntervalTillNextCheck
    /// If non-`nil`, indicates when the next `Cron` job should run. If `nil`,
    /// the next `Cron` job will run at the default interval.
    fileprivate func setSelfCheckCronJobCompletedAt(
        now: Date,
        specialIntervalTillNextCron: TimeInterval?,
        tx: DBWriteTransaction,
    ) {
        var mostRecentDate = now

        // Cron tracks the most-recent date, not the next date. If we want to
        // run at a specific future date, set the most-recent date in the past
        // such that our next check will happen at that future interval.
        if let specialIntervalTillNextCron {
            mostRecentDate.addTimeInterval(-selfCheckCronInterval)
            mostRecentDate.addTimeInterval(specialIntervalTillNextCron)
        }

        cronStore.setMostRecentDate(
            mostRecentDate,
            jitter: (specialIntervalTillNextCron ?? selfCheckCronInterval) / Cron.jitterFactor,
            tx: tx,
        )
    }

    // MARK: - LastDistinguishedTreeHead

    fileprivate func getLastDistinguishedTreeHead(tx: DBReadTransaction) -> Data? {
        return kvStore.fetchValue(Data.self, forKey: KVStoreKeys.distinguishedTreeHead, tx: tx)
    }

    fileprivate func setLastDistinguishedTreeHead(_ blob: Data, tx: DBWriteTransaction) {
        kvStore.writeValue(blob, forKey: KVStoreKeys.distinguishedTreeHead, tx: tx)
    }

    // MARK: - LibSignal blobs

    public func getKeyTransparencyBlob(
        aci: Aci,
        tx: DBReadTransaction,
    ) -> Data? {
        return failIfThrows {
            try KeyTransparencyRecord.fetchOne(tx.database, key: aci.rawUUID)?.libsignalBlob
        }
    }

    public func setKeyTransparencyBlob(
        _ libsignalBlob: Data,
        aci: Aci,
        tx: DBWriteTransaction,
    ) {
        failIfThrows {
            let record = KeyTransparencyRecord(
                aci: aci.rawUUID,
                libsignalBlob: libsignalBlob,
            )

            try record.insert(tx.database)
        }
    }
}

// MARK: - LibSignalClient.KeyTransparency.Store

/// An instance type conforming to `LibSignalClient.KeyTransparency.Store`, used
/// exclusively when calling LibSignal's KT APIs.
struct KeyTransparencyStoreForLibSignal: KeyTransparency.Store {
    let db: DB
    let keyTransparencyStore: KeyTransparencyStore

    func getLastDistinguishedTreeHead() async -> Data? {
        db.read { tx in
            keyTransparencyStore.getLastDistinguishedTreeHead(tx: tx)
        }
    }

    func setLastDistinguishedTreeHead(to blob: Data) async {
        await db.awaitableWrite { tx in
            keyTransparencyStore.setLastDistinguishedTreeHead(blob, tx: tx)
        }
    }

    func getAccountData(for aci: Aci) async -> Data? {
        db.read { tx in
            keyTransparencyStore.getKeyTransparencyBlob(aci: aci, tx: tx)
        }
    }

    func getAccountData(for aci: Aci, context: StoreContext) -> Data? {
        keyTransparencyStore.getKeyTransparencyBlob(aci: aci, tx: context.asTransaction)
    }

    func setAccountData(_ data: Data, for aci: Aci) async {
        await db.awaitableWrite { tx in
            keyTransparencyStore.setKeyTransparencyBlob(data, aci: aci, tx: tx)
        }
    }

    func setAccountData(_ data: Data, for aci: Aci, context: StoreContext) {
        keyTransparencyStore.setKeyTransparencyBlob(data, aci: aci, tx: context.asTransaction)
    }
}

// MARK: - KeyTransparencyRecord

private struct KeyTransparencyRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName: String = "KeyTransparency"

    // Overwrite if inserting a new record with an existing ACI primary key.
    static var persistenceConflictPolicy: PersistenceConflictPolicy {
        return PersistenceConflictPolicy(
            insert: .replace,
            update: .replace,
        )
    }

    let aci: UUID
    let libsignalBlob: Data

    enum CodingKeys: String, CodingKey {
        case aci
        case libsignalBlob
    }
}

// MARK: - Shims

extension KeyTransparencyManager {
    enum Shims {
        typealias MessageProcessor = _KeyTransparencyManager_MessageProcessor_Shim
    }

    enum Wrappers {
        typealias MessageProcessor = _KeyTransparencyManager_MessageProcessor_Wrapper
    }
}

// MARK: MessageProcessor

protocol _KeyTransparencyManager_MessageProcessor_Shim {
    func waitForFetchingAndProcessing() async throws(CancellationError)
}

class _KeyTransparencyManager_MessageProcessor_Wrapper: _KeyTransparencyManager_MessageProcessor_Shim {
    private let messageProcessor: MessageProcessor

    init(_ messageProcessor: MessageProcessor) {
        self.messageProcessor = messageProcessor
    }

    func waitForFetchingAndProcessing() async throws(CancellationError) {
        try await messageProcessor.waitForFetchingAndProcessing()
    }
}
