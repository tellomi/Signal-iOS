//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

public extension Bundle {
    @objc(appBundle)
    var app: Bundle {
        if self.bundleURL.pathExtension == "appex" {
            // the bundle of the main app is located in the same directory as
            // the parent of "PlugIns/MyAppExtension.appex" (the location of the app extensions bundle)
            let url = self.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            if let otherBundle = Bundle(url: url) {
                return otherBundle
            }
            owsFailDebug("bundle of main app not found")
        }
        return self
    }
}

@inlinable
public func OWSLocalizedString(_ key: String, tableName: String? = nil, value: String = "", comment: String) -> String {
    return TellomiLocalization.localizedString(key, tableName: tableName, value: value)
}

/// Tellomi：iOS 在当前语言的字符串表里找不到某个键时**不会回落到英文**，而是把键名原样显示出来
/// （实测：de 表缺键时 `localizedString(forKey:value:"",table:)` 返回的就是键名本身）。
/// 上游靠发版前由翻译平台把每种语言补齐；Tellomi 新加的文案只写中文和英文，其余几十种语言的用户
/// 会在界面上直接看到 `ONBOARDING_…` 这样的键名。这里在当前语言缺键时退回 en.lproj，
/// 英文也没有才照上游返回 `value` / 键名。
public enum TellomiLocalization {
    /// 不可能出现在任何译文里的哨兵，用来区分「表里没有这个键」和「译文恰好等于键名」。
    private static let missingSentinel = "\u{0}tellomi-missing-localization\u{0}"

    private static let appEnglishBundle: Bundle? = englishBundle(in: .main.app)

    static func englishBundle(in bundle: Bundle) -> Bundle? {
        return bundle.path(forResource: "en", ofType: "lproj").flatMap { Bundle(path: $0) }
    }

    public static func localizedString(_ key: String, tableName: String?, value: String) -> String {
        return localizedString(key, tableName: tableName, value: value, bundle: .main.app, englishBundle: appEnglishBundle)
    }

    static func localizedString(_ key: String, tableName: String?, value: String, bundle: Bundle, englishBundle: Bundle?) -> String {
        let localized = bundle.localizedString(forKey: key, value: missingSentinel, table: tableName)
        if localized != missingSentinel {
            return localized
        }
        if let englishBundle {
            let english = englishBundle.localizedString(forKey: key, value: missingSentinel, table: tableName)
            if english != missingSentinel {
                return english
            }
        }
        return value.isEmpty ? key : value
    }
}

extension String {
    public static func nonPluralLocalizedStringWithFormat(_ format: String, _ arguments: String...) -> String {
        return nonPluralLocalizedStringWithFormat(format, arguments: arguments)
    }

    public static func nonPluralLocalizedStringWithFormat(_ format: String, arguments: [String]) -> String {
        var result = ""
        var remainingFormat = format[...]
        var remainingArguments = arguments[...]
        while let range = remainingFormat.range(of: "%") {
            result += remainingFormat[..<range.lowerBound]
            remainingFormat = remainingFormat[range.upperBound...]
            let firstCharacter = remainingFormat.removeFirst()
            switch firstCharacter {
            case "%":
                result += "%"
            case "@", "d":
                result += remainingArguments.removeFirst()
            case let digit where digit.isASCII && digit.isNumber && (remainingFormat.hasPrefix("$@") || remainingFormat.hasPrefix("$d")):
                remainingFormat.removeFirst(2)
                result += arguments[arguments.startIndex + digit.wholeNumberValue! - 1]
            default:
                // This is validated by translation-validator before compiling.
                owsFail("can't format string with invalid escape sequence")
            }
        }
        result += remainingFormat
        return result
    }
}
