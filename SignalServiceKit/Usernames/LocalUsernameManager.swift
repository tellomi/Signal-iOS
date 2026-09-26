//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

/// Manages the local username and username link.
public protocol LocalUsernameManager {

    // MARK: Local state

    /// Returns the state of the local username.
    func usernameState(tx: DBReadTransaction) -> Usernames.LocalUsernameState

    /// Sets the local username and username link.
    func setLocalUsername(
        username: String,
        usernameLink: Usernames.UsernameLink,
        tx: DBWriteTransaction,
    )

    /// Sets the local username, and marks that the local username link is
    /// corrupted.
    ///
    /// Corruption indicates that the username link values we have locally may
    /// or do not decrypt the encrypted username stored by the service. This may
    /// occur due to an interrupted "update my username link" request, race
    /// between two devices simultaneously updating our username, and possibly
    /// other reasons.
    func setLocalUsernameWithCorruptedLink(
        username: String,
        tx: DBWriteTransaction,
    )

    /// Sets that the local username and username link are corrupted.
    ///
    /// Corruption indicates that the username value we have locally may or does
    /// not match the hash of our username stored by the service. This may occur
    /// due to an interrupted "update my username" request, race between two
    /// devices simultaneously updating our username, and possibly other
    /// reasons.
    func setLocalUsernameCorrupted(tx: DBWriteTransaction)

    /// Clears the local username and username link, whether they were corrupted
    /// or not.
    func clearLocalUsername(tx: DBWriteTransaction)

    /// Returns the color to be used for the local user's username link QR code.
    func usernameLinkQRCodeColor(tx: DBReadTransaction) -> QRCodeColor

    /// Sets the color to be used for the local user's username link QR code.
    func setUsernameLinkQRCodeColor(
        color: QRCodeColor,
        tx: DBWriteTransaction,
    )

    // MARK: Usernames and the service

    /// Reserve a username from the given set of candidates.
    ///
    /// Tellomi（tellomi/tellomi#1215 第二刀）：带 `chatServiceAuth`，注册资料页用注册拿到的凭证显式认证；
    /// 不带的版本在下面的扩展里，等于传 `.implicit()`（上游原来的行为）。
    func reserveUsername(
        usernameCandidates: Usernames.HashedUsername.GeneratedCandidates,
        chatServiceAuth: ChatServiceAuth,
    ) async -> Usernames.RemoteMutationResult<Usernames.ReservationResult>

    /// Set the local user's username to the given reserved username, on the
    /// service and locally. Note that setting a new username also sets a
    /// corresponding username link.
    func confirmUsername(
        reservedUsername: Usernames.HashedUsername,
        chatServiceAuth: ChatServiceAuth,
    ) async -> Usernames.RemoteMutationResult<Usernames.ConfirmationResult>

    /// Delete the local user's username and username link.
    func deleteUsername() async -> Usernames.RemoteMutationResult<Void>

    // MARK: Username links and the service

    /// Rotate the local user's username link, without modifying their username.
    func rotateUsernameLink() async -> Usernames.RemoteMutationResult<Usernames.UsernameLink>

    /// Update the case of the local user's existing username, as it will be
    /// visibly presented.
    ///
    /// This updates the local store to reflect the new username casing. It also
    /// performs an in-place update of the encrypted username used in the user's
    /// username link without modifying the link handle or entropy. The existing
    /// username link is consequently unaffected, but the username that is
    /// available via the link will reflect the new casing.
    ///
    /// - Important
    /// The new username must case-insensitively match the existing username
    /// when calling this API.
    func updateVisibleCaseOfExistingUsername(
        newUsername: String,
    ) async -> Usernames.RemoteMutationResult<Void>
}

// MARK: -

public extension Usernames {
    static let localUsernameStateChangedNotification = NSNotification.Name(
        "localUsernameStateChanged",
    )

