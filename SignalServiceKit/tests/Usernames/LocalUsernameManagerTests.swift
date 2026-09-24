//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import SignalRingRTC
import XCTest

@testable import SignalServiceKit

class LocalUsernameManagerTests: XCTestCase {
    private var mockDB: InMemoryDB!
    private var mockReachabilityManager: MockReachabilityManager!
    private var mockStorageServiceManager: MockStorageServiceManager!
    private var mockSyncMessageSender: MockUsernameChangeSyncMessageSender!
    private var mockTSAccountManager: MockTSAccountManager!
    private var mockUsernameApiClient: MockUsernameApiClient!
    private var mockUsernameLinkManager: MockUsernameLinkManager!

    private var localUsernameManager: LocalUsernameManager!

    override func setUp() {
        mockDB = InMemoryDB()

        mockReachabilityManager = MockReachabilityManager()
        mockStorageServiceManager = MockStorageServiceManager()
        mockSyncMessageSender = MockUsernameChangeSyncMessageSender()
        mockTSAccountManager = MockTSAccountManager()
        mockUsernameApiClient = MockUsernameApiClient()
        mockUsernameLinkManager = MockUsernameLinkManager()

        setLocalUsernameManager(maxNetworkRequestRetries: 0)
    }

    private func setLocalUsernameManager(maxNetworkRequestRetries: Int) {
        localUsernameManager = LocalUsernameManagerImpl(
            db: mockDB,
            keyTransparencyStore: KeyTransparencyStore(),
            reachabilityManager: mockReachabilityManager,
            storageServiceManager: mockStorageServiceManager,
            syncMessageSender: mockSyncMessageSender,
            tsAccountManager: mockTSAccountManager,
            usernameApiClient: mockUsernameApiClient,
            usernameLinkManager: mockUsernameLinkManager,
            maxNetworkRequestRetries: maxNetworkRequestRetries,
        )
    }

    override func tearDown() {
        owsPrecondition(mockUsernameApiClient.confirmReservedUsernameMocks.isEmpty)
        owsPrecondition(mockUsernameApiClient.deleteCurrentUsernameMocks.isEmpty)
        owsPrecondition(mockUsernameApiClient.setUsernameLinkMocks.isEmpty)
        XCTAssertNil(mockUsernameLinkManager.entropyToGenerate)
    }

    // MARK: Local state changes

    func testLocalUsernameStateChanges() {
        let linkHandle = UUID()

        XCTAssertEqual(usernameState(), .unset)

        mockDB.write { tx in
            localUsernameManager.setLocalUsername(
                username: "boba-fett",
                usernameLink: .mock(handle: linkHandle),
                tx: tx,
            )
        }

        XCTAssertEqual(
            usernameState(),
            .available(username: "boba-fett", usernameLink: .mock(handle: linkHandle)),
        )

        mockDB.write { tx in
            localUsernameManager.setLocalUsernameWithCorruptedLink(
                username: "boba-fett",
                tx: tx,
            )
        }

        XCTAssertEqual(usernameState(), .linkCorrupted(username: "boba-fett"))

        mockDB.write { tx in
            localUsernameManager.clearLocalUsername(tx: tx)
        }

        XCTAssertEqual(usernameState(), .unset)
    }

    func testUsernameQRCodeColorChanges() {
        func color() -> QRCodeColor {
            return mockDB.read { tx in
                return localUsernameManager.usernameLinkQRCodeColor(tx: tx)
            }
        }

        XCTAssertEqual(color(), .unknown)

        mockDB.write { tx in
            localUsernameManager.setUsernameLinkQRCodeColor(
                color: .olive,
                tx: tx,
            )
        }

        XCTAssertEqual(color(), .olive)
    }

    // MARK: Confirmation

