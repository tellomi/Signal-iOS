//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

public import SignalServiceKit

/// Tellomi（tellomi/tellomi#1215 第二刀）：注册资料页上的「用户名（选填）」，与 Android `TellomiUsernameEntry` 同一套规则。
///
/// 停顿后先在本地按 TR-ID-01 查（字母开头、3–20 位、a–z 0–9 _），通过了再向服务端保留 `<名字>.01`
/// （ADR-0066：`generateCandidates` 不指定判别位时只生成这一个）。被占用、命中保留词服务端都回「不可用」，这时给 `candidates`。
/// 点「下一步」时先确认保留，确认成功才保存资料——确认失败人还在这一页，能改。
///
/// 这时账号已经在服务端建好、本机注册还没完成，隐式认证取不到凭证，所以保留和确认都由注册协调器
/// 用 `accountIdentity.chatServiceAuth` 显式认证去做（和注册里「找回原名」同一个做法）。
public enum TellomiRegistrationUsername {

    static let minLength = 3
    static let maxLength = 20

    enum LocalError: Equatable {
        case tooShort
        case tooLong
        case invalidCharacters
        case mustStartWithLetter
    }

    /// 本地规则（TR-ID-01）。顺序照 libsignal 的校验（Android 直接用它）：先字符、再长度（「a-」算非法字符、不算太短）；
    /// 首字符非字母先拦——上游只拦数字开头，Tellomi 要求字母开头（ADR-0066），`_` 开头也说「需要以字母开头」。
    static func check(_ nickname: String) -> LocalError? {
        let scalars = Array(nickname.unicodeScalars)
        guard let first = scalars.first else {
            return .tooShort
        }
        if !isAsciiLetter(first) {
            return isAsciiDigit(first) || first == "_" ? .mustStartWithLetter : .invalidCharacters
        }
        if scalars.contains(where: { !isAsciiLetter($0) && !isAsciiDigit($0) && $0 != "_" }) {
            return .invalidCharacters
        }
        if scalars.count < minLength {
            return .tooShort
        }
        if scalars.count > maxLength {
            return .tooLong
        }
        return nil
    }

    /// 不可用时给的候选：原名后面**直接接数字**（两位、三位、再一个不同的两位），三个互不相同、都过得了 `check`。
    /// 候选本身不预先向服务端查（保留有频率限制），用户点了照常走一遍检查。
    ///
    /// 不用 `原名_数字`，原名末尾的 `_` 也去掉（taishi 审查包 4，Android 同一刀）：词库的 PREFIX 规则以「非字母数字」为边界，
    /// `kefu_58` 正是要拦的形状，而服务端拒绝表只收 EXACT，这种候选能保留成功。紧跟数字不算边界，`kefu27` 不命中。
    static func candidates<R: RandomNumberGenerator>(for nickname: String, count: Int = 3, using random: inout R) -> [String] {
        var base = String(nickname.lowercased().unicodeScalars.filter { isAsciiLetter($0) || isAsciiDigit($0) || $0 == "_" }.map(Character.init))
        while base.hasSuffix("_") {
            base.removeLast()
        }
        base = String(base.prefix(maxLength - 3))
        guard let first = base.unicodeScalars.first, isAsciiLetter(first) else {
            return []
        }

        var result: [String] = []
        var attempts = 0
        while result.count < count, attempts < count * 10 {
            let candidate = attempts % 3 == 1
                ? base + String(Int.random(in: 100..<1000, using: &random))
                : base + String(Int.random(in: 10..<100, using: &random))
            if candidate.caseInsensitiveCompare(nickname) != .orderedSame, check(candidate) == nil, !result.contains(candidate) {
                result.append(candidate)
            }
            attempts += 1
        }
        return result
    }

    static func candidates(for nickname: String) -> [String] {
        var random = SystemRandomNumberGenerator()
        return candidates(for: nickname, using: &random)
    }

    // MARK: - 服务端结果

    public enum ReservationOutcome: Equatable {
        case reserved(Usernames.HashedUsername)
        /// 被占用或是保留名（服务端不区分）。
        case notAvailable
        /// 改名冷却：回收号码的新主人会继承上一个人的 30 天冷却（ADR-0066 §6.2），这期间任何用户名都保留不了。
        case cooldown(days: Int)
        /// 保留被限流（每号 100 次，之后每 15 分钟 1 次）。
        case tooManyAttempts
        /// 网络不好 / 服务端出错，没查成。
        case failed
    }

    /// reserve 的结果 → 页面上的说法。改名冷却和普通限流在 `UsernameApiClientImpl` 里按 `Retry-After` 分开
    /// （超过一小时是冷却，#19），天数与编辑页、Android、Desktop 同一个算法。
    static func reservationOutcome(of result: Usernames.RemoteMutationResult<Usernames.ReservationResult>) -> ReservationOutcome {
        switch result {
        case .success(.successful(_, let hashedUsername)):
            return .reserved(hashedUsername)
        case .success(.rejected):
            return .notAvailable
        case .success(.rateLimited):
            return .tooManyAttempts
        case .success(.changeCooldown(let retryAfter)):
            return .cooldown(days: TellomiLinks.renameCooldownDaysLeft(retryAfter: retryAfter))
        case .failure:
            return .failed
        }
    }

    public enum ConfirmationOutcome: Equatable {
        case confirmed
        /// 保留过期（约 5 分钟）或已被别人抢走（服务端 409 / 410 不区分）：重新保留一次，结果决定可用还是给候选。
        case rejected
        case failed
    }

    static func confirmationOutcome(of result: Usernames.RemoteMutationResult<Usernames.ConfirmationResult>) -> ConfirmationOutcome {
        switch result {
        case .success(.success):
            return .confirmed
        case .success(.rejected):
            return .rejected
        case .success(.rateLimited), .failure:
            return .failed
        }
    }

    // MARK: -

    private static func isAsciiLetter(_ scalar: Unicode.Scalar) -> Bool {
        return ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }

    private static func isAsciiDigit(_ scalar: Unicode.Scalar) -> Bool {
        return ("0"..."9").contains(scalar)
    }
}