    /// Represents the states that the local user's username and username link
    /// can be in.
    enum LocalUsernameState: Equatable {
        /// The user deliberately has no username nor username link.
        case unset
        /// The user has both a username and username link.
        case available(username: String, usernameLink: UsernameLink)
        /// The user has a username, but something is wrong with the
        /// corresponding username link and it cannot be used.
        case linkCorrupted(username: String)
        /// The user has a username, but something is wrong with it and neither
        /// it nor the corresponding username link can be used.
        case usernameAndLinkCorrupted

        /// Whether the user explicitly does not have a username set.
        public var isExplicitlyUnset: Bool {
            switch self {
            case .unset:
                return true
            case .available, .linkCorrupted, .usernameAndLinkCorrupted:
                return false
            }
        }

        /// The username, if there is one available.
        public var username: String? {
            switch self {
            case let .available(username, _):
                return username
            case let .linkCorrupted(username):
                return username
            case .unset, .usernameAndLinkCorrupted:
                return nil
            }
        }

        /// The username link, if there is one available.
        public var usernameLink: Usernames.UsernameLink? {
            switch self {
            case let .available(_, usernameLink):
                return usernameLink
            case .unset, .linkCorrupted, .usernameAndLinkCorrupted:
                return nil
            }
        }
    }

    /// Errors related to the local user updating remote state pertaining to
    /// their username.
    enum RemoteMutationError: Error {
        case networkError
        case otherError
    }

    typealias RemoteMutationResult<T> = Result<T, RemoteMutationError>

    typealias ReservationResult = ApiClientReservationResult

    enum ConfirmationResult: Equatable {
        case success(
            username: String,
            usernameLink: UsernameLink,
        )
        case rejected
        case rateLimited
    }
}

public extension LocalUsernameManager {
    func reserveUsername(
        usernameCandidates: Usernames.HashedUsername.GeneratedCandidates,
    ) async -> Usernames.RemoteMutationResult<Usernames.ReservationResult> {
        return await reserveUsername(usernameCandidates: usernameCandidates, chatServiceAuth: .implicit())
    }

    func confirmUsername(
        reservedUsername: Usernames.HashedUsername,
    ) async -> Usernames.RemoteMutationResult<Usernames.ConfirmationResult> {
        return await confirmUsername(reservedUsername: reservedUsername, chatServiceAuth: .implicit())
    }
}

// MARK: -

class LocalUsernameManagerImpl: LocalUsernameManager {
    private struct CorruptionStore {
        private enum Constants {
            static let collection = "LocalUsernameCorruption"
            static let usernameKey = "username"
            static let usernameLinkKey = "link"
        }

        private let kvStore: KeyValueStore

        init() {
            kvStore = KeyValueStore(collection: Constants.collection)
        }

        func isUsernameCorrupted(tx: DBReadTransaction) -> Bool {
            return kvStore.getBool(Constants.usernameKey, defaultValue: false, transaction: tx)
        }

        func isUsernameLinkCorrupted(tx: DBReadTransaction) -> Bool {
            return kvStore.getBool(Constants.usernameLinkKey, defaultValue: false, transaction: tx)
        }

        func setUsernameCorrupted(_ value: Bool, tx: DBWriteTransaction) {
            kvStore.setBool(value, key: Constants.usernameKey, transaction: tx)
        }

        func setUsernameLinkCorrupted(_ value: Bool, tx: DBWriteTransaction) {
            kvStore.setBool(value, key: Constants.usernameLinkKey, transaction: tx)
        }
    }

    private struct UsernameStore {
        private enum Constants {
            static let collection = "LocalUsername"
            static let usernameKey = "username"
            static let usernameLinkHandleKey = "linkHandle"
            static let usernameLinkEntropyKey = "linkEntropy"
            static let usernameLinkQRCodeColorKey = "linkColor"
        }

        private let kvStore: KeyValueStore

        init() {
            kvStore = KeyValueStore(collection: Constants.collection)
        }

