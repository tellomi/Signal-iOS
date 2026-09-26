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
    private let hongKong = PhoneNumberCountry(countryName: "Hong Kong", plusPrefixedCallingCode: "+852", countryCode: "HK")
    private let taiwan = PhoneNumberCountry(countryName: "Taiwan", plusPrefixedCallingCode: "+886", countryCode: "TW")
    private let germany = PhoneNumberCountry(countryName: "Germany", plusPrefixedCallingCode: "+49", countryCode: "DE")
    private let austria = PhoneNumberCountry(countryName: "Austria", plusPrefixedCallingCode: "+43", countryCode: "AT")
    // libphonenumber 不认的两个地区：区号借用美国 / 西班牙的
    private let usOutlyingIslands = PhoneNumberCountry(countryName: "U.S. Outlying Islands", plusPrefixedCallingCode: "+1", countryCode: "UM")
    private let canaryIslands = PhoneNumberCountry(countryName: "Canary Islands", plusPrefixedCallingCode: "+34", countryCode: "IC")

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

    func testNumbersCopiedWithDirectionMarksOrOddSeparatorsStillSplit() throws {
        // taishi 审查 b12 疑问 1：从通讯录 / 电话复制的号码两头可能带 U+202D / U+202C；全角「＋」、点、不断行连字符同理。
        for text in ["\u{202D}+86 138 0013 8000\u{202C}", "＋86 138 0013 8000", "+86.138.0013.8000", "+86 138\u{2011}0013\u{2011}8000"] {
            let parsed = try XCTUnwrap(fullNumber(text, in: china), text.debugDescription)
            XCTAssertEqual(parsed.country.countryCode, "CN", text.debugDescription)
            XCTAssertEqual(parsed.nationalNumber, "13800138000", text.debugDescription)
        }
    }

    func testFullWidthPlusAndDigitsAreReadAsHalfWidth() throws {
        // taishi 审查 b20 不阻塞 1：选的是美国，粘「＋86 138 0013 8000」也要拆出中国。以前全角「＋」被 filteredAsE164 丢掉，
        // 只有当前地区恰好是中国时才靠「以区号开头」那条碰巧拆开（上面那条用例在中国下就是这样绿的）；全角数字则整串被丢。
        for text in ["＋86 138 0013 8000", "＋８６ １３８ ００１３ ８０００", "００８６ １３８ ００１３ ８０００"] {
            let parsed = try XCTUnwrap(fullNumber(text, in: unitedStates), text)
            XCTAssertEqual(parsed.country.countryCode, "CN", text)
            XCTAssertEqual(parsed.nationalNumber, "13800138000", text)
        }
        let wholeField = try XCTUnwrap(RegistrationPhoneNumberInputView.tellomiFullPhoneNumber(
            inField: "００８６13800138000",
            phoneNumberUtil: SSKEnvironment.shared.phoneNumberUtilRef,
        ))
        XCTAssertEqual(wholeField.country.countryCode, "CN")
        XCTAssertEqual(RegistrationPhoneNumberInputView.tellomiHalfWidth("＋８６ １３８-０"), "+86 138-0")
    }

    func testTaiwanNumbersWithoutPlusSplitToo() throws {
        // 台湾的本国格式带长途前缀 0（0912 345 678）。以前按「本国格式示例号码的位数」比，「886912345678」判不出来。
        for text in ["886912345678", "+886 912 345 678"] {
            let parsed = try XCTUnwrap(fullNumber(text, in: taiwan), text)
            XCTAssertEqual(parsed.country.countryCode, "TW", text)
            XCTAssertEqual(parsed.nationalNumber, "912345678", text)
        }
    }

    func testFragmentsThatAreOnlyPossibleNumbersAreLeftAlone() {
        // 「8613800138」按 isPossibleNumber 算得上 +86 13800138，但不是有效号码；「0013 8000 1234」去掉 00 也不是。和 Android 同一道闸。
        XCTAssertNil(fullNumber("8613800138", in: china))
        XCTAssertNil(fullNumber("0013 8000 1234", in: china))
    }

    func testNumbersStartingWithTheCallingCodeSplitOnlyWhenAsLongAsTheRegionsExampleNumber() throws {
        // 两端共用样例，Android 的 TellomiPhoneNumberPasteTest 是同一组：以区号开头、没有 + / 00 的一串。
        let splits: [(PhoneNumberCountry, String, String)] = [
            (china, "8613800138000", "13800138000"),
            (hongKong, "85291234567", "91234567"),
            (unitedStates, "14155550100", "4155550100"),
            (taiwan, "886912345678", "912345678"),
        ]
        for (country, text, national) in splits {
            let parsed = try XCTUnwrap(fullNumber(text, in: country), text)
            XCTAssertEqual(parsed.country.countryCode, country.countryCode, text)
            XCTAssertEqual(parsed.nationalNumber, national, text)
        }
        // DE / AT：去掉「区号」后也是有效号码，但位数和示例号码不同，不当完整号码拆（taishi 审查 b18 不阻塞 3）。
        XCTAssertNil(fullNumber("4921123456", in: germany))
        XCTAssertNil(fullNumber("4312345678", in: austria))
    }

    func testRegionsLibPhoneNumberDoesNotKnowBorrowTheirCallingCodesExample() throws {
        // 手动选了 UM / IC 这类 libphonenumber 不认的地区：示例号码按同区号、认得的地区取（上游 countryCodeForParsing），
        // 不然取不到示例位数，以区号开头的整串就拆不开（taishi 审查 b12 不阻塞 5）。
        let splits: [(PhoneNumberCountry, String, String, String)] = [
            (usOutlyingIslands, "14155550100", "+1", "4155550100"),
            (canaryIslands, "34612345678", "+34", "612345678"),
        ]
        for (country, text, callingCode, national) in splits {
            let parsed = try XCTUnwrap(fullNumber(text, in: country), text)
            XCTAssertEqual(parsed.country.plusPrefixedCallingCode, callingCode, text)
            XCTAssertEqual(parsed.nationalNumber, national, text)
        }
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

    func testZeroZeroInFrontOfTheWholeFieldSplitsItToo() throws {
        // 两端共用样例（Android 靠整框的 00 判断，taishi 审查 b18 不阻塞 2）。
        let view = RegistrationPhoneNumberInputView(initialPhoneNumber: RegistrationPhoneNumber(country: china, nationalNumber: "13800138000"))
        let field = try XCTUnwrap(textField(in: view))

        // 在已有号码前面补「0086」：插进来的只有「0086」，要看整框。
        let accepted = view.textField(field, shouldChangeCharactersIn: NSRange(location: 0, length: 0), replacementString: "0086")
        XCTAssertFalse(accepted)
        XCTAssertEqual(view.nationalNumber, "13800138000")
        XCTAssertEqual(view.country.countryCode, "CN")

        // 全选再粘：iOS 拿到的就是整段粘贴的文字，本来就拆。
        let all = NSRange(location: 0, length: (field.text ?? "").utf16.count)
        _ = view.textField(field, shouldChangeCharactersIn: all, replacementString: "0086 139 0013 9000")
        XCTAssertEqual(view.nationalNumber, "13900139000")
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