    func testConfirmUsernameHappyPath() async {
        let linkHandle = UUID()
        let username = "boba_fett.42"

        mockUsernameLinkManager.entropyToGenerate = .success(.mockEntropy)
        mockUsernameApiClient.confirmReservedUsernameMocks = [{ _, _, _ in .success(usernameLinkHandle: linkHandle) }]

        XCTAssertEqual(usernameState(), .unset)

        let value = await localUsernameManager.confirmUsername(reservedUsername: .mock(username))

        XCTAssertEqual(
            value,
            .success(.success(username: username, usernameLink: .mock(handle: linkHandle))),
        )
        XCTAssertEqual(
            usernameState(),
            .available(username: username, usernameLink: .mock(handle: linkHandle)),
        )
        XCTAssertTrue(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 1)
    }

    func testConfirmBailsEarlyIfNotReachable() async {
        mockReachabilityManager.isReachable = false

        let stateBeforeConfirm = setUsername(username: "boba_fett.42")

        let value = await localUsernameManager.confirmUsername(reservedUsername: .mock("boba_fett.43"))

        XCTAssertEqual(value, .failure(.networkError))
        XCTAssertEqual(usernameState(), stateBeforeConfirm)
        XCTAssertFalse(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 0)
    }

    func testNoCorruptionIfFailToGenerateLink() async {
        mockUsernameLinkManager.entropyToGenerate = .failure(OWSGenericError("A Sarlacc"))

        let stateBeforeConfirm = setUsername(username: "boba_fett.42")

        let value = await localUsernameManager.confirmUsername(reservedUsername: .mock("boba_fett.43"))

        XCTAssertEqual(value, .failure(.otherError))
        XCTAssertEqual(usernameState(), stateBeforeConfirm)
        XCTAssertFalse(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 0)
    }

    func testCorruptionIfNetworkErrorWhileConfirming() async {
        mockUsernameLinkManager.entropyToGenerate = .success(.mockEntropy)
        mockUsernameApiClient.confirmReservedUsernameMocks = [{ _, _, _ in throw OWSHTTPError.mockNetworkFailure }]

        XCTAssertEqual(usernameState(), .unset)

        let value = await localUsernameManager.confirmUsername(reservedUsername: .mock("boba_fett.42"))

        XCTAssertEqual(value, .failure(.networkError))
        XCTAssertEqual(usernameState(), .usernameAndLinkCorrupted)
        XCTAssertFalse(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 0)
    }

    func testCorruptionIfErrorWhileConfirming() async {
        mockUsernameLinkManager.entropyToGenerate = .success(.mockEntropy)
        mockUsernameApiClient.confirmReservedUsernameMocks = [{ _, _, _ in throw OWSGenericError("") }]

        XCTAssertEqual(usernameState(), .unset)

        let value = await localUsernameManager.confirmUsername(reservedUsername: .mock("boba_fett.42"))

        XCTAssertEqual(value, .failure(.otherError))
        XCTAssertEqual(usernameState(), .usernameAndLinkCorrupted)
        XCTAssertFalse(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 0)
    }

    func testNoCorruptionIfRejectedWhileConfirming() async {
        mockUsernameLinkManager.entropyToGenerate = .success(.mockEntropy)
        mockUsernameApiClient.confirmReservedUsernameMocks = [{ _, _, _ in .rejected }]

        let stateBeforeConfirm = setUsername(username: "boba_fett.42")

        let value = await localUsernameManager.confirmUsername(reservedUsername: .mock("boba_fett.43"))

        XCTAssertEqual(value, .success(.rejected))
        XCTAssertEqual(usernameState(), stateBeforeConfirm)
        XCTAssertFalse(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 0)
    }

    func testNoCorruptionIfRateLimitedWhileConfirming() async {
        mockUsernameLinkManager.entropyToGenerate = .success(.mockEntropy)
        mockUsernameApiClient.confirmReservedUsernameMocks = [{ _, _, _ in .rateLimited }]

        let stateBeforeConfirm = setUsername(username: "boba_fett.42")

        let value = await localUsernameManager.confirmUsername(reservedUsername: .mock("boba_fett.43"))

        XCTAssertEqual(value, .success(.rateLimited))
        XCTAssertEqual(usernameState(), stateBeforeConfirm)
        XCTAssertFalse(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 0)
    }