        func username(tx: DBReadTransaction) -> String? {
            return kvStore.getString(Constants.usernameKey, transaction: tx)
        }

        func usernameLink(tx: DBReadTransaction) -> Usernames.UsernameLink? {
            if
                let linkHandleData = kvStore.getData(Constants.usernameLinkHandleKey, transaction: tx),
                let linkHandle = UUID(data: linkHandleData),
                let linkEntropy = kvStore.getData(Constants.usernameLinkEntropyKey, transaction: tx),
                let link = Usernames.UsernameLink(handle: linkHandle, entropy: linkEntropy)
            {
                return link
            }

            return nil
        }

        func usernameLinkColor(tx: DBReadTransaction) -> QRCodeColor {
            return (try? kvStore.getCodableValue(
                forKey: Constants.usernameLinkQRCodeColorKey,
                transaction: tx,
            )) ?? .unknown
        }

        func setUsername(username: String?, tx: DBWriteTransaction) {
            kvStore.setString(username, key: Constants.usernameKey, transaction: tx)
        }

        func setUsernameLink(usernameLink: Usernames.UsernameLink?, tx: DBWriteTransaction) {
            kvStore.setData(usernameLink?.handle.data, key: Constants.usernameLinkHandleKey, transaction: tx)
            kvStore.setData(usernameLink?.entropy, key: Constants.usernameLinkEntropyKey, transaction: tx)
        }

        func setUsernameLinkColor(color: QRCodeColor, tx: DBWriteTransaction) {
            try? kvStore.setCodable(color, key: Constants.usernameLinkQRCodeColorKey, transaction: tx)
        }
    }

    /// Thrown when ``SSKReachability`` indicates we do not have network access,
    /// and that consequently we will not succeed in a usernames-related
    /// network request.
    ///
    /// Because we mark the username/link as corrupted while mutation requests
    /// are in-flight it's preferable to bail out early if we believe the
    /// request is doomed to fail, rather than unnecessarily leaving the
    /// username/link corrupted when the request fails.
    private struct NoReachabilityError: Error {}

    private let db: any DB
    private let keyTransparencyStore: KeyTransparencyStore
    private let reachabilityManager: SSKReachabilityManager
    private let storageServiceManager: StorageServiceManager
    private let syncMessageSender: UsernameChangeSyncMessageSender
    private let tsAccountManager: TSAccountManager
    private let usernameApiClient: UsernameApiClient
    private let usernameLinkManager: UsernameLinkManager

    private let corruptionStore: CorruptionStore
    private let usernameStore: UsernameStore

    private let maxNetworkRequestRetries: Int

    private var logger: PrefixedLogger { UsernameLogger.shared }

    init(
        db: any DB,
        keyTransparencyStore: KeyTransparencyStore,
        reachabilityManager: SSKReachabilityManager,
        storageServiceManager: StorageServiceManager,
        syncMessageSender: UsernameChangeSyncMessageSender,
        tsAccountManager: TSAccountManager,
        usernameApiClient: UsernameApiClient,
        usernameLinkManager: UsernameLinkManager,
        maxNetworkRequestRetries: Int = 2,
    ) {
        self.db = db
        self.keyTransparencyStore = keyTransparencyStore
        self.reachabilityManager = reachabilityManager
        self.storageServiceManager = storageServiceManager
        self.syncMessageSender = syncMessageSender
        self.tsAccountManager = tsAccountManager
        self.usernameApiClient = usernameApiClient
        self.usernameLinkManager = usernameLinkManager

        corruptionStore = CorruptionStore()
        usernameStore = UsernameStore()

        self.maxNetworkRequestRetries = maxNetworkRequestRetries
    }

    // MARK: - Local state

