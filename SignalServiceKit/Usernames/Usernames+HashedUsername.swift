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
        /// Tellomi（ADR-0066 §六 第 73 行 / ADR-0036）：`_` 开头。libsignal 允许，Tellomi 的规则是字母开头。
        case nicknameCannotStartWithUnderscore

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
        enforcingLetterFirst: Bool = true,
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
            // Tellomi（ADR-0066 §六 第 73 行 / ADR-0036）：新建 / 修改的用户名必须字母开头。libsignal 只拒数字开头、放行 `_` 开头，
            // 服务端只见到哈希、拦不了，只能在客户端收紧。放在 libsignal 判过之后：太短 / 非法字符照旧先报。
            // 只有选用户名页调用这里；找回已有用户名、搜索、链接都不经过，别人已有的 `_` 开头用户名照样能找到。
            if enforcingLetterFirst, nickname.hasPrefix("_") {
                throw CandidateGenerationError.nicknameCannotStartWithUnderscore
            }
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

// MARK: - Tellomi

public extension Usernames.HashedUsername {
    /// Tellomi（ADR-0066 §六；taishi 审 Android a3 的意见，iOS 同一条）：「字母开头」只对新起的名字收紧。
    /// - 昵称与已有昵称忽略大小写相同 → 不拦。只改大小写已由选用户名页的捷径处理，这里覆盖旧后缀迁到 `.01`（`_kaixin.57` → `_kaixin.01`）。
    /// - 修复模式 → 不拦。iOS 修复时本地用户名已损坏、原名未知（`currentUsername: nil`），拦了的话 `_` 开头的用户认领不回原名。
    static func tellomiEnforcesLetterFirst(desiredNickname: String, existingNickname: String?, isAttemptingRecovery: Bool) -> Bool {
        if isAttemptingRecovery {
            return false
        }
        if let existingNickname, existingNickname.lowercased() == desiredNickname.lowercased() {
            return false
        }
        return true
    }
}

// MARK: - Equatable

extension Usernames.HashedUsername: Equatable {
    public static func ==(lhs: Usernames.HashedUsername, rhs: Usernames.HashedUsername) -> Bool {
        lhs.libSignalUsername.value == rhs.libSignalUsername.value
    }
}
