//
// Copyright 2021 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

class QRCodeParserTest: XCTestCase {
    func testParse() {
        struct SampleQRCode {
            let qrCodeBase64: String
            let symbolVersion: Int
            let expectedMode: UInt
            let expectedString: String?
        }
        let sampleQRCodes: [SampleQRCode] = [
            SampleQRCode(
                qrCodeBase64: "QNJ1R3YXMgYnJpbGxpZw7A==",
                symbolVersion: 1,
                expectedMode: 4,
                expectedString: "'Twas brillig",
            ),
            SampleQRCode(
                qrCodeBase64: "QPVGhpcyBpcyBhIFRlc3QggCC4npgOwR7BHsEQ==",
                symbolVersion: 2,
                expectedMode: 4,
                expectedString: "This is a Test ",
            ),
            SampleQRCode(
                qrCodeBase64: "QJc2hvcHBpbmcKDsEewR7A==",
                symbolVersion: 1,
                expectedMode: 4,
                expectedString: "shopping\n",
            ),
            SampleQRCode(
                qrCodeBase64: "QZaHR0cDovL2VuLm0ud2lraXBlZGlhLm9yZw7BHsEewR7A==",
                symbolVersion: 3,
                expectedMode: 4,
                expectedString: "http://en.m.wikipedia.org",
            ),
            SampleQRCode(
                qrCodeBase64: "QBQCBCi6YzXaOADsEewR7A==",
                symbolVersion: 1,
                expectedMode: 4,
                expectedString: "@",
            ),
            SampleQRCode(
                qrCodeBase64: "Q6aHR0cDovL2l0dW5lcy5hcHBsZS5jb20vdXMvYXBwL2VuY3ljbG9wYWVkaWEtYnJpdGFubmljYS9pZBAlv+XLtAU/bXQ9OA7BHsEQ==",
                symbolVersion: 6,
                expectedMode: 4,
                expectedString: "http://itunes.apple.com/us/app/encyclopaedia-britannica/id",
            ),
            // QRCodePayload current only supports mode 4, .byte.
            // This QR code will fail to parse.
            SampleQRCode(
                qrCodeBase64: "caQVaHR0cHM6Ly9jcnVuY2hpZnkuY29tAOw=",
                symbolVersion: 3,
                expectedMode: 7,
                expectedString: nil,
            ),
            SampleQRCode(
                qrCodeBase64: "QyaHR0cHM6Ly9zaXRlcy5nb29nbGUuY29tL3NpdGUvcGVueWVsaWRpa2Fua2JhL2hvbWUOwR7A==",
                symbolVersion: 3,
                expectedMode: 4,
                expectedString: "https://sites.google.com/site/penyelidikankba/home",
            ),
            SampleQRCode(
                qrCodeBase64: "QKSSBsb3ZlIHlvdQ7BHsEQ==",
                symbolVersion: 1,
                expectedMode: 4,
                expectedString: "I love you",
            ),
            SampleQRCode(
                qrCodeBase64: "QZaHR0cDovL21lbW9yeW5vdGZvdW5kLmNvbQ7BHsEewR7A==",
                symbolVersion: 2,
                expectedMode: 4,
                expectedString: "http://memorynotfound.com",
            ),
            // QRCodePayload current only supports mode 4, .byte.
            // This QR code will fail to parse.
            SampleQRCode(
                qrCodeBase64: "caQVaHR0cDovL2NydW5jaGlmeS5jb20vAOwR7BHsEewR7A==",
                symbolVersion: 2,
                expectedMode: 7,
                expectedString: nil,
            ),
            SampleQRCode(
                qrCodeBase64: "QXaHR0cDovL3d3dy5xcnN0dWZmLmNvbS8OwR7BHsEewR7A==",
                symbolVersion: 2,
                expectedMode: 4,
                expectedString: "http://www.qrstuff.com/",
            ),
            SampleQRCode(
                qrCodeBase64: "QWaHR0cHM6Ly93d3cuZm91bmRpdC5pZQ7BHsEewR7BHsEQ==",
                symbolVersion: 2,
                expectedMode: 4,
                expectedString: "https://www.foundit.ie",
            ),
            SampleQRCode(
                qrCodeBase64: "RRaHR0cDovL2J3LXdpbmVsaXN0LXdlYnNpdGUtcHJvZC5zMy13ZWJzaXRlLXVzLXdlc3QtMi5hbWF6b25hd3MuY29tL3dpbmVsaXN0LWRlbW8vDsEewR7BHsEewR7BHsEewR7BHsEewR7BHs",
                symbolVersion: 5,
                expectedMode: 4,
                expectedString: "http://bw-winelist-website-prod.s3-website-us-west-2.amazonaws.com/winelist-demo/",
            ),
            SampleQRCode(
                qrCodeBase64: "QeaHR0cDovL3d3dy5yZWljaG1hbm4tcmFjaW5nLmRlDsEQ==",
                symbolVersion: 2,
                expectedMode: 4,
                expectedString: "http://www.reichmann-racing.de",
            ),
            SampleQRCode(
                qrCodeBase64: "QjaHR0cDovL3d3dy5ocnQubXN1LmVkdS9icmlkZ2V0LWJlaGUOwR7BHsEewR7BHsEewR7BHsEQ==",
                symbolVersion: 3,
                expectedMode: 4,
                expectedString: "http://www.hrt.msu.edu/bridget-behe",
            ),
            SampleQRCode(
                qrCodeBase64: "QISGVsbG8gOikOwR7BHsEewR7A==",
                symbolVersion: 1,
                expectedMode: 4,
                expectedString: "Hello :)",
            ),
            SampleQRCode(
                qrCodeBase64: "QNSGVsbG8gV29ybGQhIIBgmIXEKSE/CmgASAMkAa6I2KAJDsEewR7BHsEew=",
                symbolVersion: 3,
                expectedMode: 4,
                expectedString: "Hello World! ",
            ),
            SampleQRCode(
                qrCodeBase64: "QPd3d3LnhhbWFyaW4uY29tDsEQ==",
                symbolVersion: 1,
                expectedMode: 4,
                expectedString: "www.xamarin.com",
            ),
            SampleQRCode(
                qrCodeBase64: "QsaHR0cDovL3BhdGhzLmlvbmludGVyYWN0aXZlLmNvbS9xcmd1aWRlY292ZXIOwR7BHsEewR7BHsEewR7BHsEQ==",
                symbolVersion: 4,
                expectedMode: 4,
                expectedString: "http://paths.ioninteractive.com/qrguidecover",
            ),
        ]

        for sampleQRCode in sampleQRCodes {
            let qrCodeBase64 = sampleQRCode.qrCodeBase64
            let symbolVersion = sampleQRCode.symbolVersion
            let expectedMode = sampleQRCode.expectedMode
            let expectedString = sampleQRCode.expectedString

            let qrCodeData: Data = Data(base64Encoded: qrCodeBase64)!
            guard
                let payload = QRCodePayload.parse(
                    codewords: qrCodeData,
                    qrCodeVersion: symbolVersion,
                )
            else {
                if expectedMode != 4 {
                    Logger.warn("Could not parse payload; expected for non-.byte mode.")
                } else {
                    XCTFail("Could not parse payload: \(expectedMode).")
                }
                continue
            }
            XCTAssertEqual(payload.mode.rawValue, expectedMode)

            if let expectedString {
                if let string = payload.asString {
                    XCTAssertEqual(string, expectedString)
                } else {
                    XCTFail("Missing string.")
                }
            } else {
                XCTFail("Missing expectedString.")
            }
        }
    }
}