    func usernameState(
        tx: DBReadTransaction,
    ) -> Usernames.LocalUsernameState {
        if corruptionStore.isUsernameCorrupted(tx: tx) {
            return .usernameAndLinkCorrupted
        } else if let username = usernameStore.username(tx: tx) {
            if
                !corruptionStore.isUsernameLinkCorrupted(tx: tx),
                let usernameLink = usernameStore.usernameLink(tx: tx)
            {
                return .available(username: username, usernameLink: usernameLink)
            }

            return .linkCorrupted(username: username)
        }

        return .unset
    }

    func setLocalUsername(
        username: String,
        usernameLink: Usernames.UsernameLink,
        tx: DBWriteTransaction,
    ) {
        corruptionStore.setUsernameCorrupted(false, tx: tx)
        usernameStore.setUsername(username: username, tx: tx)

        corruptionStore.setUsernameLinkCorrupted(false, tx: tx)
        usernameStore.setUsernameLink(usernameLink: usernameLink, tx: tx)

        tx.addSyncCompletion {
            self.postLocalUsernameStateChangedNotification()
        }
    }

    func setLocalUsernameWithCorruptedLink(
        username: String,
        tx: DBWriteTransaction,
    ) {
        corruptionStore.setUsernameCorrupted(false, tx: tx)
        usernameStore.setUsername(username: username, tx: tx)

        corruptionStore.setUsernameLinkCorrupted(true, tx: tx)

        tx.addSyncCompletion {
            self.postLocalUsernameStateChangedNotification()
        }
    }

    func setLocalUsernameCorrupted(tx: DBWriteTransaction) {
        markUsernameCorrupted(true, tx: tx)
    }

    func clearLocalUsername(tx: DBWriteTransaction) {
        corruptionStore.setUsernameCorrupted(false, tx: tx)
        corruptionStore.setUsernameLinkCorrupted(false, tx: tx)

        usernameStore.setUsername(username: nil, tx: tx)
        usernameStore.setUsernameLink(usernameLink: nil, tx: tx)

        tx.addSyncCompletion {
            self.postLocalUsernameStateChangedNotification()
        }
    }

    func usernameLinkQRCodeColor(
        tx: DBReadTransaction,
    ) -> QRCodeColor {
        return usernameStore.usernameLinkColor(tx: tx)
    }

    func setUsernameLinkQRCodeColor(
        color: QRCodeColor,
        tx: DBWriteTransaction,
    ) {
        usernameStore.setUsernameLinkColor(color: color, tx: tx)
    }

    private func markUsernameCorrupted(_ value: Bool, tx: DBWriteTransaction) {
        corruptionStore.setUsernameCorrupted(value, tx: tx)
        corruptionStore.setUsernameLinkCorrupted(value, tx: tx)

        tx.addSyncCompletion {
            self.postLocalUsernameStateChangedNotification()
        }
    }

    private func markUsernameLinkCorrupted(_ value: Bool, tx: DBWriteTransaction) {
        corruptionStore.setUsernameLinkCorrupted(value, tx: tx)

        tx.addSyncCompletion {
            self.postLocalUsernameStateChangedNotification()
        }
    }

    private func postLocalUsernameStateChangedNotification() {
        NotificationCenter.default.postOnMainThread(
            name: Usernames.localUsernameStateChangedNotification,
            object: nil,
        )
    }

    // MARK: Usernames and the service

    func reserveUsername(
        usernameCandidates: Usernames.HashedUsername.GeneratedCandidates,
        chatServiceAuth: ChatServiceAuth,
    ) async -> Usernames.RemoteMutationResult<Usernames.ReservationResult> {
        guard reachabilityManager.isReachable else {
            logger.warn("Not attempting to reserve username – Reachability indicates we will fail.")
            return .failure(.networkError)
        }

        do {
            let reservationResult = try await makeRequestWithNetworkRetries {
                return try await usernameApiClient.reserveUsernameCandidates(usernameCandidates: usernameCandidates, chatServiceAuth: chatServiceAuth)
            }
            return .success(reservationResult)
        } catch {
            if error.isNetworkFailureOrTimeout {
                return .failure(.networkError)
            }

            return .failure(.otherError)
        }
    }