    func testSuccessfulConfirmationClearsLinkCorruption() async {
        let newHandle = UUID()

        mockUsernameLinkManager.entropyToGenerate = .success(.mockEntropy)
        mockUsernameApiClient.confirmReservedUsernameMocks = [{ _, _, _ in .success(usernameLinkHandle: newHandle) }]

        mockDB.write { tx in
            localUsernameManager.setLocalUsernameWithCorruptedLink(
                username: "boba_fett.42",
                tx: tx,
            )
        }

        XCTAssertEqual(usernameState(), .linkCorrupted(username: "boba_fett.42"))

        let value = await localUsernameManager.confirmUsername(reservedUsername: try! Usernames.HashedUsername(forUsername: "boba_fett.43"))

        let expectedNewLink = Usernames.UsernameLink(handle: newHandle, entropy: .mockEntropy)!

        XCTAssertEqual(
            value,
            .success(.success(username: "boba_fett.43", usernameLink: expectedNewLink)),
        )
        XCTAssertEqual(
            usernameState(),
            .available(username: "boba_fett.43", usernameLink: expectedNewLink),
        )
        XCTAssertTrue(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 1)
    }

    func testSuccessfulConfirmationClearsUsernameCorruption() async {
        let newHandle = UUID()

        mockUsernameLinkManager.entropyToGenerate = .success(.mockEntropy)
        mockUsernameApiClient.confirmReservedUsernameMocks = [{ _, _, _ in .success(usernameLinkHandle: newHandle) }]

        mockDB.write { tx in
            localUsernameManager.setLocalUsernameCorrupted(tx: tx)
        }

        XCTAssertEqual(usernameState(), .usernameAndLinkCorrupted)

        let value = await localUsernameManager.confirmUsername(reservedUsername: try! Usernames.HashedUsername(forUsername: "boba_fett.43"))

        let expectedNewLink = Usernames.UsernameLink(handle: newHandle, entropy: .mockEntropy)!

        XCTAssertEqual(
            value,
            .success(.success(username: "boba_fett.43", usernameLink: expectedNewLink)),
        )
        XCTAssertEqual(
            usernameState(),
            .available(username: "boba_fett.43", usernameLink: expectedNewLink),
        )
        XCTAssertTrue(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 1)
    }

    // MARK: Deletion

    func testDeletionHappyPath() async {
        mockUsernameApiClient.deleteCurrentUsernameMocks = [{}]

        _ = setUsername(username: "boba_fett.42")

        let value = await localUsernameManager.deleteUsername()

        XCTAssertEqual(value.isSuccess, true)
        XCTAssertEqual(usernameState(), .unset)
        XCTAssertTrue(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 1)
    }

    func testDeleteBailsEarlyIfNotReachable() async {
        mockReachabilityManager.isReachable = false

        let stateBeforeConfirm = setUsername(username: "boba_fett.42")

        let value = await localUsernameManager.deleteUsername()

        XCTAssertEqual(value.isNetworkError, true)
        XCTAssertEqual(usernameState(), stateBeforeConfirm)
        XCTAssertFalse(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 0)
    }

    func testCorruptionIfNetworkErrorWhileDeleting() async {
        mockUsernameApiClient.deleteCurrentUsernameMocks = [{ throw OWSHTTPError.mockNetworkFailure }]

        _ = setUsername(username: "boba_fett.42")

        let value = await localUsernameManager.deleteUsername()

        XCTAssertEqual(value.isNetworkError, true)
        XCTAssertEqual(usernameState(), .usernameAndLinkCorrupted)
        XCTAssertFalse(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 0)
    }

