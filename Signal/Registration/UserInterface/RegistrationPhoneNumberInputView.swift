//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

protocol RegistrationPhoneNumberInputViewDelegate: AnyObject {
    func present(_ countryCodeViewController: CountryCodeViewController)
    func didChange()
    func didPressReturn()
}

class RegistrationPhoneNumberInputView: UIView {
    weak var delegate: RegistrationPhoneNumberInputViewDelegate?

    // We impose a limit on the number of digits. This is much higher than what a valid E164 allows
    // and is just here for safety.
    private let maxNationalNumberDigits = 50

    init(initialPhoneNumber: RegistrationPhoneNumber) {
        self.country = initialPhoneNumber.country

        super.init(frame: .zero)

        layoutMargins = .init(hMargin: 16, vMargin: 9)

        // Background
        let backgroundView = UIView()
        if #available(iOS 26, *) {
            backgroundView.cornerConfiguration = .capsule()
        } else {
            backgroundView.layer.cornerRadius = 10
        }
        backgroundView.backgroundColor = .Signal.secondaryBackground
        addSubview(backgroundView)
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        // Content view (horizontal stack).
        let dividerView = UIView()
        dividerView.backgroundColor = .Signal.secondaryLabel

        let stackView = UIStackView(arrangedSubviews: [countryCodeView, dividerView, nationalNumberView])
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.distribution = .fill
        stackView.spacing = 16
        addSubview(stackView)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dividerView.widthAnchor.constraint(equalToConstant: hairlineWidth),
            dividerView.heightAnchor.constraint(equalTo: stackView.heightAnchor),

            stackView.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
            stackView.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            stackView.bottomAnchor.constraint(equalTo: layoutMarginsGuide.bottomAnchor),
            stackView.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
        ])

        nationalNumberView.text = formatNationalNumber(input: initialPhoneNumber.nationalNumber)
        update()
    }

    @available(*, unavailable, message: "use other constructor")
    required init(coder: NSCoder) {
        owsFail("init(coder:) has not been implemented")
    }

    // MARK: - Data

    private(set) var country: PhoneNumberCountry {
        didSet { update() }
    }

    var nationalNumber: String { nationalNumberView.text?.asciiDigitsOnly ?? "" }

    var phoneNumber: RegistrationPhoneNumber {
        return RegistrationPhoneNumber(country: country, nationalNumber: nationalNumber)
    }

    var isEnabled: Bool = true {
        didSet {
            if !isEnabled {
                nationalNumberView.resignFirstResponder()
            }
            update()
        }
    }

    // MARK: - Rendering

    private lazy var countryCodeLabel: UILabel = {
        let result = UILabel()
        result.font = .dynamicTypeBodyClamped
        result.textAlignment = .center
        result.textColor = .Signal.label
        result.setCompressionResistanceHigh()
        result.setContentHuggingHorizontalHigh()
        return result
    }()

    private lazy var countryCodeView: UIView = {
        let container = UIView.container()

        container.addSubview(countryCodeLabel)
        countryCodeLabel.translatesAutoresizingMaskIntoConstraints = false

        var chevronIcon = UIImageView(image: UIImage(imageLiteralResourceName: "chevron-down-extra-small"))
        chevronIcon.tintColor = .Signal.secondaryLabel
        container.addSubview(chevronIcon)
        chevronIcon.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            countryCodeLabel.topAnchor.constraint(greaterThanOrEqualTo: container.topAnchor),
            countryCodeLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            countryCodeLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            chevronIcon.widthAnchor.constraint(equalToConstant: 12),
            chevronIcon.heightAnchor.constraint(equalToConstant: 12),
            chevronIcon.leadingAnchor.constraint(equalTo: countryCodeLabel.trailingAnchor, constant: 9),
            chevronIcon.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            chevronIcon.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        container.isUserInteractionEnabled = true
        container.addGestureRecognizer(UITapGestureRecognizer(
            target: self,
            action: #selector(didTapCountryCode),
        ))

        container.isAccessibilityElement = true
        container.accessibilityTraits = .button
        container.accessibilityIdentifier = "registration.phonenumber.countryCode"
        container.accessibilityLabel = OWSLocalizedString(
            "REGISTRATION_DEFAULT_COUNTRY_NAME",
            comment: "Label for the country code field",
        )

        return container
    }()

    private lazy var nationalNumberView: UITextField = {
        let result = UITextField()
        result.font = .dynamicTypeBodyClamped
        result.textAlignment = .left
        result.textColor = .Signal.label
        result.textContentType = .telephoneNumber
        result.keyboardType = .phonePad
        // Tellomi（tellomi/tellomi#1213，ADR-0051 §C）：非空时有清空 ×。
        result.clearButtonMode = .whileEditing
        result.placeholder = OWSLocalizedString(
            "ONBOARDING_PHONE_NUMBER_PLACEHOLDER",
            comment: "Placeholder string for phone number field during registration",
        )
        result.delegate = self
        return result
    }()

    private func update() {
        countryCodeLabel.text = country.plusPrefixedCallingCode
        countryCodeView.accessibilityValue = countryCodeLabel.text
        nationalNumberView.isEnabled = isEnabled
    }

    // MARK: - Events

    @objc
    private func didTapCountryCode(sender: UIGestureRecognizer) {
        guard isEnabled, sender.state == .recognized, let delegate else { return }

        let countryCodeViewController = CountryCodeViewController(delegate: self)
        countryCodeViewController.interfaceOrientationMask = UIDevice.current.isIPad ? .all : .portrait

        delegate.present(countryCodeViewController)
    }

    // MARK: - Responder pass-through

    override var isFirstResponder: Bool { nationalNumberView.isFirstResponder }

    override var canBecomeFirstResponder: Bool { nationalNumberView.canBecomeFirstResponder }

    @discardableResult
    override func becomeFirstResponder() -> Bool { nationalNumberView.becomeFirstResponder() }

    @discardableResult
    override func resignFirstResponder() -> Bool { nationalNumberView.resignFirstResponder() }
}

