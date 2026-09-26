//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import LibSignalClient

extension Usernames {
    public class HashedUsername {
        private typealias LibSignalUsername = LibSignalClient.Username

        // MARK: Init

        private let libSignalUsername: LibSignalUsername

        public convenience init(forUsername username: String) throws {
            self.init(libSignalUsername: try .init(username))
        }

        private init(libSignalUsername: LibSignalUsername) {
            self.libSignalUsername = libSignalUsername
        }

        // MARK: Getters

        /// The raw username.
        public var usernameString: String {
            libSignalUsername.value
        }

        /// The hash of this username, as bytes.
        var rawHash: Data {
            libSignalUsername.hash
        }

        /// The hash of this username, base64url-encoded.
        lazy var hashString: String = {
            libSignalUsername.hash.asBase64Url
        }()

        /// The ZKProof string for this username's hash.
        lazy var proofString: String = {
            libSignalUsername.generateProof().asBase64Url
        }()
    }
}

// MARK: - Generate candidates

public extension Usernames.HashedUsername {
    struct GeneratedCandidates {
        private let candidates: [Usernames.HashedUsername]

        fileprivate init(candidates: [Usernames.HashedUsername]) {
            self.candidates = candidates
        }

        var candidateHashes: [String] {
            candidates.map { $0.hashString }
        }

        func candidate(matchingHash hashString: String) -> Usernames.HashedUsername? {
            candidates.first(where: { candidate in
                candidate.hashString == hashString
            })
        }
    }

    enum CandidateGenerationError: Error {
        case nicknameCannotBeEmpty
        case nicknameCannotStartWithDigit
        case nicknameContainsInvalidCharacters
        case nicknameTooShort
        case nicknameTooLong

        fileprivate init?(fromSignalError signalError: LibSignalClient.SignalError?) {
            guard let signalError else { return nil }

            switch signalError {
            case .nicknameCannotBeEmpty:
                self = .nicknameCannotBeEmpty
            case .nicknameCannotStartWithDigit:
                self = .nicknameCannotStartWithDigit
            case .badNicknameCharacter:
                self = .nicknameContainsInvalidCharacters
            case .nicknameTooShort:
                self = .nicknameTooShort
            case .nicknameTooLong:
                self = .nicknameTooLong
            default:
                return nil
            }
        }
    }

    static func generateCandidates(
        forNickname nickname: String,
        minNicknameLength: UInt32,
        maxNicknameLength: UInt32,
        desiredDiscriminator: String?,
    ) throws -> GeneratedCandidates {
        do {
            let nicknameLengthRange = minNicknameLength...maxNicknameLength
            // Tellomi（tellomi/tellomi#1106 第二刀，ADR-0066 §六「生成」）：不指定判别位时只试 `<nickname>.01` 这一个候选。
            // 上游 `LibSignalUsername.candidates(from:)` 随机一批；01–99 被服务端拒绝表挡住时会落到三位数，
            // 名字就「换了个数字」成功了。判别位固定之后 hash 唯一 = nickname 唯一，被占 / 保留词都是 409。
            let username = try LibSignalUsername(
                nickname: nickname,
                discriminator: desiredDiscriminator ?? TellomiLinks.fixedUsernameDiscriminator,
                withValidLengthWithin: nicknameLengthRange,
            )
            return .init(candidates: [.init(libSignalUsername: username)])
        } catch let error {
            if
                let libSignalError = error as? SignalError,
                let generationError = CandidateGenerationError(fromSignalError: libSignalError)
            {
                throw generationError
            }

            throw error
        }
    }
}

// MARK: - Equatable

extension Usernames.HashedUsername: Equatable {
    public static func ==(lhs: Usernames.HashedUsername, rhs: Usernames.HashedUsername) -> Bool {
        lhs.libSignalUsername.value == rhs.libSignalUsername.value
    }
}
