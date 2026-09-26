//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import SignalUI

final class CallLinkTest: XCTestCase {
    private func parse(_ urlString: String) -> CallLink? {
        return CallLink(url: URL(string: urlString)!)
    }

    func testUrlString() {
        XCTAssertNil(parse("https://signal.link/call/#key=bcdf-ghkm-npqr-stxz-bcdf-ghkm-npqr-stx"))
        XCTAssertNil(parse("http://signal.link/call/#key=bcdf-ghkm-npqr-stxz-bcdf-ghkm-npqr-stxz"))
        XCTAssertNil(parse("https://signal.art/call/#key=bcdf-ghkm-npqr-stxz-bcdf-ghkm-npqr-stxz"))
        XCTAssertNil(parse("https://signal.link/c/#key=bcdf-ghkm-npqr-stxz-bcdf-ghkm-npqr-stxz"))
    }

    func testRoundtrip() throws {
        // Tellomi（tellomi/tellomi#1113）：生成的是 tell.cc/call#key=…（不带斜杠）；旧的 signal.link/call/ 形状解析出的是同一个 key
        let tellShape = "https://tell.cc/call#key=bcdf-ghkm-npqr-stxz-bcdf-ghkm-npqr-stxz"
        let legacy = "https://signal.link/call/#key=bcdf-ghkm-npqr-stxz-bcdf-ghkm-npqr-stxz"
        let fromTellShape = try XCTUnwrap(parse(tellShape))
        let fromLegacy = try XCTUnwrap(parse(legacy))
        XCTAssertEqual(fromTellShape, fromLegacy)
        XCTAssertEqual(fromTellShape.url().absoluteString, tellShape)
        XCTAssertEqual(fromLegacy.url().absoluteString, tellShape)
    }

    func testGenerate() {
        let url1 = CallLink.generate().url()
        let url2 = CallLink.generate().url()
        XCTAssertNotEqual(url1, url2)
    }
}
