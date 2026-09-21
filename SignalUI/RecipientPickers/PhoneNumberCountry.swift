//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit

public struct PhoneNumberCountry: Equatable, Identifiable {
    // e.g. France
    public let countryName: String
    // e.g. +33
    public let plusPrefixedCallingCode: String
    // e.g. FR
    public let countryCode: String

    public var id: String { countryCode }

    public init(countryName: String, plusPrefixedCallingCode: String, countryCode: String) {
        self.countryName = countryName
        self.plusPrefixedCallingCode = plusPrefixedCallingCode
        self.countryCode = countryCode
    }

    /// Tellomi：注册 / 输号码界面预选的国家。
    ///
    /// 上游用设备区域（`Locale.current.regionCode`，取不到时回落 "US"）。对 Signal 是对的；
    /// 对我们，**主战场是中国大陆**，而且测试机上的区域五花八门——模拟器上是泰国 +66、
    /// Android 模拟器是 +1，每次注册都要先去列表里翻一遍「中国大陆」。
    ///
    /// 所以这里固定预选 **CN**，**列表本身完全不动**：用户照常点开、照常选别的国家。
    /// 这一点是有意的——号码能不能注册是**服务端**决定的（香港那套现在 +86 真发短信、
    /// 其它号走「后六位」规则），客户端把列表藏起来只是障眼法，还会挡住我们自己用
    /// `+1 415 555 0301` 这类测试号联调。以后要开放/限制国家，改服务端配置即可，
    /// 不用发新版客户端。
    private static let tellomiDefaultCountryCode = "CN"

    public static var defaultValue: PhoneNumberCountry {
        AssertIsOnMainThread()

        let countryCode: String = tellomiDefaultCountryCode
        let callingCodeNumber = SSKEnvironment.shared.phoneNumberUtilRef.getCallingCode(forRegion: countryCode)
        let plusPrefixedCallingCode = "\(PhoneNumber.countryCodePrefix)\(callingCodeNumber)"
        let countryName = PhoneNumberUtil.countryName(fromCountryCode: countryCode)

        return PhoneNumberCountry(countryName: countryName, plusPrefixedCallingCode: plusPrefixedCallingCode, countryCode: countryCode)
    }

    // MARK: -

    private static func bestEffortCallingCode(fromCountryCode countryCode: String) -> Int? {
        if let result = PhoneNumberUtil.callingCodeForUnsupportedCountryCode(countryCode) {
            return result
        }
        let result = SSKEnvironment.shared.phoneNumberUtilRef.getCallingCode(forRegion: countryCode)
        return result == 0 ? nil : result
    }

    private static func does(_ string: String, matchQuery query: String) -> Bool {
        let searchOptions: String.CompareOptions = [.caseInsensitive, .anchored]

        let stringTokens = string.components(separatedBy: .whitespaces)
        let queryTokens = query.components(separatedBy: .whitespaces)

        return queryTokens.allSatisfy { queryToken in
            if queryToken.isEmpty {
                return true
            }
            return stringTokens.contains { stringToken in
                stringToken.range(of: queryToken, options: searchOptions) != nil
            }
        }
    }

    /// Get country codes from a search term.
    private static func countryCodes(forSearchTerm searchTerm: String?) -> [String] {
        let cleanedSearch = (searchTerm ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        var countryCodesAndNames = NSLocale.isoCountryCodes.compactMap { countryCode -> (countryCode: String, countryName: String)? in
            guard let callingCode = bestEffortCallingCode(fromCountryCode: countryCode) else {
                // Clipperton Island is filtered intentionally.
                owsAssertDebug(countryCode == "CP")
                return nil
            }
            let countryName = PhoneNumberUtil.countryName(fromCountryCode: countryCode)
            let isMatch = (
                cleanedSearch.isEmpty ||
                    Self.does(countryName, matchQuery: cleanedSearch) ||
                    Self.does(countryCode, matchQuery: cleanedSearch) ||
                    "+\(callingCode)".contains(cleanedSearch),
            )
            return isMatch ? (countryCode, countryName) : nil
        }

        countryCodesAndNames.sort(by: { lhs, rhs in
            return lhs.countryName.localizedCaseInsensitiveCompare(rhs.countryName) == .orderedAscending
        })

        return countryCodesAndNames.map(\.countryCode)
    }

    public static func buildCountries(searchText: String?) -> [PhoneNumberCountry] {
        let searchText = searchText?.strippedOrNil
        let countryCodes: [String] = countryCodes(forSearchTerm: searchText)
        return PhoneNumberCountry.buildCountries(forCountryCodes: countryCodes)
    }

    private static func buildCountries(forCountryCodes countryCodes: [String]) -> [PhoneNumberCountry] {
        return countryCodes.compactMap { (countryCode: String) -> PhoneNumberCountry? in
            guard let countryCode = countryCode.strippedOrNil else {
                owsFailDebug("Invalid countryCode.")
                return nil
            }
            return buildCountry(forCountryCode: countryCode)
        }
    }

    public static func buildCountry(forCountryCode countryCode: String) -> PhoneNumberCountry? {
        guard let callingCode = bestEffortCallingCode(fromCountryCode: countryCode) else {
            owsFailDebug("Invalid countryCode.")
            return nil
        }
        return buildCountry(countryCode: countryCode, plusPrefixedCallingCode: "+\(callingCode)")
    }

    public static func buildCountry(forCallingCode callingCode: Int) -> PhoneNumberCountry? {
        let phoneNumberUtil = SSKEnvironment.shared.phoneNumberUtilRef

        guard let countryCode = phoneNumberUtil.getFilteredRegionCodeForCallingCode(callingCode) else {
            owsFailDebug("Invalid callingCode.")
            return nil
        }

        return buildCountry(countryCode: countryCode, plusPrefixedCallingCode: "+\(callingCode)")
    }

    private static func buildCountry(countryCode: String, plusPrefixedCallingCode: String) -> PhoneNumberCountry {
        return PhoneNumberCountry(
            countryName: PhoneNumberUtil.countryName(fromCountryCode: countryCode),
            plusPrefixedCallingCode: plusPrefixedCallingCode,
            countryCode: countryCode,
        )
    }
}
