//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Tellomi（tellomi/tellomi#1215）：默认头像上的字，与 Android `TellomiNames.abbreviation` 同一条规则。
public enum TellomiNames {

    /// 单框名字（注册资料页只剩一个框，全名存在 given name 里）的默认头像字，与 Android `TellomiNames.abbreviation` 逐条相同：
    /// - 中文名取最后两个字（见 `hanAbbreviation`）；
    /// - 其它名字按半角空格拆词，每个词去掉开头的非字母 / 数字 / 符号，取第一个词的第一个字素，有第二个词再加第二个词的第一个字素：
    ///   「John Smith」→「JS」、「Kevin 张」→「K张」、「小明 Wang」→「小W」、「娜娜😀」→「娜」；
    /// - 一个字素超过 16 个码位（Zalgo）换成 U+FFFD，与 Android 同一条线（taishi 审查包 5）。上游 `filterForDisplay` 做的也是这一步，
    ///   但单框名字这一支绕过了它：资料名走的是未过滤的 `nameComponents`；
    /// - 拆不出词（空串、只有标点）返回 nil，调用方显示默认头像。
    public static func abbreviation(_ name: String) -> String? {
        if let hanAbbreviation = hanAbbreviation(name) {
            return hanAbbreviation
        }
        let words = name
            .components(separatedBy: " ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { $0.replacingOccurrences(of: "^[^\\p{L}\\p{Nd}\\p{S}]+", with: "", options: .regularExpression) }
            .compactMap { $0.first }
            .map { StringSanitizer.isExtremelyLongGraphemeCluster($0) ? "\u{FFFD}" : String($0) }
        switch words.count {
        case 0:
            return nil
        case 1:
            return words[0]
        default:
            return words[0] + words[1]
        }
    }

    /// 中文名（去掉空白和标点后全是汉字）取**最后两个字**：「欧阳娜娜」→「娜娜」、「张三」→「张三」、「李」→「李」、「马克·卡尔」→「卡尔」，
    /// 和国内常见的默认头像一致。不是中文名时返回 nil。
    ///
    /// 「全是汉字」按码位判（NSString 的正则走 UTF-16），和 Android 的 `UnicodeScript.of` 同一口径，也不随系统版本变。
    /// Swift `String.range(of:options:)` 按字素匹配，汉字后面的组合符、异体字选择符会被一起算进汉字，Zalgo 就原样进了头像（taishi 中转包 8）。
    public static func hanAbbreviation(_ fullName: String) -> String? {
        let letters = fullName.replacingOccurrences(of: "[\\s\\p{P}]", with: "", options: .regularExpression)
        guard !letters.isEmpty, (letters as NSString).range(of: "^\\p{Han}+$", options: .regularExpression).location != NSNotFound else {
            return nil
        }
        return String(letters.suffix(2))
    }
}
