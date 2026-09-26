//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
public import SignalRingRTC
import SignalServiceKit

public struct CallLink: Equatable {

    // MARK: -

    private enum Constants {
        static let scheme = "https"
        static let host = "signal.link"
        static let path = "/call/"
        static let legacyPath = "/call"
        static let key = "key"
    }

    // MARK: -

    public let rootKey: CallLinkRootKey

    public init(rootKey: CallLinkRootKey) {
        self.rootKey = rootKey
    }

    /// Parses a URL of the form: https://signal.link/call/#key=value
    ///
    /// Tellomi（tellomi/tellomi#1113、#947）：`tell.cc/call#key=…`（Desktop 已在发）先换算成上面的旧形状再解析——
    /// 聊天里点、扫码、链接预览都走这里，一处认全。
    public init?(url originalUrl: URL) {
        let url = TellomiLinks.legacyEquivalent(of: originalUrl)
        guard
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme == Constants.scheme || components.scheme == "sgnl",
            components.user == nil,
            components.password == nil,
            components.host == Constants.host,
            components.port == nil,
            components.path == Constants.path || components.path == Constants.legacyPath,
            components.query == nil
        else {
            return nil
        }
        components.percentEncodedQuery = components.percentEncodedFragment
        guard
            let queryItems = components.queryItems?.filter({ $0.name == Constants.key }),
            queryItems.count == 1,
            let keyItem = queryItems.first,
            let keyValue = keyItem.value,
            let rootKey = try? CallLinkRootKey(keyValue)
        else {
            return nil
        }
        self.init(rootKey: rootKey)
    }

    public static func generate() -> CallLink {
        let rootKey = CallLinkRootKey.generate()
        return CallLink(rootKey: rootKey)
    }

    public func url() -> URL {
        // Tellomi（tellomi/tellomi#1113）：发出 `https://tell.cc/call#key=…`（不带结尾斜杠，`LINKS_AND_SCHEMES.md` 那张表的形状）；
        // 解析带不带斜杠都认（init 里先换算成 `signal.link/call/#…`）
        var components = URLComponents()
        components.scheme = Constants.scheme
        components.host = TellomiLinks.host
        components.path = TellomiLinks.Path.call
        components.queryItems = [
            URLQueryItem(name: Constants.key, value: rootKey.description),
        ]
        components.percentEncodedFragment = components.percentEncodedQuery
        components.query = nil
        return components.url!
    }

    // MARK: - Equatable

    public static func ==(lhs: CallLink, rhs: CallLink) -> Bool {
        lhs.url() == rhs.url()
    }
}
