//
// Copyright 2026 Tellomi
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Tellomi（tellomi/tellomi#1215）：默认头像上的字，与 Android `TellomiNames.abbreviation` 同一条规则。
public enum TellomiNames {

    /// 中文名（去掉空白和标点后全是汉字）取**最后两个字**：「欧阳娜娜」→「娜娜」、「张三」→「张三」、「李」→「李」、「马克·卡尔」→「卡尔」，
    /// 和国内常见的默认头像一致。不是中文名时返回 nil，调用方照上游（`PersonNameComponentsFormatter` 的缩写）。
    public static func hanAbbreviation(_ fullName: String) -> String? {
        let letters = fullName.replacingOccurrences(of: "[\\s\\p{P}]", with: "", options: .regularExpression)
        guard !letters.isEmpty, letters.range(of: "^\\p{Han}+$", options: .regularExpression) != nil else {
            return nil
        }
        return String(letters.suffix(2))
    }
}
