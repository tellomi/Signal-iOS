//
// Copyright 2026 Tellomi
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// Tellomi（tellomi/tellomi#1213）：注册手机号输入框——粘贴 / 自动填充进来的完整号码拆出区号；清空 × 要通知页面。
@MainActor
final class TellomiPhoneNumberInputTest: SignalBaseTest {

    private final class Delegate: RegistrationPhoneNumberInputViewDelegate {
        var changeCount = 0
        var onChange: (() -> Void)?
        func present(_ countryCodeViewController: CountryCodeViewController) {}
        func didChange() {
            changeCount += 1
            onChange?()
        }

        func didPressReturn() {}
    }

    private let china = PhoneNumberCountry(countryName: "China", plusPrefixedCallingCode: "+86", countryCode: "CN")
    private let unitedStates = PhoneNumberCountry(countryName: "United States", plusPrefixedCallingCode: "+1", countryCode: "US")

    private func fullNumber(_ text: String, in country: PhoneNumberCountry) -> RegistrationPhoneNumber? {
        RegistrationPhoneNumberInputView.tellomiFullPhoneNumber(
            in: text,
            currentCountry: country,
            phoneNumberUtil: SSKEnvironment.shared.phoneNumberUtilRef,
        )
    }

    func testFullNumbersInTheFormsPeopleCopy() throws {
        for text in ["+86 138 0013 8000", "+8613800138000", "0086 138 0013 8000", "008613800138000", "8613800138000", "86 138-0013-8000"] {
            let parsed = try XCTUnwrap(fullNumber(text, in: china), text)
            XCTAssertEqual(parsed.country.countryCode, "CN", text)
            XCTAssertEqual(parsed.nationalNumber, "13800138000", text)
        }
        let hongKong = try XCTUnwrap(fullNumber("+852 9123 4567", in: china))
        XCTAssertEqual(hongKong.country.countryCode, "HK")
        XCTAssertEqual(hongKong.nationalNumber, "91234567")

        let american = try XCTUnwrap(fullNumber("1 415 555 0100", in: unitedStates))
        XCTAssertEqual(american.country.countryCode, "US")
        XCTAssertEqual(american.nationalNumber, "4155550100")
    }

    func testPlainNationalNumbersAreLeftAlone() {
        // 本地号码本身、太短的片段都不当完整号码。
        XCTAssertNil(fullNumber("13800138000", in: china))
        XCTAssertNil(fullNumber("138 0013 8000", in: china))
        XCTAssertNil(fullNumber("86138", in: china))
        XCTAssertNil(fullNumber("4155550100", in: unitedStates))
    }

    // MARK: - The view

    private func textField(in view: UIView) -> UITextField? {
        if let field = view as? UITextField {
            return field
        }
        for subview in view.subviews {
            if let found = textField(in: subview) {
                return found
            }
        }
        return nil
    }

    func testPastingAFullNumberIntoANonEmptyFieldReplacesIt() throws {
        let view = RegistrationPhoneNumberInputView(initialPhoneNumber: RegistrationPhoneNumber(country: china, nationalNumber: "138"))
        let delegate = Delegate()
        view.delegate = delegate
        let field = try XCTUnwrap(textField(in: view))
        let end = (field.text ?? "").utf16.count

        let accepted = view.textField(field, shouldChangeCharactersIn: NSRange(location: end, length: 0), replacementString: "+86 139 0000 0000")

        XCTAssertFalse(accepted)
        XCTAssertEqual(view.nationalNumber, "13900000000")
        XCTAssertEqual(view.country.countryCode, "CN")
        XCTAssertEqual(delegate.changeCount, 1)
    }

    func testPastingWithoutPlusSplitsTheCallingCode() throws {
        let view = RegistrationPhoneNumberInputView(initialPhoneNumber: RegistrationPhoneNumber(country: china, nationalNumber: ""))
        let field = try XCTUnwrap(textField(in: view))

        _ = view.textField(field, shouldChangeCharactersIn: NSRange(location: 0, length: 0), replacementString: "008613900000000")

        XCTAssertEqual(view.nationalNumber, "13900000000")
    }

    func testClearButtonTellsThePage() throws {
        let view = RegistrationPhoneNumberInputView(initialPhoneNumber: RegistrationPhoneNumber(country: china, nationalNumber: "13800138000"))
        let delegate = Delegate()
        view.delegate = delegate
        let field = try XCTUnwrap(textField(in: view))
        XCTAssertEqual(field.clearButtonMode, .whileEditing)

        let notified = expectation(description: "didChange after clearing")
        delegate.onChange = { notified.fulfill() }
        XCTAssertTrue(view.textFieldShouldClear(field))
        wait(for: [notified], timeout: 2)
    }
}