    /// Confirm the given reserved username, setting it as our username.
    func confirmUsername(
        reservedUsername: Usernames.HashedUsername,
        chatServiceAuth: ChatServiceAuth,
    ) async -> Usernames.RemoteMutationResult<Usernames.ConfirmationResult> {
        guard reachabilityManager.isReachable else {
            logger.warn("Not attempting to confirm username – Reachability indicates we will fail.")
            return .failure(.networkError)
        }

        let linkEntropy: Data
        let linkEncryptedUsername: Data
        do {
            (
                linkEntropy,
                linkEncryptedUsername,
            ) = try self.usernameLinkManager.generateEncryptedUsername(
                username: reservedUsername.usernameString,
                existingEntropy: nil,
            )
        } catch let error {
            UsernameLogger.shared.error("Failed to generate encrypted username! \(error)")
            return .failure(.otherError)
        }

        // Mark as corrupted in case we encounter an unexpected error while
        // confirming. If that happens we can't be sure if our new username was
        // set or not, so we conservatively leave it in the corrupted state.
        // If, however, we get a response we understand (affirmative or
        // negative), we remove the corrupted flag.
        await db.awaitableWrite { tx in
            markUsernameCorrupted(true, tx: tx)
        }

        do {
            let apiClientConfirmationResult = try await makeRequestWithNetworkRetries {
                return try await usernameApiClient.confirmReservedUsername(
                    reservedUsername: reservedUsername,
                    encryptedUsernameForLink: linkEncryptedUsername,
                    chatServiceAuth: chatServiceAuth,
                )
            }
            let confirmationResult = await self.db.awaitableWrite { tx -> Usernames.ConfirmationResult in
                switch apiClientConfirmationResult {
                case let .success(linkHandle):
                    guard
                        let usernameLink = Usernames.UsernameLink(
                            handle: linkHandle,
                            entropy: linkEntropy,
                        )
                    else {
                        owsFail("This link should always be valid - we just generated the entropy ourselves!")
                    }

                    let username = reservedUsername.usernameString

                    self.setLocalUsername(
                        username: username,
                        usernameLink: usernameLink,
                        tx: tx,
                    )

                    // This device changed our username hash, which we need to
                    // communicate out.
                    self.usernameHashDidChangeLocally(tx: tx)

                    // We back up the username and link in StorageService, so
                    // trigger a backup now.
                    self.storageServiceManager.recordPendingLocalAccountUpdates()

                    return .success(
                        username: username,
                        usernameLink: usernameLink,
                    )
                case .rejected:
                    self.markUsernameCorrupted(false, tx: tx)
                    return .rejected
                case .rateLimited:
                    self.markUsernameCorrupted(false, tx: tx)
                    return .rateLimited
                }
            }

            return .success(confirmationResult)
        } catch {
            if error.isNetworkFailureOrTimeout {
                UsernameLogger.shared.error("Network error while confirming username. Username now assumed corrupted!")
                return .failure(.networkError)
            }

            UsernameLogger.shared.error("Unknown error while confirming username. Username now assumed corrupted!")
            return .failure(.otherError)
        }
    }

