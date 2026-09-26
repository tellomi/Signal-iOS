//
// Copyright 2022 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest
@testable import SignalServiceKit

class HttpHeadersTest: XCTestCase {
    func testFormatAcceptLanguageHeader() throws {
        func chars(_ str: String) -> [String] {
            str.map { String($0) }
        }

        let testCases: [[String]: String] = [
            []: "*",
            ["invalid!"]: "*",
            ["bad1", "bad2", "no_unders", "itstoolong", "en--", "en--us", "en-*stars*", "en-**"]: "*",

            ["en-US"]: "en-US",
            ["en-*"]: "en-*",
            ["*-US"]: "*-US",
            ["*-*"]: "*-*",
            ["a-b-c2-d"]: "a-b-c2-d",
            ["bad1", "ok", "bad2"]: "ok",

            // This was an actual string sent from someone's device, so we test that it's ignored.
            ["en-US@attribute=isk", "de"]: "de",

            ["a", "b", "c"]: "a, b;q=0.9, c;q=0.8",
            ["a", "b", "bad123", "c"]: "a, b;q=0.9, c;q=0.8",
            chars("abcdefghij"): "a, b;q=0.9, c;q=0.8, d;q=0.7, e;q=0.6, f;q=0.5, g;q=0.4, h;q=0.3, i;q=0.2, j;q=0.1",
            chars("abcdefghijklmnopqrst"): "a, b;q=0.9, c;q=0.8, d;q=0.7, e;q=0.6, f;q=0.5, g;q=0.4, h;q=0.3, i;q=0.2, j;q=0.1",
            chars("a!b@c#d$e%f^g&h(i)j_"): "a, b;q=0.9, c;q=0.8, d;q=0.7, e;q=0.6, f;q=0.5, g;q=0.4, h;q=0.3, i;q=0.2, j;q=0.1",
        ]

        for (languages, expected) in testCases {
            let actual = HttpHeaders.formatAcceptLanguageHeader(languages)
            XCTAssertEqual(actual, expected, "Input: \(languages)")
        }
    }

    func testAcceptLanguageHeaderValue() throws {
        let expected = HttpHeaders.formatAcceptLanguageHeader(Locale.preferredLanguages)
        let actual = HttpHeaders.acceptLanguageHeaderValue
        XCTAssertEqual(actual, expected)
    }

    func testDebugDescription() {
        var httpHeaders = HttpHeaders()
        httpHeaders.addHeader("Retry-After", value: "Wed, 21 Oct 2015 07:28:01 GMT", overwriteOnConflict: true)
        httpHeaders.addHeader("x-signal-timestamp", value: "1669077270", overwriteOnConflict: true)
        httpHeaders.addHeader("Content-Type", value: "text/plain", overwriteOnConflict: true)

        XCTAssertEqual(
            "\(httpHeaders)",
            "<HttpHeaders: [content-type; retry-after: Wed, 21 Oct 2015 07:28:01 GMT; x-signal-timestamp: 1669077270]>",
        )
    }