// MARK: - UITextFieldDelegate

extension RegistrationPhoneNumberInputView: UITextFieldDelegate {
    func textField(
        _ textField: UITextField,
        shouldChangeCharactersIn range: NSRange,
        replacementString: String,
    ) -> Bool {
        // Tellomi（tellomi/tellomi#1213）：一次进来一整串（粘贴 / 自动填充）就当完整号码解析一次（Telegram PhoneInputNode
        // 同样把多字符插入当完整号码重新解析区号）。上游只在输入框为空、而且带「+」时这样做；框里已经有字，或者是
        // 「0086…」「86…」这种写法，会被原样接到后面，变成十几位的无效号码。
        if
            replacementString.count > 1,
            let phoneNumber = Self.tellomiFullPhoneNumber(
                in: replacementString,
                currentCountry: country,
                phoneNumberUtil: SSKEnvironment.shared.phoneNumberUtilRef,
            )
        {
            country = phoneNumber.country
            textField.text = formatNationalNumber(input: phoneNumber.nationalNumber)
            delegate?.didChange()
            return false
        }

        let wasEmpty = textField.text.isEmptyOrNil
        var replacementString = replacementString

        if
            textField.text.isEmptyOrNil,
            let fullE164 = E164(replacementString.removeCharacters(characterSet: CharacterSet(charactersIn: " -()"))),
            let phoneNumber = RegistrationPhoneNumberParser(phoneNumberUtil: SSKEnvironment.shared.phoneNumberUtilRef).parseE164(fullE164)
        {
            // If we got a full e164, it was probably from system autofill.
            // Split out the country code portion.
            self.country = phoneNumber.country
            replacementString = phoneNumber.nationalNumber
        }

        let oldValue = textField.text!

        let result = FormattedNumberField.textField(
            textField,
            shouldChangeCharactersIn: range,
            replacementString: replacementString,
            allowedCharacters: .numbers,
            maxCharacters: maxNationalNumberDigits,
            format: formatNationalNumber,
        )

        if wasEmpty {
            DispatchQueue.main.async {
                // Move the cursor back to the end.
                textField.selectedTextRange = textField.textRange(
                    from: textField.endOfDocument,
                    to: textField.endOfDocument,
                )
            }
        }

        let newValue = textField.text!

        if newValue != oldValue {
            delegate?.didChange()
        }

        return result
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        delegate?.didPressReturn()
        return false
    }

    func textFieldShouldClear(_ textField: UITextField) -> Bool {
        // Tellomi（tellomi/tellomi#1213）：清空 × 不经过 shouldChangeCharactersIn，要自己通知一次，
        // 否则「下一步」的可用状态和号码校验不跟着变。
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.didChange()
        }
        return true
    }

    /// Tellomi：把一段文字当完整号码解析——「+86 138 0013 8000」「0086 138…」，或者以当前区号开头的「8613800138000」；
    /// 去掉前缀后必须是有效号码。都不是就返回 nil，按普通输入处理。Android 的 PhoneNumberEntryViewModel.tellomiFullNumberInserted 是同一套规则。
    static func tellomiFullPhoneNumber(
        in text: String,
        currentCountry: PhoneNumberCountry,
        phoneNumberUtil: PhoneNumberUtil,
    ) -> RegistrationPhoneNumber? {
        // 只留开头的「+」和 ASCII 数字：从通讯录 / 电话复制的号码两头可能带 U+202D / U+202C，
        // 中间可能有不断行连字符、点、全角「＋」（taishi 审查 b12 疑问 1）。
        let compact = text.filteredAsE164
        let international: String
        if compact.hasPrefix("+") {
            international = compact
        } else if compact.hasPrefix("00") {
            international = "+" + compact.dropFirst(2)
        } else {
            let callingCode = String(currentCountry.plusPrefixedCallingCode.dropFirst())
            guard compact.hasPrefix(callingCode) else {
                return nil
            }
            international = "+" + compact
        }
        // 去掉前缀后还得是有效号码，和 Android 同一道闸：「8613800138」「0013 8000 1234」这种片段不当完整号码拆。
        // 以前比的是「本国格式的示例号码位数」，台湾的本国格式带长途前缀 0（0912 345 678），「886912345678」判不出来。
        guard let e164 = E164(international), phoneNumberUtil.isValidNumber(e164) else {
            return nil
        }
        return RegistrationPhoneNumberParser(phoneNumberUtil: phoneNumberUtil).parseE164(e164)
    }

    private func formatNationalNumber(input: String) -> String {
        return PhoneNumber.bestEffortFormatPartialUserSpecifiedTextToLookLikeAPhoneNumber(input, plusPrefixedCallingCode: country.plusPrefixedCallingCode)
    }
}

// MARK: - CountryCodeViewControllerDelegate

extension RegistrationPhoneNumberInputView: CountryCodeViewControllerDelegate {
    func countryCodeViewController(
        _ vc: CountryCodeViewController,
        didSelectCountry country: PhoneNumberCountry,
    ) {
        self.country = country

        nationalNumberView.text = PhoneNumber.bestEffortFormatPartialUserSpecifiedTextToLookLikeAPhoneNumber(nationalNumber, plusPrefixedCallingCode: country.plusPrefixedCallingCode)

        delegate?.didChange()
    }
}