    func testCorruptionIfErrorWhileDeleting() async {
        mockUsernameApiClient.deleteCurrentUsernameMocks = [{ throw OWSGenericError("") }]

        _ = setUsername(username: "boba_fett.42")

        let value = await localUsernameManager.deleteUsername()

        XCTAssertEqual(value.isOtherError, true)
        XCTAssertEqual(usernameState(), .usernameAndLinkCorrupted)
        XCTAssertFalse(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 0)
    }

    func testDeletionClearsCorruption() async {
        mockUsernameApiClient.deleteCurrentUsernameMocks = [{}]

        mockDB.write { tx in
            localUsernameManager.setLocalUsernameCorrupted(tx: tx)
        }

        XCTAssertEqual(usernameState(), .usernameAndLinkCorrupted)

        let value = await localUsernameManager.deleteUsername()

        XCTAssertEqual(value.isSuccess, true)
        XCTAssertEqual(usernameState(), .unset)
        XCTAssertTrue(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 1)
    }

    func testDeletionClearsLinkCorruption() async {
        mockUsernameApiClient.deleteCurrentUsernameMocks = [{}]

        mockDB.write { tx in
            localUsernameManager.setLocalUsernameWithCorruptedLink(
                username: "boba_fett.42",
                tx: tx,
            )
        }

        XCTAssertEqual(usernameState(), .linkCorrupted(username: "boba_fett.42"))

        let value = await localUsernameManager.deleteUsername()

        XCTAssertEqual(value.isSuccess, true)
        XCTAssertEqual(usernameState(), .unset)
        XCTAssertTrue(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 1)
    }

    // MARK: Rotate link

    func testRotationHappyPath() async {
        let newHandle = UUID()

        mockUsernameLinkManager.entropyToGenerate = .success(.mockEntropy)
        mockUsernameApiClient.setUsernameLinkMocks = [{ _, _ in newHandle }]

        _ = setUsername(username: "boba_fett.42")

        let value = await localUsernameManager.rotateUsernameLink()

        let expectedNewLink = Usernames.UsernameLink(handle: newHandle, entropy: .mockEntropy)!

        XCTAssertEqual(value, .success(expectedNewLink))
        XCTAssertEqual(
            usernameState(),
            .available(username: "boba_fett.42", usernameLink: expectedNewLink),
        )
        XCTAssertTrue(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 0)
    }

    func testRotationBailsEarlyIfNotReachable() async {
        mockReachabilityManager.isReachable = false

        let stateBeforeConfirm = setUsername(username: "boba_fett.42")

        let value = await localUsernameManager.rotateUsernameLink()

        XCTAssertEqual(value, .failure(.networkError))
        XCTAssertEqual(usernameState(), stateBeforeConfirm)
        XCTAssertFalse(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 0)
    }

    func testNoCorruptionIfFailToGenerateNewLink() async {
        mockUsernameLinkManager.entropyToGenerate = .failure(OWSGenericError("Jabba's Sudden But Inevitable Betrayal"))

        let stateBeforeRotate = setUsername(username: "boba_fett.42")

        let value = await localUsernameManager.rotateUsernameLink()

        XCTAssertEqual(value, .failure(.otherError))
        XCTAssertEqual(usernameState(), stateBeforeRotate)
        XCTAssertFalse(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 0)
    }

    func testCorruptionIfNetworkErrorWhileRotatingLink() async {
        mockUsernameLinkManager.entropyToGenerate = .success(.mockEntropy)
        mockUsernameApiClient.setUsernameLinkMocks = [{ _, _ in throw OWSHTTPError.mockNetworkFailure }]

        _ = setUsername(username: "boba_fett.42")

        let value = await localUsernameManager.rotateUsernameLink()

        XCTAssertEqual(value, .failure(.networkError))
        XCTAssertEqual(usernameState(), .linkCorrupted(username: "boba_fett.42"))
        XCTAssertFalse(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 0)
    }

