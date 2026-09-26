//
// Copyright 2021 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import MobileCoin
@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

class PaymentsTest: SignalBaseTest {
    override func setUp() {
        super.setUp()

        SSKEnvironment.shared.setPaymentsHelperForUnitTests(PaymentsHelperImpl())
        SUIEnvironment.shared.paymentsRef = PaymentsImpl(appReadiness: AppReadinessMock())
    }

    func test_passphraseRoundtrip1() {
        let paymentsEntropy = Randomness.generateRandomBytes(PaymentsConstants.paymentsEntropyLength)
        guard let passphrase = SUIEnvironment.shared.paymentsSwiftRef.passphrase(forPaymentsEntropy: paymentsEntropy) else {
            XCTFail("Missing passphrase.")
            return
        }
        XCTAssertEqual(paymentsEntropy, SUIEnvironment.shared.paymentsSwiftRef.paymentsEntropy(forPassphrase: passphrase))
    }

    func test_passphraseRoundtrip2() {
        let passphraseWords: [String] = "glide belt note artist surge aware disease cry mobile assume weird space pigeon scrap vast iron maximum begin rug public spice remember sword cruel".split(separator: " ").map { String($0) }
        let passphrase1 = try! PaymentsPassphrase(words: passphraseWords)
        let paymentsEntropy = SUIEnvironment.shared.paymentsSwiftRef.paymentsEntropy(forPassphrase: passphrase1)!
        guard let passphrase2 = SUIEnvironment.shared.paymentsSwiftRef.passphrase(forPaymentsEntropy: paymentsEntropy) else {
            XCTFail("Missing passphrase.")
            return
        }
        XCTAssertEqual(passphrase1, passphrase2)
        let paymentsEntropyExpected = Data(base64Encoded: "YwKeWoaNpCCPwamOYb/k6CpLgvxrsoliivRWjRlrdxE=")!
        XCTAssertEqual(paymentsEntropyExpected, paymentsEntropy)
    }

    func test_paymentAddressSigning() {
        let identityKeyPair = ECKeyPair.generateKeyPair()
        let publicAddressData = Randomness.generateRandomBytes(256)
        let signatureData = try! TSPaymentAddress.sign(
            identityKeyPair: identityKeyPair,
            publicAddressData: publicAddressData,
        )
        XCTAssertTrue(TSPaymentAddress.verifySignature(
            identityKey: identityKeyPair.keyPair.identityKey,
            publicAddressData: publicAddressData,
            signatureData: signatureData,
        ))
        let fakeSignatureData = Randomness.generateRandomBytes(UInt(signatureData.count))
        XCTAssertFalse(TSPaymentAddress.verifySignature(
            identityKey: identityKeyPair.keyPair.identityKey,
            publicAddressData: publicAddressData,
            signatureData: fakeSignatureData,
        ))
    }

    func test_isValidPhoneNumberForPayments_remoteConfigBlocklist() {
        XCTAssertTrue(PaymentsHelperImpl.isValidPhoneNumberForPayments_remoteConfigBlocklist(
            "+523456",
            paymentsDisabledRegions: ["1", "234"],
        ))
        XCTAssertFalse(PaymentsHelperImpl.isValidPhoneNumberForPayments_remoteConfigBlocklist(
            "+123456",
            paymentsDisabledRegions: ["1", "234"],
        ))
        XCTAssertTrue(PaymentsHelperImpl.isValidPhoneNumberForPayments_remoteConfigBlocklist(
            "+233333333",
            paymentsDisabledRegions: ["1", "234"],
        ))
        XCTAssertFalse(PaymentsHelperImpl.isValidPhoneNumberForPayments_remoteConfigBlocklist(
            "+234333333",
            paymentsDisabledRegions: ["1", "234"],
        ))
    }

    // Tellomi：付款在 Tellomi 构建里永远不可用，不看服务端（tellomi/tellomi#1233）。
    // 场景：已注册的 +86 号码，服务端下发的禁用地区里没有 86——上游会放行。
    func test_tellomi_paymentsStayOffWhenRemoteConfigAllowsRegion() {
        let remoteConfigManager = SSKEnvironment.shared.remoteConfigManagerRef as! StubbableRemoteConfigManager
        remoteConfigManager._currentConfig = RemoteConfig(
            clockSkew: 0,
            valueFlags: ["global.payments.disabledRegions": "98,963,53,850,7"],
        )
        SSKEnvironment.shared.databaseStorageRef.write { tx in
            (DependenciesBridge.shared.registrationStateChangeManager as! RegistrationStateChangeManagerImpl).registerForTests(
                localIdentifiers: .init(
                    aci: .init(fromUUID: UUID()),
                    pni: .init(fromUUID: UUID()),
                    e164: .init("+8613800138000")!,
                ),
                tx: tx,
            )
        }
        let paymentsHelper = SSKEnvironment.shared.paymentsHelperRef

        // 前提：上游的地区判断确实放行了这个号码，否则下面几条测不出东西。
        XCTAssertTrue(paymentsHelper.hasValidPhoneNumberForPayments)

        XCTAssertTrue(paymentsHelper.isKillSwitchActive)
        XCTAssertFalse(paymentsHelper.canEnablePayments)
        XCTAssertFalse(SUIEnvironment.shared.paymentsRef.shouldShowPaymentsUI)
    }
}