    func deleteUsername() async -> Usernames.RemoteMutationResult<Void> {
        guard reachabilityManager.isReachable else {
            logger.warn("Not attempting to delete username – Reachability indicates we will fail.")
            return .failure(.networkError)
        }

        // Mark as corrupted in case we encounter an unexpected error while
        // deleting. If that happens we can't be sure if our new username was
        // deleted or not, so we conservatively leave it in the corrupted state.
        // If, however, we get a response, we remove the corrupted flag.
        await db.awaitableWrite { tx in
            markUsernameCorrupted(true, tx: tx)
        }

        do {
            try await makeRequestWithNetworkRetries {
                try await usernameApiClient.deleteCurrentUsername()
            }
            await self.db.awaitableWrite { tx in
                self.clearLocalUsername(tx: tx)

                // Tellomi（ADR-0066 §6.2）：删掉的名字保留期内再设名也算改名，记下时间好在设名前提醒。
                TellomiUsernameHold.recordDeletion(tx: tx)

                // This device changed our username hash, which we need to
                // communicate out.
                self.usernameHashDidChangeLocally(tx: tx)
            }

            // We back up the username and link in StorageService, so
            // trigger a backup now.
            self.storageServiceManager.recordPendingLocalAccountUpdates()

            return .success(())
        } catch {
            if error.isNetworkFailureOrTimeout {
                UsernameLogger.shared.error("Network error while deleting username. Username now assumed corrupted!")
                return .failure(.networkError)
            }

            UsernameLogger.shared.error("Unknown error while deleting username. Username now assumed corrupted!")
            return .failure(.otherError)
        }
    }

    /// Performs necessary side-effects when we locally change our username such
    /// that the username hash has changed.
    private func usernameHashDidChangeLocally(tx: DBWriteTransaction) {
        guard let localAci = tsAccountManager.localIdentifiers(tx: tx)?.aci else {
            return
        }

        // Enqueue a username-change sync message, so our other devices learn
        // about each of our username changes. (If we just relied on Storage
        // Service, multiple quick updates might appear to a linked device as
        // one update.)
        syncMessageSender.addUsernameChangeSyncMessage(tx: tx)

        // Our local username hash has changed, and we should inform
        // LibSignal for KT self-check monitoring.
        KeyTransparencyManager.handleSelfCheckIdentifierChanged(
            accountDataField: .usernameHash,
            localAci: localAci,
            tx: tx,
            db: db,
            keyTransparencyStore: keyTransparencyStore,
        )
    }

    // MARK: Username links and the service

    func rotateUsernameLink() async -> Usernames.RemoteMutationResult<Usernames.UsernameLink> {
        guard reachabilityManager.isReachable else {
            logger.warn("Not attempting to rotate username link – Reachability indicates we will fail.")
            return .failure(.networkError)
        }

        guard
            let (currentUsername, newEntropy, newEncryptedUsername) = await db.awaitableWrite(block: { tx -> (String, Data, Data)? in
                guard let currentUsername = usernameState(tx: tx).username else {
                    owsFailDebug("Tried to rotate link, but missing current username!")
                    return nil
                }

                let newEntropy: Data
                let newEncryptedUsername: Data
                do {
                    (
                        newEntropy,
                        newEncryptedUsername,
                    ) = try self.usernameLinkManager.generateEncryptedUsername(
                        username: currentUsername,
                        existingEntropy: nil,
                    )
                } catch let error {
                    UsernameLogger.shared.error("Failed to generate encrypted username! \(error)")
                    return nil
                }

                // Mark as corrupted in case we encounter an unexpected error while
                // rotating. If that happens we can't be sure if our username link was
                // rotated or not, so we conservatively leave it in the corrupted state.
                // If, however, we get a response, we remove the corrupted flag.
                markUsernameLinkCorrupted(true, tx: tx)

                return (currentUsername, newEntropy, newEncryptedUsername)
            })
        else {
            return .failure(.otherError)
        }

        do {
            let newHandle = try await makeRequestWithNetworkRetries {
                try await usernameApiClient.setUsernameLink(encryptedUsername: newEncryptedUsername, keepLinkHandle: false)
            }

            guard
                let newUsernameLink = Usernames.UsernameLink(
                    handle: newHandle,
                    entropy: newEntropy,
                )
            else {
                owsFail("This link should always be valid - we just generated the entropy ourselves!")
            }

            await self.db.awaitableWrite { tx in
                self.setLocalUsername(
                    username: currentUsername,
                    usernameLink: newUsernameLink,
                    tx: tx,
                )
            }

            // We back up the username and link in StorageService, so
            // trigger a backup now.
            self.storageServiceManager.recordPendingLocalAccountUpdates()

            return .success(newUsernameLink)
        } catch {
            if error.isNetworkFailureOrTimeout {
                UsernameLogger.shared.error("Network error while rotating username link. Username link now assumed corrupted!")
                return .failure(.networkError)
            }

            UsernameLogger.shared.error("Error while rotating username link. Username link now assumed corrupted!")
            return .failure(.otherError)
        }
    }