// MARK: - Tellomi（#1219）

/// 关联设备扫码只放行对准中心、连续对准 0.5 秒的码。时刻都取 1/8 秒的倍数，浮点运算是精确的。
class TellomiQrFocusTest: XCTestCase {
    private var now: TimeInterval = 0
    private lazy var focus = TellomiQrFocus(now: { [unowned self] in self.now })

    private let center = CGPoint(x: 0.5, y: 0.5)

    /// 在 `times` 这些时刻各喂一帧，返回每一帧是否放行。
    private func feed(_ code: String?, at point: CGPoint?, _ times: TimeInterval...) -> [Bool] {
        times.map {
            now = $0
            return focus.onFrame(code: code, center: point)
        }
    }

    func testCenteredCodeIsReleasedOnlyAfterHalfASecond() {
        XCTAssertEqual(feed("A", at: center, 0, 0.125, 0.25, 0.375), [false, false, false, false])
        XCTAssertEqual(feed("A", at: center, 0.5), [true])
    }

    func testCodeOutsideTheCenterIsNeverReleased() {
        let results = feed("A", at: CGPoint(x: 0.15, y: 0.5), 0, 0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 0.875, 1)
        XCTAssertFalse(results.contains(true))
    }

    func testSwitchingToAnotherCodeRestartsTheTimer() {
        _ = feed("A", at: center, 0, 0.125, 0.25, 0.375)
        XCTAssertEqual(feed("B", at: center, 0.5, 0.625, 0.75, 0.875), [false, false, false, false])
        XCTAssertEqual(feed("B", at: center, 1), [true])
    }

    func testAMissedFrameDoesNotRestartTheTimer() {
        _ = feed("A", at: center, 0, 0.125, 0.25)
        _ = feed(nil, at: nil, 0.375)
        XCTAssertEqual(feed("A", at: center, 0.5), [true])
    }

    func testLosingTheCodeForLongerThanTheGapRestartsTheTimer() {
        _ = feed("A", at: center, 0, 0.125)
        _ = feed(nil, at: nil, 0.25, 0.375, 0.5)
        XCTAssertEqual(feed("A", at: center, 0.625, 0.75, 0.875, 1), [false, false, false, false])
        XCTAssertEqual(feed("A", at: center, 1.125), [true])
    }

    func testSlowFramesThatAllSeeTheCenteredCodeStillReleaseIt() {
        // 处理一帧要 0.375 秒：每帧都对准，中间没有别的帧，不算丢失
        XCTAssertEqual(feed("A", at: center, 0, 0.375), [false, false])
        XCTAssertEqual(feed("A", at: center, 0.75), [true])
    }

    func testFramesJustOverTheGapStillRelease() {
        XCTAssertEqual(feed("A", at: center, 0, 0.359375), [false, false])
        XCTAssertEqual(feed("A", at: center, 0.71875), [true])
    }

    func testASlowFrameAfterAMissStillRestartsTheTimer() {
        // 中间真的看到过没对准的帧，再按间隔判丢失
        _ = feed("A", at: center, 0)
        _ = feed("A", at: CGPoint(x: 0.1, y: 0.5), 0.125)
        XCTAssertEqual(feed("A", at: center, 0.5, 0.875), [false, false])
        XCTAssertEqual(feed("A", at: center, 1), [true])
    }

    func testCenterRegionIsTheMiddleFortyPercentOnBothAxes() {
        XCTAssertTrue(TellomiQrFocus.isInCenter(CGPoint(x: 0.3, y: 0.3)))
        XCTAssertTrue(TellomiQrFocus.isInCenter(CGPoint(x: 0.7, y: 0.7)))
        XCTAssertFalse(TellomiQrFocus.isInCenter(CGPoint(x: 0.5, y: 0.29)))
        XCTAssertFalse(TellomiQrFocus.isInCenter(CGPoint(x: 0.71, y: 0.5)))
    }
}