    /// Test weird behavior with Apple's allHTTPHeaderFields property.
    func testURLRequestAllHTTPHeaderFields() {
        var urlRequest = URLRequest(url: URL(string: "https://signal.org")!)
        urlRequest.allHTTPHeaderFields = ["Retry-After": "1234", "X-Custom": "Value 1"]
        // this does *not* clear any headers
        urlRequest.allHTTPHeaderFields = nil
        // this does *not* clear all headers
        urlRequest.allHTTPHeaderFields = [:]
        // this does *not* clear missing headers
        urlRequest.allHTTPHeaderFields = ["x-custom": "Value 2"]
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "X-Custom"), "Value 2")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Retry-After"), "1234")
    }

    /// Tellomi（tellomi/tellomi#1137）：User-Agent 的版本保持三段，构建号放在最后的 `Build/` 段（taishi 中转包 8 第〇节第 1 条）。
    func testTellomiUserAgentPutsTheBuildNumberInABuildSegment() throws {
        XCTAssertEqual(HttpHeaders.tellomiUserAgent(appVersion: "0.1.2.37", systemVersion: "26.0"), "Signal-iOS/0.1.2 iOS/26.0 Build/37")
        XCTAssertEqual(HttpHeaders.tellomiUserAgent(appVersion: "1.0.0.0", systemVersion: "18.7"), "Signal-iOS/1.0.0 iOS/18.7 Build/0")
        // 没有构建号（不到四段）就不写 Build/ 段，版本原样。
        XCTAssertEqual(HttpHeaders.tellomiUserAgent(appVersion: "0.1.2", systemVersion: "26.0"), "Signal-iOS/0.1.2 iOS/26.0")

        // 服务端 UserAgentUtil 的 STANDARD_UA_PATTERN，原样照抄：平台是 iOS，版本只有三段，构建号落在附加段的 Build/ 里。
        let userAgent = HttpHeaders.userAgentHeaderValueSignalIos
        let serverPattern = try NSRegularExpression(pattern: "^Signal-(Android|Desktop|iOS)/([^ ]+)( (.+))?$", options: .caseInsensitive)
        let match = try XCTUnwrap(serverPattern.firstMatch(in: userAgent, range: NSRange(userAgent.startIndex..., in: userAgent)), userAgent)
        let platform = try XCTUnwrap(Range(match.range(at: 1), in: userAgent))
        let version = try XCTUnwrap(Range(match.range(at: 2), in: userAgent))
        let additional = try XCTUnwrap(Range(match.range(at: 4), in: userAgent))
        let appVersion = AppVersionImpl.shared.currentAppVersion.split(separator: ".").map(String.init)
        XCTAssertEqual(String(userAgent[platform]), "iOS")
        XCTAssertEqual(String(userAgent[version]), appVersion.prefix(3).joined(separator: "."))
        XCTAssertEqual(userAgent[version].split(separator: ".").count, 3, userAgent)
        XCTAssertTrue(userAgent[additional].hasSuffix(" Build/\(appVersion.dropFirst(3).joined(separator: "."))"), userAgent)
    }

    func testRetryAfter() {
        let now = Date().timeIntervalSince1970
        let testCases: [(String, TimeInterval?)] = [
            // Reference: date -jf '%a, %d %b %Y %T %Z' <Value> +%s
            ("Thu, 01 Jan 1970 00:00:00 GMT", 0),
            ("Wed, 21 Oct 2015 07:28:01 GMT", 1445412481),

            // Reference: date -jf '%Y-%m-%dT%T%z' <Value> +%s
            ("1970-01-01T00:00:00+0000", 0),
            ("1969-12-31T16:00:00-0800", 0),
            ("2015-10-21T07:28:01+0000", 1445412481),
            ("2015-10-20T23:28:01-0800", 1445412481),

            // Relative delays
            ("1", now + 1),
            ("2", now + 2),
            ("1200.0", now + 1200),
            ("1200.5", now + 1200.5),
            ("86400.000", now + 86400),
            ("   86400.000    ", now + 86400),
            (" \t  \t86400.000\t  \t  ", now + 86400),

            // Absent values (these use nil)
            ("", nil),
            ("      ", nil),
            ("\n", nil),
        ]

        for (headerValue, expectedTimeInterval) in testCases {
            var headers = HttpHeaders()
            headers["Retry-After"] = headerValue

            let actualTimeInterval = headers.retryAfterDate?.timeIntervalSince1970
            if let expectedTimeInterval, let actualTimeInterval {
                XCTAssertEqual(actualTimeInterval, expectedTimeInterval, accuracy: 0.3, "\(headerValue)")
            } else {
                XCTAssertEqual(actualTimeInterval, expectedTimeInterval, "\(headerValue)")
            }
        }
    }
}