    func updateVisibleCaseOfExistingUsername(
        newUsername: String,
    ) async -> Usernames.RemoteMutationResult<Void> {
        guard reachabilityManager.isReachable else {
            logger.warn("Not attempting to update visible username case – Reachability indicates we will fail.")
            return .failure(.networkError)
        }

        guard
            let (newEncryptedUsername, currentUsernameLink) = await db.awaitableWrite(block: { tx -> (Data, Usernames.UsernameLink)? in
                let currentUsernameState = usernameState(tx: tx)

                guard
                    let currentUsernameLink = currentUsernameState.usernameLink,
                    let currentUsername = currentUsernameState.username,
                    newUsername.lowercased() == currentUsername.lowercased()
                else {
                    owsFailDebug("Attempting to change username case, but new nickname does not match existing username!")
                    return nil
                }

                let newEncryptedUsername: Data
                do {
                    (_, newEncryptedUsername) = try usernameLinkManager.generateEncryptedUsername(
                        username: newUsername,
                        existingEntropy: currentUsernameLink.entropy,
                    )
                } catch let error {
                    UsernameLogger.shared.error("Failed to generate encrypted username! \(error)")
                    return nil
                }

                // Mark as corrupted in case we encounter an unexpected error while
                // setting the new encrypted username. If that happens we can't be sure
                // if our encrypted username was updated or not, so we conservatively
                // leave it in the corrupted state. If, however, we get a response, we
                // remove the corrupted flag.
                markUsernameLinkCorrupted(true, tx: tx)

                return (newEncryptedUsername, currentUsernameLink)
            })
        else {
            return .failure(.otherError)
        }

        defer {
            // We back up the username and link in StorageService, and in all
            // codepaths we've updated the username, so trigger a backup now.
            storageServiceManager.recordPendingLocalAccountUpdates()
        }

        do {
            let newHandle = try await makeRequestWithNetworkRetries {
                /// Pass `keepLinkHandle = true` here, to ask the service not to
                /// rotate the username link handle. That's key to keeping the
                /// existing link unaffected while updating the case of the
                /// visible username the link points to.
                return try await usernameApiClient.setUsernameLink(encryptedUsername: newEncryptedUsername, keepLinkHandle: true)
            }
            guard currentUsernameLink.handle == newHandle else {
                UsernameLogger.shared.error("Handle received while changing username case did not match existing! Is this a server bug?")
                throw OWSGenericError("")
            }

            await self.db.awaitableWrite { tx in
                self.setLocalUsername(
                    username: newUsername,
                    usernameLink: currentUsernameLink,
                    tx: tx,
                )
            }
            return .success(())
        } catch {
            // Even though we failed to update the link, we can save the new
            // nickname locally. If the user rotates their link to fix the
            // issue, the new link will reflect the updated nickname.
            await self.db.awaitableWrite { tx in
                self.setLocalUsernameWithCorruptedLink(
                    username: newUsername,
                    tx: tx,
                )
            }

            if error.isNetworkFailureOrTimeout {
                UsernameLogger.shared.error("Network error while updating username link for nickname case change. Username updated locally, but link now assumed corrupted!")
                return .failure(.networkError)
            }

            UsernameLogger.shared.error("Unknown error while updating username link for nickname case change. Username updated locally, but link now assumed corrupted!")
            return .failure(.otherError)
        }
    }

    // MARK: - Network retries