    func testCorruptionIfErrorWhileRotatingLink() async {
        mockUsernameLinkManager.entropyToGenerate = .success(.mockEntropy)
        mockUsernameApiClient.setUsernameLinkMocks = [{ _, _ in throw OWSGenericError("") }]

        _ = setUsername(username: "boba_fett.42")

        let value = await localUsernameManager.rotateUsernameLink()

        XCTAssertEqual(value, .failure(.otherError))
        XCTAssertEqual(usernameState(), .linkCorrupted(username: "boba_fett.42"))
        XCTAssertFalse(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 0)
    }

    func testSuccessfulRotationClearsCorruption() async {
        let newHandle = UUID()

        mockUsernameLinkManager.entropyToGenerate = .success(.mockEntropy)
        mockUsernameApiClient.setUsernameLinkMocks = [{ _, _ in newHandle }]

        mockDB.write { tx in
            localUsernameManager.setLocalUsernameWithCorruptedLink(
                username: "boba_fett.42",
                tx: tx,
            )
        }

        XCTAssertEqual(usernameState(), .linkCorrupted(username: "boba_fett.42"))

        let value = await localUsernameManager.rotateUsernameLink()

        let expectedNewLink = Usernames.UsernameLink(handle: newHandle, entropy: .mockEntropy)!

        XCTAssertEqual(value, .success(expectedNewLink))
        XCTAssertEqual(
            usernameState(),
            .available(username: "boba_fett.42", usernameLink: expectedNewLink),
        )
        XCTAssertTrue(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 0)
    }

    func testUpdateVisibleCaseHappyPath() async {
        let linkHandle = UUID()

        mockUsernameApiClient.setUsernameLinkMocks = [{ _, keepLinkHandle in
            XCTAssertTrue(keepLinkHandle)
            return linkHandle
        }]

        let currentLink = setUsername(username: "boba_fett.42", linkHandle: linkHandle).usernameLink!

        let value = await localUsernameManager.updateVisibleCaseOfExistingUsername(newUsername: "BoBa_fEtT.42")

        XCTAssertEqual(value.isSuccess, true)
        XCTAssertEqual(
            usernameState(),
            .available(username: "BoBa_fEtT.42", usernameLink: currentLink),
        )
        XCTAssertTrue(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 0)
    }

    func testUpdateVisibleCaseBailsEarlyIfNotReachable() async {
        mockReachabilityManager.isReachable = false

        let stateBeforeConfirm = setUsername(username: "boba_fett.42")

        let value = await localUsernameManager.updateVisibleCaseOfExistingUsername(newUsername: "BoBa_fEtT.42")

        XCTAssertEqual(value.isNetworkError, true)
        XCTAssertEqual(usernameState(), stateBeforeConfirm)
        XCTAssertFalse(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 0)
    }

    func testUpdateVisibleCaseSetsLocalEvenIfNetworkError() async {
        let linkHandle = UUID()

        mockUsernameApiClient.setUsernameLinkMocks = [{ _, keepLinkHandle in
            XCTAssertTrue(keepLinkHandle)
            throw OWSHTTPError.mockNetworkFailure
        }]

        _ = setUsername(username: "boba_fett.42", linkHandle: linkHandle).usernameLink!

        let value = await localUsernameManager.updateVisibleCaseOfExistingUsername(newUsername: "BoBa_fEtT.42")

        XCTAssertEqual(value.isNetworkError, true)
        XCTAssertEqual(
            usernameState(),
            .linkCorrupted(username: "BoBa_fEtT.42"),
        )
        XCTAssertTrue(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 0)
    }

    func testUpdateVisibleCaseSetsLocalEvenIfError() async {
        let linkHandle = UUID()

        mockUsernameApiClient.setUsernameLinkMocks = [{ _, keepLinkHandle in
            XCTAssertTrue(keepLinkHandle)
            throw OWSGenericError("oopsie")
        }]

        _ = setUsername(username: "boba_fett.42", linkHandle: linkHandle).usernameLink!

        let value = await localUsernameManager.updateVisibleCaseOfExistingUsername(newUsername: "BoBa_fEtT.42")

        XCTAssertEqual(value.isOtherError, true)
        XCTAssertEqual(
            usernameState(),
            .linkCorrupted(username: "BoBa_fEtT.42"),
        )
        XCTAssertTrue(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 0)
    }

