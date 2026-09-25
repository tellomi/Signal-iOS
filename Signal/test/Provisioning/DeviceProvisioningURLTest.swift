//
// Copyright 2022 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import XCTest
@testable import Signal
@testable import SignalServiceKit

class DeviceProvisioningURLTest: XCTestCase {
    func testValid() {
        func isValid(_ provisioningURL: String) -> Bool {
            DeviceProvisioningURL(urlString: provisioningURL) != nil
        }

        XCTAssertFalse(isValid(""))
        // Tellomi: the tellomi:// scheme is accepted alongside sgnl://
        XCTAssertTrue(isValid("tellomi://linkdevice?uuid=asd&pub_key=BQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"))
        XCTAssertFalse(isValid("https://linkdevice?uuid=asd&pub_key=BQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"))
        XCTAssertFalse(isValid("sgnl://linkdevice?uuid=BQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"))
        XCTAssertFalse(isValid("sgnl://linkdevice?pub_key=BQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"))
        XCTAssertFalse(isValid("sgnl://linkdevice/uuid=asd&pub_key=BQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"))

        XCTAssertTrue(isValid("sgnl://linkdevice?uuid=asd&pub_key=BQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"))
    }

    func testPublicKey() throws {
        let url = try XCTUnwrap(DeviceProvisioningURL(urlString: "sgnl://linkdevice?uuid=asd&pub_key=BQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"))

        XCTAssertEqual(url.publicKey, try PublicKey(keyData: Data(repeating: 0, count: 32)))
    }

    func testEphemeralDeviceId() throws {
        let url = try XCTUnwrap(DeviceProvisioningURL(urlString: "sgnl://linkdevice?uuid=asd&pub_key=BQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"))

        XCTAssertEqual(url.ephemeralDeviceId, "asd")
    }
}

// MARK: - Tellomi（#1219）

/// 关联设备失败的分型与文案（`LinkDeviceViewController.retryActionSheetController`）。
class TellomiLinkDeviceFailureTest: XCTestCase {
    private func httpError(_ status: Int) -> Error {
        OWSHTTPError.serviceResponse(.init(
            requestUrl: URL(string: "https://example.com/v1/provisioning/abc")!,
            responseStatus: status,
            responseHeaders: HttpHeaders(),
            responseData: nil,
        ))
    }

    func testOnly404MeansExpiredOrForeignCode() {
        XCTAssertTrue(LinkDeviceViewController.tellomiIsExpiredOrForeignCode(httpError(404)))
        for status in [400, 403, 409, 411, 422, 429, 500] {
            XCTAssertFalse(LinkDeviceViewController.tellomiIsExpiredOrForeignCode(httpError(status)), "\(status)")
        }
        XCTAssertFalse(LinkDeviceViewController.tellomiIsExpiredOrForeignCode(OWSHTTPError.networkFailure(.genericTimeout)))
    }

    func testExpiredOrForeignCodeMessageNamesSignalThroughThePlaceholder() {
        let message = LinkDeviceViewController.tellomiExpiredOrForeignCodeMessage()

        XCTAssertTrue(message.contains("from Signal rather than Tellomi"), message)
        XCTAssertFalse(message.contains("%@"), message)
    }

    func testNetworkAndServerErrorsGetTheTellomiText() {
        let networkText = OWSLocalizedString("LINKING_DEVICE_FAILED_TELLOMI_NETWORK_BODY", comment: "")
        // 键在英文里真的有（缺键时 iOS 直接返回键名）
        XCTAssertNotEqual(networkText, "LINKING_DEVICE_FAILED_TELLOMI_NETWORK_BODY")

        XCTAssertEqual(LinkDeviceViewController.tellomiFailureMessage(for: OWSHTTPError.networkFailure(.genericTimeout)), networkText)
        XCTAssertEqual(LinkDeviceViewController.tellomiFailureMessage(for: httpError(503)), networkText)

        // 429 保留上游「尝试次数太多」那句
        let rateLimited = httpError(429)
        XCTAssertEqual(LinkDeviceViewController.tellomiFailureMessage(for: rateLimited), rateLimited.userErrorDescription)
        XCTAssertNotEqual(LinkDeviceViewController.tellomiFailureMessage(for: rateLimited), networkText)
    }
}