    /// Make the request in the given block, with retries.
    ///
    /// Because a failed username mutation request leaves us in a corrupted
    /// state, add retries for network errors to avoid unnecessary corruption
    /// where possible.
    private func makeRequestWithNetworkRetries<T>(requestBlock: () async throws -> T) async throws -> T {
        return try await Retry.performWithBackoff(
            maxAttempts: self.maxNetworkRequestRetries + 1,
            isRetryable: { $0.isNetworkFailureOrTimeout },
            block: requestBlock,
        )
    }

    // MARK: -

    /// Wrapper around `MessageSenderJobQueue`, for tests.
    protocol UsernameChangeSyncMessageSender {
        func addUsernameChangeSyncMessage(tx: DBWriteTransaction)
    }

    struct UsernameChangeSyncMessageSenderImpl: UsernameChangeSyncMessageSender {
        let messageSenderJobQueue: MessageSenderJobQueue
        let threadStore: ThreadStore

        func addUsernameChangeSyncMessage(tx: DBWriteTransaction) {
            guard let localThread = threadStore.getOrCreateLocalThread(tx: tx) else {
                owsFailDebug("Failed to getOrCreateLocalThread!")
                return
            }

            let usernameChangeSyncMessage = UsernameChangeSyncMessage(
                localThread: localThread,
                tx: tx,
            )

            messageSenderJobQueue.add(
                message: .preprepared(transientMessageWithoutAttachments: usernameChangeSyncMessage),
                transaction: tx,
            )
        }
    }
}

// MARK: - Tellomi

/// Tellomi（ADR-0066 §6.2）：删掉的用户名服务端给原主人保留 30 天（server `Accounts.java:883-890`），这期间设**任何**用户名
/// 都算一次改名、开始 30 天冷却。这里记下本账号上一次删掉用户名的时间，设名前据此提醒（与 Android
/// `SignalStore.account.tellomiUsernameDeletedAt`、Desktop `tellomiUsernameDeletedAt` 同一件事）。
/// 只在本机：换机后没有记录，最多少提示一次，服务端照样按保留期开始冷却。
public enum TellomiUsernameHold {
    /// 服务端保留删掉的用户名的天数。
    public static let holdDays = 30

    /// 保存用户名前弹哪种确认框（与 Android `UsernameEditViewModel.saveConfirmation`、Desktop `getUsernameSaveConfirmation`
    /// 同一判法）。只改大小写不走预约、到不了确认这一步，所以这里不用管。
    public enum SaveConfirmation: Equatable {
        /// 首次设名，或删掉已超过保留期：直接设。
        case none
        /// 已有用户名（含修复模式）：原来的换名确认。
        case change
        /// 没有用户名，但保留期内删过一个：服务端也当改名，先提醒。
        case setAfterDelete
    }

    private static let collection = "TellomiUsernameHold"
    private static let deletedAtKey = "deletedAt"

    public static func deletedAt(tx: DBReadTransaction) -> Date? {
        return KeyValueStore(collection: collection).getDate(deletedAtKey, transaction: tx)
    }

    /// 本机删成功时记；合并 AccountRecord 发现名字被别的设备删了也记。同步时刻晚于删除时刻，只会多提示，不会漏。
    public static func recordDeletion(now: Date = Date(), tx: DBWriteTransaction) {
        KeyValueStore(collection: collection).setDate(now, key: deletedAtKey, transaction: tx)
    }

    /// 时钟往回拨（`now` 早于删除时间）仍算在保留期内：多提示，不漏提示。
    public static func isWithinHold(deletedAt: Date?, now: Date) -> Bool {
        guard let deletedAt else {
            return false
        }
        return now.timeIntervalSince(deletedAt) < TimeInterval(holdDays) * .day
    }

    public static func saveConfirmation(hasExistingUsername: Bool, deletedAt: Date?, now: Date) -> SaveConfirmation {
        if hasExistingUsername {
            return .change
        }
        if isWithinHold(deletedAt: deletedAt, now: now) {
            return .setAfterDelete
        }
        return .none
    }
}