    // MARK: Network retries

    func testUpdateVisibleCaseWorkSecondTimeAfterNetworkError() async {
        setLocalUsernameManager(maxNetworkRequestRetries: 1)

        let linkHandle = UUID()

        mockUsernameApiClient.setUsernameLinkMocks = [
            { _, keepLinkHandle in
                XCTAssertTrue(keepLinkHandle)
                throw OWSHTTPError.mockNetworkFailure
            },
            { _, keepLinkHandle in
                XCTAssertTrue(keepLinkHandle)
                return linkHandle
            },
        ]

        let currentLink = setUsername(username: "boba_fett.42", linkHandle: linkHandle).usernameLink!

        let value = await localUsernameManager.updateVisibleCaseOfExistingUsername(newUsername: "BoBa_fEtT.42")

        XCTAssertEqual(value.isSuccess, true)
        XCTAssertEqual(
            usernameState(),
            .available(username: "BoBa_fEtT.42", usernameLink: currentLink),
        )
        XCTAssertTrue(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
        XCTAssertEqual(mockSyncMessageSender.usernameChangeSyncMessageCount, 0)
    }

    // MARK: Utilities

    private func setUsername(
        username: String,
        linkHandle: UUID? = nil,
    ) -> Usernames.LocalUsernameState {
        return mockDB.write { tx in
            localUsernameManager.setLocalUsername(
                username: username,
                usernameLink: .mock(handle: linkHandle ?? UUID()),
                tx: tx,
            )

            return localUsernameManager.usernameState(tx: tx)
        }
    }

    private func usernameState() -> Usernames.LocalUsernameState {
        return mockDB.read { tx in
            return localUsernameManager.usernameState(tx: tx)
        }
    }

    // MARK: - Tellomi

    /// Tellomi（tellomi/tellomi#1106 第二刀，ADR-0066 §六「生成」）：不指定判别位时只产 `<nickname>.01` 一个候选；
    /// 指定了照用（修复模式沿用旧判别位的路径还在）；昵称不合法照旧抛错，界面按错误类型给提示。
    func testTellomiCandidatesUseOnlyTheFixedDiscriminator() throws {
        let generated = try Usernames.HashedUsername.generateCandidates(
            forNickname: "kaixin",
            minNicknameLength: 3,
            maxNicknameLength: 20,
            desiredDiscriminator: nil,
            enforcingLetterFirst: true,
        )
        XCTAssertEqual(generated.candidateHashes.count, 1)
        XCTAssertEqual(generated.candidate(matchingHash: generated.candidateHashes[0])?.usernameString, "kaixin.01")

        let custom = try Usernames.HashedUsername.generateCandidates(
            forNickname: "kaixin",
            minNicknameLength: 3,
            maxNicknameLength: 20,
            desiredDiscriminator: "57",
            enforcingLetterFirst: true,
        )
        XCTAssertEqual(custom.candidate(matchingHash: custom.candidateHashes[0])?.usernameString, "kaixin.57")

        XCTAssertThrowsError(try Usernames.HashedUsername.generateCandidates(
            forNickname: "1kaixin",
            minNicknameLength: 3,
            maxNicknameLength: 20,
            desiredDiscriminator: nil,
            enforcingLetterFirst: true,
        ))
    }

    /// Tellomi（ADR-0066 §六 第 73 行 / ADR-0036）：新建 / 修改的用户名必须字母开头。libsignal 放行 `_` 开头，客户端收紧；
    /// 太短 / 非法字符照旧由 libsignal 先报；`_` 在中间、结尾照旧合法。
    func testTellomiNicknameMustStartWithLetter() throws {
        typealias CandidateError = Usernames.HashedUsername.CandidateGenerationError

        func generate(_ nickname: String) throws -> Usernames.HashedUsername.GeneratedCandidates {
            try Usernames.HashedUsername.generateCandidates(
                forNickname: nickname,
                minNicknameLength: 3,
                maxNicknameLength: 20,
                desiredDiscriminator: nil,
                enforcingLetterFirst: true,
            )
        }

        func assertRejected(_ nickname: String, _ expected: CandidateError, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try generate(nickname), file: file, line: line) { error in
                XCTAssertEqual(error as? CandidateError, expected, "\(nickname)", file: file, line: line)
            }
        }

        assertRejected("_kaixin", .nicknameCannotStartWithUnderscore)
        assertRejected("___", .nicknameCannotStartWithUnderscore)
        assertRejected("_1abc", .nicknameCannotStartWithUnderscore)
        assertRejected("_a", .nicknameTooShort)
        assertRejected("_ab cd", .nicknameContainsInvalidCharacters)
        assertRejected("1kaixin", .nicknameCannotStartWithDigit)

        XCTAssertEqual(try generate("kai_xin").candidateHashes.count, 1)
        XCTAssertEqual(try generate("kaixin_").candidateHashes.count, 1)
    }

