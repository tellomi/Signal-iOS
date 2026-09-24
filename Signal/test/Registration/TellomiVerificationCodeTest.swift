//
// Copyright 2026 Tellomi
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit

/// Tellomi（tellomi/tellomi#1214）：验证码页——系统自动填充 / 粘贴一次进来一整串要能整串填满；「收不到验证码？」面板说清出路。
@MainActor
final class TellomiVerificationCodeTest: SignalBaseTest {

    private final class Delegate: RegistrationVerificationCodeViewDelegate {
        var changeCount = 0
        func codeViewDidChange() {
            changeCount += 1
        }
    }

    // MARK: - Finding a code in pasted text

    func testCodeCandidateInPastedText() {
        func candidate(_ text: String) -> String? {
            RegistrationVerificationCodeView.codeCandidate(in: text, digitCount: 6)
        }
        XCTAssertEqual(candidate("123456"), "123456")
        XCTAssertEqual(candidate("123-456"), "123456")
        XCTAssertEqual(candidate("123 456"), "123456")
        XCTAssertEqual(candidate("【Tellomi】您的验证码是 482913，5 分钟内有效，请勿泄露。"), "482913")
        XCTAssertEqual(candidate("Your Tellomi code: 482-913"), "482913")
        // 手机号那样的长串、7 位数字都不是验证码。
        XCTAssertNil(candidate("+86 138 0013 8000"))
        XCTAssertNil(candidate("13800138000"))
        XCTAssertNil(candidate("1234567"))
        XCTAssertNil(candidate("12345"))
        XCTAssertNil(candidate("没有数字"))
    }

    // MARK: - The code view

    private func makeCodeView() -> (RegistrationVerificationCodeView, Delegate) {
        let view = RegistrationVerificationCodeView()
        let delegate = Delegate()
        view.delegate = delegate
        return (view, delegate)
    }

    /// Feeds `text` the way the system does for autofill and paste: one `shouldChangeCharactersIn` call with the whole string.
    private func insert(_ text: String, into view: RegistrationVerificationCodeView) {
        _ = view.textField(UITextField(), shouldChangeCharactersIn: NSRange(location: 0, length: 0), replacementString: text)
    }

    func testAutofillOfTheWholeCodeFillsEveryDigit() {
        let (view, delegate) = makeCodeView()
        insert("482913", into: view)
        XCTAssertEqual(view.verificationCode, "482913")
        XCTAssertTrue(view.isComplete)
        XCTAssertEqual(delegate.changeCount, 1)
    }

    func testPastingTheWholeSMSExtractsTheCode() {
        let (view, _) = makeCodeView()
        insert("【Tellomi】您的验证码是 482913，5 分钟内有效。", into: view)
        XCTAssertEqual(view.verificationCode, "482913")
    }

    func testPastingAFewDigitsContinuesFromTheCurrentDigit() {
        let (view, _) = makeCodeView()
        insert("4", into: view)
        insert("82", into: view)
        XCTAssertEqual(view.verificationCode, "482")
        XCTAssertFalse(view.isComplete)
    }

    func testTypingOneDigitAtATimeStillWorks() {
        let (view, _) = makeCodeView()
        for digit in "482913" {
            insert(String(digit), into: view)
        }
        XCTAssertEqual(view.verificationCode, "482913")
    }

    // MARK: - "Didn't get the code?" sheet

    private func texts(in view: UIView) -> [String] {
        var result: [String] = []
        if let label = view as? UILabel, let text = label.text {
            result.append(text)
        }
        if let button = view as? UIButton, let title = button.configuration?.title {
            result.append(title)
        }
        for subview in view.subviews {
            result += texts(in: subview)
        }
        return result
    }

    private func button(withIdentifier identifier: String, in view: UIView) -> UIButton? {
        if let button = view as? UIButton, button.accessibilityIdentifier == identifier {
            return button
        }
        for subview in view.subviews {
            if let found = button(withIdentifier: identifier, in: subview) {
                return found
            }
        }
        return nil
    }

    func testTellomiHelpSheetOffersWaysOut() throws {
        var changedNumber = 0
        var contactedSupport = 0
        let sheet = RegistrationVerificationHelpSheetViewController(tellomiHelp: .init(
            phoneNumber: "+86 138 0013 8000",
            onChangeNumber: { changedNumber += 1 },
            onContactSupport: { contactedSupport += 1 },
        ))
        sheet.loadViewIfNeeded()
        let shown = texts(in: sheet.view)
        let joined = shown.joined(separator: "\n")

        XCTAssertTrue(shown.contains(RegistrationVerificationHelpSheetViewController.tellomiTitle), joined)
        XCTAssertTrue(joined.contains("+86 138 0013 8000"), joined)
        XCTAssertTrue(joined.contains("support@tellomi.app"), joined)
        if let quota = TSConstants.smsVerificationCodesPerSession {
            XCTAssertTrue(joined.contains(String(quota)), joined)
        }
        // 上游那三条通用提示不再出现。
        XCTAssertFalse(shown.contains(OWSLocalizedString("ONBOARDING_VERIFICATION_HELP_BULLET_2", comment: "")), joined)

        try XCTUnwrap(button(withIdentifier: "registration.verification.help.changeNumber", in: sheet.view))
            .sendActions(for: .primaryActionTriggered)
        try XCTUnwrap(button(withIdentifier: "registration.verification.help.contactSupport", in: sheet.view))
            .sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(changedNumber, 1)
        XCTAssertEqual(contactedSupport, 1)
    }

    func testHongKongDeploymentAllowsThreeCodesPerSession() {
        // deploy/hk/enable-aliyun-sms.sh：send-sms-verification-code.delays: [30s, 1m, 5m]
        XCTAssertEqual(TSConstants.smsVerificationCodesPerSession, 3)
    }
}