    /// Tellomi（taishi 审 Android a3 的意见，iOS 同一条）：「字母开头」只对新起的名字收紧；
    /// 已有昵称（含旧后缀迁到 `.01`）与修复模式（包括修复模式下全新的 `_` 名）不拦，别的规则照旧。
    func testTellomiLetterFirstOnlyForNewNames() throws {
        typealias HashedUsername = Usernames.HashedUsername

        XCTAssertTrue(HashedUsername.tellomiEnforcesLetterFirst(desiredNickname: "_other", existingNickname: "_kaixin", isAttemptingRecovery: false))
        XCTAssertTrue(HashedUsername.tellomiEnforcesLetterFirst(desiredNickname: "_kaixin", existingNickname: nil, isAttemptingRecovery: false))
        XCTAssertFalse(HashedUsername.tellomiEnforcesLetterFirst(desiredNickname: "_KaiXin", existingNickname: "_kaixin", isAttemptingRecovery: false))
        XCTAssertFalse(HashedUsername.tellomiEnforcesLetterFirst(desiredNickname: "_kaixin", existingNickname: nil, isAttemptingRecovery: true))
        // 修复模式整段不收紧，全新的 `_` 名也放过（比 Android / Desktop 宽一档，taishi 审 a4-v2 同意保留）
        XCTAssertFalse(HashedUsername.tellomiEnforcesLetterFirst(desiredNickname: "_other", existingNickname: nil, isAttemptingRecovery: true))

        let kept = try HashedUsername.generateCandidates(
            forNickname: "_kaixin",
            minNicknameLength: 3,
            maxNicknameLength: 20,
            desiredDiscriminator: nil,
            enforcingLetterFirst: false,
        )
        XCTAssertEqual(kept.candidate(matchingHash: kept.candidateHashes[0])?.usernameString, "_kaixin.01")

        XCTAssertThrowsError(try HashedUsername.generateCandidates(
            forNickname: "1kaixin",
            minNicknameLength: 3,
            maxNicknameLength: 20,
            desiredDiscriminator: nil,
            enforcingLetterFirst: false,
        )) { error in
            XCTAssertEqual(error as? HashedUsername.CandidateGenerationError, .nicknameCannotStartWithDigit)
        }
    }

    /// Tellomi（tellomi/tellomi#1106 第四刀，ADR-0066 §6.2）：reserve 的 429 按 Retry-After 分成改名冷却和普通限流。
    func testTellomiReservationRateLimitSplitsOffRenameCooldown() {
        guard case .changeCooldown(let retryAfter) = UsernameApiClientImpl.reservationResultForRateLimit(retryAfter: 2_591_999) else {
            return XCTFail("30 天的 Retry-After 应当是改名冷却")
        }
        XCTAssertEqual(retryAfter, 2_591_999)

        for shortOrMissing: TimeInterval? in [9, 3600, nil] {
            guard case .rateLimited = UsernameApiClientImpl.reservationResultForRateLimit(retryAfter: shortOrMissing) else {
                return XCTFail("\(String(describing: shortOrMissing)) 秒应当是普通限流")
            }
        }
    }
}

private extension Usernames.RemoteMutationResult<Void> {
    var isSuccess: Bool {
        switch self {
        case .success: return true
        case .failure: return false
        }
    }

    var isNetworkError: Bool {
        switch self {
        case .failure(.networkError): return true
        case .success, .failure(.otherError): return false
        }
    }

    var isOtherError: Bool {
        switch self {
        case .failure(.otherError): return true
        case .success, .failure(.networkError): return false
        }
    }
}

// MARK: - Mocks

private extension OWSHTTPError {
    static var mockNetworkFailure: OWSHTTPError {
        return .networkFailure(.genericFailure)
    }
}

private extension Usernames.HashedUsername {
    static func mock(_ username: String) -> Usernames.HashedUsername {
        try! Usernames.HashedUsername(forUsername: username)
    }
}

private extension Usernames.UsernameLink {
    static func mock(handle: UUID) -> Usernames.UsernameLink {
        Usernames.UsernameLink(
            handle: handle,
            entropy: .mockEntropy,
        )!
    }
}

private extension Data {
    static let mockEntropy = Data(repeating: 12, count: 32)
}

private class MockReachabilityManager: SSKReachabilityManager {
    var isReachable: Bool = true
    func isReachable(via reachabilityType: ReachabilityType) -> Bool { owsFail("Not implemented!") }
}

private class MockStorageServiceManager: StorageServiceManager {
    var didRecordPendingLocalAccountUpdates: Bool = false

    func recordPendingLocalAccountUpdates() {
        didRecordPendingLocalAccountUpdates = true
    }

    func setLocalIdentifiers(_ localIdentifiers: LocalIdentifiers) { owsFail("Not implemented!") }
    func registerForCron(_ cron: Cron) { owsFail("Not implemented.") }
    func currentManifestVersion(tx: DBReadTransaction) -> UInt64 { owsFail("Not implemented") }
    func currentManifestHasRecordIkm(tx: DBReadTransaction) -> Bool { owsFail("Not implemented") }
    func waitForPendingRestores() async throws { owsFail("Not implemented") }
    func waitForSteadyState() async throws(CancellationError) { owsFail("Not implemented") }
    func resetLocalData(transaction: DBWriteTransaction) { owsFail("Not implemented!") }
    func recordPendingUpdates(updatedRecipientUniqueIds: [RecipientUniqueId]) { owsFail("Not implemented!") }
    func recordPendingUpdates(updatedAddresses: [SignalServiceAddress]) { owsFail("Not implemented!") }
    func recordPendingUpdates(updatedGroupV2MasterKeys: [GroupMasterKey]) { owsFail("Not implemented!") }
    func recordPendingInsertions(forGroupMasterKeys groupMasterKeys: [GroupMasterKey]) {}
    func recordPendingUpdates(updatedStoryDistributionListIds: [Data]) { owsFail("Not implemented!") }
    func recordPendingUpdates(callLinkRootKeys: [CallLinkRootKey]) { owsFail("Not implemented!") }
    func backupPendingChanges(authedDevice: AuthedDevice) { owsFail("Not implemented!") }
    func restoreOrCreateManifestIfNecessary(authedDevice: AuthedDevice, masterKeySource: StorageService.MasterKeySource) -> Promise<Void> { owsFail("Not implemented!") }
    func rotateManifest(mode: ManifestRotationMode, authedDevice: AuthedDevice) async throws { owsFail("Not implemented!") }
}

private class MockUsernameChangeSyncMessageSender: LocalUsernameManagerImpl.UsernameChangeSyncMessageSender {
    var usernameChangeSyncMessageCount = 0

    func addUsernameChangeSyncMessage(tx: DBWriteTransaction) {
        usernameChangeSyncMessageCount += 1
    }
}
