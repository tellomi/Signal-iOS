//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SafariServices
import SignalServiceKit
import SignalUI

// MARK: - RegistrationPhoneNumberPresenter

protocol RegistrationPhoneNumberPresenter: RegistrationMethodPresenter {
    func goToNextStep(withE164: E164)

    func switchToDeviceLinking()

    /// Completely exit registration. Not to be confused with  `cancelChosenRestoreMethod`
    /// which returns to the splash screen.
    func exitRegistration()
}

// MARK: - RegistrationPhoneNumberViewController

class RegistrationPhoneNumberViewController: OWSViewController {
    init(
        state: RegistrationPhoneNumberViewState.RegistrationMode,
        presenter: RegistrationPhoneNumberPresenter,
    ) {
        self.state = state
        self.presenter = presenter

        self.phoneNumberInput = RegistrationPhoneNumberInputView(initialPhoneNumber: {
            switch state {
            case let .initialRegistration(state):
                if let e164 = state.previouslyEnteredE164, let result = RegistrationPhoneNumberParser(phoneNumberUtil: SSKEnvironment.shared.phoneNumberUtilRef).parseE164(e164) {
                    return result
                }
                return RegistrationPhoneNumber(
                    country: .defaultValue,
                    nationalNumber: "",
                )
            case let .reregistration(state):
                guard let result = RegistrationPhoneNumberParser(phoneNumberUtil: SSKEnvironment.shared.phoneNumberUtilRef).parseE164(state.e164) else {
                    owsFail("Could not parse re-registration E164")
                }
                return result
            }
        }())

        super.init()

        self.phoneNumberInput.delegate = self
    }

    func updateState(_ state: RegistrationPhoneNumberViewState.RegistrationMode) {
        self.state = state
    }

    @available(*, unavailable)
    override init() {
        owsFail("This should not be called")
    }

    deinit {
        nowTimer?.invalidate()
        nowTimer = nil
    }

    // MARK: Internal state

    private var state: RegistrationPhoneNumberViewState.RegistrationMode {
        didSet { configureUI() }
    }

    private weak var presenter: RegistrationPhoneNumberPresenter?

    private var nowTimer: Timer?

    private var nationalNumber: String { phoneNumberInput.nationalNumber }

    private var countryCode: String {
        return phoneNumberInput.country.countryCode
    }

    private var localValidationError: RegistrationPhoneNumberViewState.ValidationError? {
        didSet { configureUI() }
    }

    private var validationError: RegistrationPhoneNumberViewState.ValidationError? {
        switch state {
        case .initialRegistration(let initialRegistration):
            return initialRegistration.validationError ?? localValidationError
        case .reregistration(let reregistration):
            return reregistration.validationError ?? localValidationError
        }
    }

    private var canChangePhoneNumber: Bool {
        switch state {
        case .initialRegistration:
            return true
        case .reregistration:
            return false
        }
    }

    private func canSubmit(isBlockedByValidationError: Bool) -> Bool {
        if phoneNumberInput.nationalNumber.isEmpty {
            return false
        }

        switch state {
        case .initialRegistration:
            return !isBlockedByValidationError
        case .reregistration:
            return true
        }
    }

    private func explanationText() -> String {
        if canChangePhoneNumber {
            return OWSLocalizedString(
                "REGISTRATION_PHONE_NUMBER_SUBTITLE",
                comment: "During registration, users are asked to enter their phone number. This is the subtitle on that screen, which gives users some instructions.",
            )
        }
        return OWSLocalizedString(
            "REGISTRATION_PHONE_NUMBER_SUBTITLE_2",
            comment: "During re-registration, users are asked to confirm their phone number. This is the subtitle on that screen, which gives users some instructions.",
        )
    }

    // MARK: UI

    private lazy var titleLabel: UILabel = {
        let result = UILabel.titleLabelForRegistration(text: OWSLocalizedString(
            "REGISTRATION_PHONE_NUMBER_TITLE",
            comment: "During registration, users are asked to enter their phone number. This is the title on that screen.",
        ))
        result.accessibilityIdentifier = "registration.phonenumber.titleLabel"
        return result
    }()

    private lazy var explanationLabel: UILabel = {
        let result = UILabel.explanationLabelForRegistration(text: explanationText())
        result.accessibilityIdentifier = "registration.phonenumber.explanationLabel"
        return result
    }()

    private let phoneNumberInput: RegistrationPhoneNumberInputView

    private lazy var validationWarningLabel: UILabel = {
        let result = UILabel()
        result.textColor = .Signal.red
        result.numberOfLines = 0
        result.font = .dynamicTypeSubheadlineClamped
        result.accessibilityIdentifier = "registration.phonenumber.validationWarningLabel"
        return result
    }()

    private lazy var cancelButton = UIButton(
        configuration: .mediumSecondary(title: CommonStrings.cancelButton),
        primaryAction: UIAction { [weak self] _ in
            self?.phoneNumberInput.resignFirstResponder()
            self?.presenter?.cancelChosenRestoreMethod()
        },
    )

    /// Tellomi：协议行，默认不勾（tellomi/tellomi#1211；ADR-0038 · ADR-0051 §E）。
    private lazy var consentRow: TellomiConsentRow = {
        let result = TellomiConsentRow()
        result.onOpenURL = { [weak self] url in
            self?.present(SFSafariViewController(url: url), animated: true)
        }
        return result
    }()

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .Signal.background

        navigationItem.rightBarButtonItem = .nextButton { [weak self] in
            self?.didTapNext()
        }

        let stackView = addStaticContentStackView(
            arrangedSubviews: [
                titleLabel,
                explanationLabel,
                phoneNumberInput,
                validationWarningLabel,
                .vStretchingSpacer(),
                consentRow,
                cancelButton.enclosedInVerticalStackView(isFullWidthButton: false),
            ],
            shouldAvoidKeyboard: true,
        )
        stackView.setCustomSpacing(24, after: explanationLabel)
        stackView.setCustomSpacing(16, after: consentRow)

        configureUI()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        Logger.info("")

        let shouldBecomeFirstResponder: Bool = {
            switch validationError {
            case .rateLimited:
                return false
            case nil, .invalidInput, .invalidE164:
                break
            }

            switch state {
            case .reregistration:
                return false
            case .initialRegistration:
                return true
            }
        }()
        if shouldBecomeFirstResponder {
            phoneNumberInput.becomeFirstResponder()
        }
    }

    private func configureUI() {
        var actions: [UIAction] = [
            UIAction(
                title: OWSLocalizedString(
                    "USE_PROXY_BUTTON",
                    comment: "Button to activate the signal proxy",
                ),
                handler: { [weak self] _ in
                    guard let self else { return }
                    let vc = ProxySettingsViewController()
                    self.presentFormSheet(OWSNavigationController(rootViewController: vc), animated: true)
                },
            ),
        ]
        let canCancelChosenRegistrationMethod: Bool
        let canSwitchToLinking: Bool
        let canExitRegistration: Bool
        switch state {
        case .initialRegistration(let subState):
            canCancelChosenRegistrationMethod = true
            canSwitchToLinking = true
            canExitRegistration = subState.canExitRegistration
            Logger.debug("initialRegistration")
        case .reregistration(let subState):
            canCancelChosenRegistrationMethod = false
            canSwitchToLinking = false
            canExitRegistration = subState.canExitRegistration
            Logger.debug("reregistration")
        }

        if canSwitchToLinking {
            actions.insert(UIAction(
                title: OWSLocalizedString(
                    "LINK_DEVICE_MENU_ACTION",
                    comment: "Menu action on the phone number entry screen to link this device as a secondary device.",
                ),
                handler: { [weak presenter] _ in
                    presenter?.switchToDeviceLinking()
                },
            ), at: 0)
        }

        cancelButton.isHidden = !canCancelChosenRegistrationMethod
        cancelButton.isEnabled = canCancelChosenRegistrationMethod

        if canExitRegistration {
            actions.append(UIAction(
                title: OWSLocalizedString(
                    "EXIT_REREGISTRATION",
                    comment: "Button to exit re-registration, shown in context menu.",
                ),
                handler: { [weak self] _ in
                    self?.presenter?.exitRegistration()
                },
            ))
        }

        navigationItem.leftBarButtonItem = .contextMenuButton(actions: actions)

        let now = Date()

        let isBlockedByValidationError = { () -> Bool in
            switch validationError {
            case let .invalidInput(error):
                return !error.canSubmit(countryCode: countryCode, nationalNumber: nationalNumber)
            case let .invalidE164(error):
                return !error.canSubmit(e164: parseE164())
            case let .rateLimited(error):
                return !error.canSubmit(e164: parseE164(), dateProvider: { now })
            case nil:
                return false
            }
        }()

        if isBlockedByValidationError, case .rateLimited = validationError {
            if nowTimer == nil {
                nowTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    self?.configureUI()
                }
            }
        } else {
            nowTimer?.invalidate()
            nowTimer = nil
        }

        navigationItem.rightBarButtonItem?.isEnabled = canSubmit(isBlockedByValidationError: isBlockedByValidationError)

        phoneNumberInput.isEnabled = canChangePhoneNumber

        explanationLabel.text = explanationText()

        // We always render the warning label but sometimes invisibly. This avoids UI jumpiness.
        if isBlockedByValidationError, let validationError {
            validationWarningLabel.alpha = 1
            validationWarningLabel.text = validationError.warningLabelText(dateProvider: { now })
        } else {
            validationWarningLabel.alpha = 0
        }
        switch validationError {
        case nil, .rateLimited:
            break
        case let .invalidInput(error):
            showInvalidPhoneNumberAlertIfNecessary(for: .invalidInput(countryCode: error.invalidCountryCode, nationalNumber: error.invalidNationalNumber))
        case let .invalidE164(error):
            showInvalidPhoneNumberAlertIfNecessary(for: .invalidE164(error.invalidE164))
        }
    }

    private enum InvalidNumberError: Equatable {
        case invalidInput(countryCode: String, nationalNumber: String)
        case invalidE164(E164)
    }

    private var previousInvalidNumberError: InvalidNumberError?

    private func showInvalidPhoneNumberAlertIfNecessary(for invalidNumberError: InvalidNumberError) {
        let shouldShowAlert = invalidNumberError != previousInvalidNumberError
        if shouldShowAlert {
            OWSActionSheets.showActionSheet(
                title: OWSLocalizedString(
                    "REGISTRATION_VIEW_INVALID_PHONE_NUMBER_ALERT_TITLE",
                    comment: "Title of alert indicating that users needs to enter a valid phone number to register.",
                ),
                message: OWSLocalizedString(
                    "REGISTRATION_VIEW_INVALID_PHONE_NUMBER_ALERT_MESSAGE",
                    comment: "Message of alert indicating that users needs to enter a valid phone number to register.",
                ),
            )
        }

        previousInvalidNumberError = invalidNumberError
    }

    // MARK: Events

    private func didTapNext() {
        goToNextStep()
    }

    private func parseE164() -> E164? {
        let phoneNumberUtil = SSKEnvironment.shared.phoneNumberUtilRef
        return E164(phoneNumberUtil.parsePhoneNumber(countryCode: countryCode, nationalNumber: nationalNumber)?.e164)
    }

    private func goToNextStep() {
        Logger.info("")

        phoneNumberInput.resignFirstResponder()

        guard let e164 = parseE164() else {
            localValidationError = .invalidInput(.init(invalidCountryCode: countryCode, invalidNationalNumber: nationalNumber))
            return
        }
        guard PhoneNumberValidator().isValidForRegistration(phoneNumber: e164) else {
            localValidationError = .invalidE164(.init(invalidE164: e164))
            return
        }
        localValidationError = nil

        // Tellomi：先同意、再发号码。没勾就点「下一步」→ 二次确认；同意 = 勾选框看得见地打勾后再继续，
        // 不同意 = 什么都不发生。客户端绝不静默替用户打勾（ADR-0051 §E；tellomi/tellomi#1211）。
        guard consentRow.isChecked else {
            presentTellomiTermsConsentDialog { [weak self] in
                guard let self else { return }
                self.consentRow.setChecked(true, animated: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.goToNextStep() }
            }
            return
        }

        // Tellomi：跨境单独告知与同意（tellomi/tellomi#1133）。手机号是第一条发往境外（香港）服务端的个人信息，
        // 所以这一页排在协议同意之后、发出号码之前；同意过同一版本就不再出现。
        guard TellomiCrossBorderConsent.hasAgreed else {
            presentTellomiCrossBorderNotice { [weak self] in
                self?.goToNextStep()
            }
            return
        }

        guard canChangePhoneNumber else {
            presenter?.goToNextStep(withE164: e164)
            return
        }

        presentActionSheet(.forRegistrationVerificationConfirmation(
            mode: .sms,
            e164: e164.stringValue,
            didConfirm: { [weak self] in self?.presenter?.goToNextStep(withE164: e164) },
            didRequestEdit: { [weak self] in self?.phoneNumberInput.becomeFirstResponder() },
        ))
    }
}

// MARK: - RegistrationPhoneNumberInputViewDelegate

extension RegistrationPhoneNumberViewController: RegistrationPhoneNumberInputViewDelegate {
    func present(_ countryCodeViewController: CountryCodeViewController) {
        let navController = OWSNavigationController(rootViewController: countryCodeViewController)
        present(navController, animated: true)
    }

    func didChange() {
        configureUI()
    }

    func didPressReturn() {
        goToNextStep()
    }
}

// MARK: - Tellomi：注册同意（tellomi/tellomi#1211；ADR-0038 · ADR-0051 §E）

/// owner 定的规则（ADR-0038 / ADR-0051 §E）：
/// - 勾选框默认不勾；没勾就点「下一步」→ 二次确认「同意并继续 / 不同意」，同意 = 勾选框看得见地打勾并继续；
///   **客户端绝不静默替用户打勾**。
/// - 第一次打开 App 先弹一次隐私提示（2019《App 违法违规收集使用个人信息行为认定方法》：
///   首次运行要用弹窗等明显方式提示隐私政策）。
/// - 只记在本机（文档版本 + 时间）；服务端留存与跨境告知（tellomi/tellomi#1133）一起设计。
enum TellomiLegalConsent {
    static let termsURL = URL(string: "https://tellomi.app/legal/terms/")!
    static let privacyURL = URL(string: "https://tellomi.app/legal/privacy/")!

    /// 《用户服务协议》《隐私政策》的版本（1.0.0，2026-09-11 生效）。
    /// 文本改版时改这里：记下的版本对不上，就会重新要求同意。
    static let documentsVersion = "1.0.0"

    private static let termsKey = "TellomiLegalConsent.termsAndPrivacy.version"
    private static let termsDateKey = "TellomiLegalConsent.termsAndPrivacy.date"
    private static let noticeKey = "TellomiLegalConsent.firstLaunchNotice.version"

    static var hasAgreedToTerms: Bool {
        UserDefaults.standard.string(forKey: termsKey) == documentsVersion
    }

    static func setAgreedToTerms(_ agreed: Bool) {
        let defaults = UserDefaults.standard
        if agreed {
            defaults.set(documentsVersion, forKey: termsKey)
            defaults.set(Date(), forKey: termsDateKey)
        } else {
            defaults.removeObject(forKey: termsKey)
            defaults.removeObject(forKey: termsDateKey)
        }
    }

    static var hasAcceptedFirstLaunchNotice: Bool {
        UserDefaults.standard.string(forKey: noticeKey) == documentsVersion
    }

    static func acceptFirstLaunchNotice() {
        UserDefaults.standard.set(documentsVersion, forKey: noticeKey)
    }

    static var termsLink: (String, URL) {
        (
            OWSLocalizedString(
                "TELLOMI_CONSENT_TERMS_LINK",
                comment: "Name of the Terms of Service document, shown as a tappable link inside consent sentences.",
            ),
            termsURL,
        )
    }

    static var privacyLink: (String, URL) {
        (
            OWSLocalizedString(
                "TELLOMI_CONSENT_PRIVACY_LINK",
                comment: "Name of the Privacy Policy document, shown as a tappable link inside consent sentences.",
            ),
            privacyURL,
        )
    }

    /// 把格式串里的 `%1$@`、`%2$@` 依次换成可点的文档链接。
    static func linkedSentence(format: String, links: [(String, URL)]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var remainder = Substring(format)
        while let range = remainder.range(of: #"%\d\$@"#, options: .regularExpression) {
            result.append(NSAttributedString(string: String(remainder[..<range.lowerBound])))
            let digit = remainder[range].dropFirst().prefix(while: { $0.isNumber })
            let index = (Int(digit) ?? 1) - 1
            if links.indices.contains(index) {
                result.append(NSAttributedString(string: links[index].0, attributes: [.link: links[index].1]))
            }
            remainder = remainder[range.upperBound...]
        }
        result.append(NSAttributedString(string: String(remainder)))
        return result
    }
}

/// 「○ 我已年满 18 周岁，已阅读并同意《用户服务协议》和《隐私政策》」这一行。
final class TellomiConsentRow: UIView {
    var onOpenURL: ((URL) -> Void)?

    private(set) var isChecked = TellomiLegalConsent.hasAgreedToTerms

    private let checkbox = UIButton(type: .system)

    private lazy var sentenceView: LinkingTextView = {
        let result = LinkingTextView(shouldInteractWithURL: { [weak self] url in
            self?.onOpenURL?(url)
            return false
        })
        result.attributedText = TellomiLegalConsent.linkedSentence(
            format: OWSLocalizedString(
                "TELLOMI_CONSENT_ROW_FORMAT",
                comment: "Consent sentence next to the checkbox during registration. Embeds {{Terms of Service}} and {{Privacy Policy}} as links.",
            ),
            links: [TellomiLegalConsent.termsLink, TellomiLegalConsent.privacyLink],
        )
        result.font = .dynamicTypeFootnote
        result.textColor = .Signal.secondaryLabel
        return result
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)

        checkbox.accessibilityLabel = OWSLocalizedString(
            "TELLOMI_CONSENT_CHECKBOX_ACCESSIBILITY_LABEL",
            comment: "Accessibility label for the consent checkbox during registration.",
        )
        checkbox.accessibilityIdentifier = "registration.phonenumber.consentCheckbox"
        checkbox.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.setChecked(!self.isChecked, animated: true)
        }, for: .primaryActionTriggered)

        let stack = UIStackView(arrangedSubviews: [checkbox, sentenceView])
        stack.axis = .horizontal
        stack.alignment = .top
        stack.spacing = 8
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            checkbox.widthAnchor.constraint(equalToConstant: 24),
            checkbox.heightAnchor.constraint(equalToConstant: 24),
        ])
        updateCheckbox()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        owsFail("Not implemented")
    }

    /// 勾上 = 记下同意（文档版本 + 时间）；取消勾 = 撤回。动画只在用户看得见的时候做。
    func setChecked(_ checked: Bool, animated: Bool) {
        isChecked = checked
        TellomiLegalConsent.setAgreedToTerms(checked)
        updateCheckbox()
        guard animated, checked, !UIAccessibility.isReduceMotionEnabled else { return }
        checkbox.transform = CGAffineTransform(scaleX: 1.35, y: 1.35)
        UIView.animate(
            withDuration: 0.4,
            delay: 0,
            usingSpringWithDamping: 0.45,
            initialSpringVelocity: 0,
            options: [.allowUserInteraction],
        ) {
            self.checkbox.transform = .identity
        }
    }

    private func updateCheckbox() {
        checkbox.setImage(UIImage(systemName: isChecked ? "checkmark.circle.fill" : "circle"), for: .normal)
        checkbox.tintColor = isChecked ? .Signal.label : .Signal.secondaryLabel
        checkbox.accessibilityValue = isChecked ? CommonStrings.yesButton : CommonStrings.noButton
    }
}

/// 居中的确认卡片：标题 + 带可点链接的正文 + 主按钮 + 次按钮。系统的 alert 正文里放不了可点的链接。
final class TellomiConsentDialogViewController: OWSViewController {
    private let titleText: String
    private let body: NSAttributedString
    private let primaryTitle: String
    private let secondaryTitle: String
    private let onPrimary: () -> Void
    private let onSecondary: (TellomiConsentDialogViewController) -> Void

    /// 卡片内边距。正文宽度 = 卡片宽度 − 左右边距，量正文高度时要用。
    private static let contentInsets = NSDirectionalEdgeInsets(top: 24, leading: 20, bottom: 12, trailing: 20)

    private let hintLabel = UILabel()
    private let card = UIView()
    private var bodyView: LinkingTextView?
    private var bodyHeightConstraint: NSLayoutConstraint?

    init(
        title: String,
        body: NSAttributedString,
        primaryTitle: String,
        secondaryTitle: String,
        onPrimary: @escaping () -> Void,
        onSecondary: @escaping (TellomiConsentDialogViewController) -> Void,
    ) {
        self.titleText = title
        self.body = body
        self.primaryTitle = primaryTitle
        self.secondaryTitle = secondaryTitle
        self.onPrimary = onPrimary
        self.onSecondary = onSecondary
        super.init()
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .Signal.backdrop

        let titleLabel = UILabel()
        titleLabel.text = titleText
        titleLabel.font = .dynamicTypeHeadline
        titleLabel.textColor = .Signal.label
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        let bodyView = LinkingTextView(shouldInteractWithURL: { [weak self] url in
            self?.present(SFSafariViewController(url: url), animated: true)
            return false
        })
        bodyView.attributedText = body
        bodyView.font = .dynamicTypeSubheadline
        bodyView.textColor = .Signal.secondaryLabel
        bodyView.textAlignment = .center
        // 正文不许把卡片撑宽：卡片宽度只由屏幕宽度定（见下面的 preferredWidth），正文按那个宽度折行。
        bodyView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.bodyView = bodyView
        let bodyHeight = bodyView.heightAnchor.constraint(equalToConstant: bodyView.font?.lineHeight ?? 20)
        bodyHeight.isActive = true
        self.bodyHeightConstraint = bodyHeight

        hintLabel.font = .dynamicTypeFootnote
        hintLabel.textColor = .Signal.secondaryLabel
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 0
        hintLabel.isHidden = true

        let primaryButton = UIButton(
            configuration: .largePrimary(title: primaryTitle),
            primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                let onPrimary = self.onPrimary
                self.dismiss(animated: true) { onPrimary() }
            },
        )
        primaryButton.accessibilityIdentifier = "tellomi.consentDialog.primary"

        let secondaryButton = UIButton(
            configuration: .mediumBorderless(title: secondaryTitle),
            primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                self.onSecondary(self)
            },
        )
        secondaryButton.accessibilityIdentifier = "tellomi.consentDialog.secondary"

        let stack = UIStackView(arrangedSubviews: [titleLabel, bodyView, hintLabel, primaryButton, secondaryButton])
        stack.axis = .vertical
        stack.spacing = 12
        stack.setCustomSpacing(20, after: bodyView)
        stack.setCustomSpacing(16, after: hintLabel)
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = Self.contentInsets

        // 浅色白、深色 #1C1C1E。overFullScreen 呈现不带 elevated 特征，用 .Signal.background 在深色下是纯黑，
        // 和后面的黑底融成一片、看不出卡片（模拟器深色实测）。
        card.backgroundColor = .Signal.secondaryGroupedBackground
        card.layer.cornerRadius = 24
        card.layer.cornerCurve = .continuous
        card.addSubview(stack)
        view.addSubview(card)

        stack.translatesAutoresizingMaskIntoConstraints = false
        card.translatesAutoresizingMaskIntoConstraints = false
        let preferredWidth = card.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -64)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            preferredWidth,
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 不滚动的 UITextView 在 stack 里自己报的高度靠不住：正文只比一行稍长时（「请阅读并同意《用户服务协议》和《隐私政策》」），
        // 模拟器实测折成了两行、高度却只有一行，《隐私政策》被裁掉。这个回调里正文自己还没排版（实测宽度 0），
        // 卡片已经有宽度了——按卡片宽度减边距量出正文高度，直接写进高度约束。
        guard let bodyView, let bodyHeightConstraint else { return }
        let bodyWidth = card.bounds.width - Self.contentInsets.leading - Self.contentInsets.trailing
        guard bodyWidth > 0 else { return }
        let fitting = ceil(bodyView.sizeThatFits(CGSize(width: bodyWidth, height: .greatestFiniteMagnitude)).height)
        if bodyHeightConstraint.constant != fitting {
            bodyHeightConstraint.constant = fitting
        }
    }

    func showHint(_ text: String) {
        hintLabel.text = text
        hintLabel.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: text)
    }
}

extension UIViewController {
    /// 没勾协议就点主按钮时的二次确认（ADR-0051 §E）。「不同意」= 什么都不发生。
    func presentTellomiTermsConsentDialog(onAgree: @escaping () -> Void) {
        let dialog = TellomiConsentDialogViewController(
            title: OWSLocalizedString(
                "TELLOMI_CONSENT_DIALOG_TITLE",
                comment: "Title of the dialog asking the user to agree to the Terms of Service and Privacy Policy before continuing registration.",
            ),
            body: TellomiLegalConsent.linkedSentence(
                format: OWSLocalizedString(
                    "TELLOMI_CONSENT_DIALOG_BODY_FORMAT",
                    comment: "Body of the consent dialog during registration. Embeds {{Terms of Service}} and {{Privacy Policy}} as links.",
                ),
                links: [TellomiLegalConsent.termsLink, TellomiLegalConsent.privacyLink],
            ),
            primaryTitle: OWSLocalizedString(
                "TELLOMI_CONSENT_AGREE_AND_CONTINUE",
                comment: "Button in the registration consent dialog: agree to the Terms of Service and Privacy Policy and continue.",
            ),
            secondaryTitle: OWSLocalizedString(
                "TELLOMI_CONSENT_DISAGREE",
                comment: "Button in consent dialogs: do not agree.",
            ),
            onPrimary: onAgree,
            onSecondary: { dialog in dialog.dismiss(animated: true) },
        )
        present(dialog, animated: true)
    }

    /// 第一次打开 App 时的隐私提示。「不同意」不关闭——说明后果，留在这里等用户决定。
    func presentTellomiFirstLaunchNotice() {
        let dialog = TellomiConsentDialogViewController(
            title: OWSLocalizedString(
                "TELLOMI_FIRST_LAUNCH_TITLE",
                comment: "Title of the privacy notice shown the first time the app is opened.",
            ),
            body: TellomiLegalConsent.linkedSentence(
                format: OWSLocalizedString(
                    "TELLOMI_FIRST_LAUNCH_BODY_FORMAT",
                    comment: "Body of the privacy notice shown the first time the app is opened. Embeds {{Privacy Policy}} as a link.",
                ),
                links: [TellomiLegalConsent.privacyLink],
            ),
            primaryTitle: OWSLocalizedString(
                "TELLOMI_FIRST_LAUNCH_AGREE",
                comment: "Button in the first-launch privacy notice: agree.",
            ),
            secondaryTitle: OWSLocalizedString(
                "TELLOMI_CONSENT_DISAGREE",
                comment: "Button in consent dialogs: do not agree.",
            ),
            onPrimary: { TellomiLegalConsent.acceptFirstLaunchNotice() },
            onSecondary: { dialog in
                dialog.showHint(OWSLocalizedString(
                    "TELLOMI_FIRST_LAUNCH_DISAGREE_HINT",
                    comment: "Shown in the first-launch privacy notice after the user taps 'Disagree'.",
                ))
            },
        )
        present(dialog, animated: true)
    }
}

// MARK: - Tellomi：跨境单独告知与同意（tellomi/tellomi#1133）

/// 需求：`docs/product/specs/privacy-compliance-hk-cross-border.md` 第二节（tellomi/tellomi#1134）。
/// 服务端还在香港的这段时间，手机号、推送令牌、网络信息等会出境，这一页就是出境前的单独告知与单独同意。
/// **文字是草稿**：9 项正文以 tellomi/tellomi#1132 的法务定稿为准，owner 审定后才能对外发布。
enum TellomiCrossBorderConsent {
    /// 告知文本的版本。定稿后与 `docs/legal/manifest.json` 里跨境告知的版本对齐。
    /// 文本有实质变化就改这里，已经同意过的人会被重新询问。
    static let noticeVersion = "0.1.0-draft"

    private static let versionKey = "TellomiCrossBorderConsent.version"
    private static let dateKey = "TellomiCrossBorderConsent.date"

    static var hasAgreed: Bool {
        UserDefaults.standard.string(forKey: versionKey) == noticeVersion
    }

    /// 本机记一份（版本 + 时间）。服务端的最小记录点由 taishi 设计（tellomi/tellomi#1133）。
    static func recordAgreement() {
        UserDefaults.standard.set(noticeVersion, forKey: versionKey)
        UserDefaults.standard.set(Date(), forKey: dateKey)
    }
}

/// 独立一页：标题 + 9 项 + 隐私政策链接 + 两个同样醒目的按钮。不预选、不倒计时、不默认聚焦「同意」。
/// 「不同意」留在这一页，说明后果；不发送任何信息。
final class TellomiCrossBorderNoticeViewController: OWSViewController {
    private let onAgree: () -> Void
    private let disagreeHintLabel = UILabel()

    init(onAgree: @escaping () -> Void) {
        self.onAgree = onAgree
        super.init()
        modalPresentationStyle = .fullScreen
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .Signal.background

        let titleLabel = UILabel()
        titleLabel.text = OWSLocalizedString(
            "TELLOMI_CROSS_BORDER_TITLE",
            comment: "Title of the cross-border data transfer notice shown before the phone number is sent during registration.",
        )
        titleLabel.font = .dynamicTypeTitle2.semibold()
        titleLabel.textColor = .Signal.label
        titleLabel.numberOfLines = 0
        titleLabel.accessibilityTraits.insert(.header)

        let introLabel = Self.bodyLabel(OWSLocalizedString(
            "TELLOMI_CROSS_BORDER_INTRO",
            comment: "Introduction of the cross-border data transfer notice.",
        ))

        var arrangedSubviews: [UIView] = [titleLabel, introLabel]
        arrangedSubviews += Self.items().map { Self.itemView(title: $0.title, body: $0.body) }

        let privacyButton = UIButton(
            configuration: .smallBorderless(title: OWSLocalizedString(
                "TELLOMI_CROSS_BORDER_PRIVACY_LINK",
                comment: "Link at the bottom of the cross-border notice that opens the Privacy Policy sections about storage location and cross-border transfer.",
            )),
            primaryAction: UIAction { [weak self] _ in
                self?.present(SFSafariViewController(url: TellomiLegalConsent.privacyURL), animated: true)
            },
        )
        privacyButton.contentHorizontalAlignment = .leading
        // 去掉按钮自带的左右内边距，让链接和上面的正文左对齐。
        privacyButton.configuration?.contentInsets.leading = 0
        privacyButton.configuration?.contentInsets.trailing = 0
        privacyButton.accessibilityTraits.insert(.link)
        arrangedSubviews.append(privacyButton)

        let contentStack = UIStackView(arrangedSubviews: arrangedSubviews)
        contentStack.axis = .vertical
        contentStack.spacing = 16
        contentStack.setCustomSpacing(8, after: titleLabel)
        contentStack.setCustomSpacing(24, after: introLabel)

        let scrollView = UIScrollView()
        scrollView.alwaysBounceVertical = true
        scrollView.addSubview(contentStack)

        disagreeHintLabel.text = OWSLocalizedString(
            "TELLOMI_CROSS_BORDER_DISAGREE_HINT",
            comment: "Shown on the cross-border notice after the user taps 'Disagree'.",
        )
        disagreeHintLabel.font = .dynamicTypeFootnote
        disagreeHintLabel.textColor = .Signal.secondaryLabel
        disagreeHintLabel.numberOfLines = 0
        disagreeHintLabel.isHidden = true

        // 两个按钮同样的样式、同样宽，谁也不比谁醒目（需求 2.2）。
        let disagreeButton = UIButton(
            configuration: .largeSecondary(title: OWSLocalizedString(
                "TELLOMI_CONSENT_DISAGREE",
                comment: "Button in consent dialogs: do not agree.",
            )),
            primaryAction: UIAction { [weak self] _ in
                self?.didTapDisagree()
            },
        )
        disagreeButton.accessibilityIdentifier = "tellomi.crossBorder.disagree"
        let agreeButton = UIButton(
            configuration: .largeSecondary(title: OWSLocalizedString(
                "TELLOMI_CONSENT_AGREE_AND_CONTINUE",
                comment: "Button in the registration consent dialog: agree to the Terms of Service and Privacy Policy and continue.",
            )),
            primaryAction: UIAction { [weak self] _ in
                self?.didTapAgree()
            },
        )
        agreeButton.accessibilityIdentifier = "tellomi.crossBorder.agree"
        let buttonRow = UIStackView(arrangedSubviews: [disagreeButton, agreeButton])
        buttonRow.axis = .horizontal
        buttonRow.distribution = .fillEqually
        buttonRow.spacing = 12

        let footer = UIStackView(arrangedSubviews: [disagreeHintLabel, buttonRow])
        footer.axis = .vertical
        footer.spacing = 12

        view.addSubview(scrollView)
        view.addSubview(footer)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        footer.translatesAutoresizingMaskIntoConstraints = false
        let margins = view.layoutMarginsGuide
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),

            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 24),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -12),
            contentStack.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: margins.trailingAnchor),

            footer.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])
    }

    private func didTapAgree() {
        TellomiCrossBorderConsent.recordAgreement()
        let onAgree = self.onAgree
        dismiss(animated: true) { onAgree() }
    }

    private func didTapDisagree() {
        disagreeHintLabel.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: disagreeHintLabel.text)
    }

    private static func bodyLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .dynamicTypeSubheadline
        label.textColor = .Signal.secondaryLabel
        label.numberOfLines = 0
        return label
    }

    private static func itemView(title: String, body: String) -> UIView {
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .dynamicTypeHeadline
        titleLabel.textColor = .Signal.label
        titleLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [titleLabel, bodyLabel(body)])
        stack.axis = .vertical
        stack.spacing = 4
        stack.isAccessibilityElement = true
        stack.accessibilityLabel = "\(title)\n\(body)"
        return stack
    }

    /// 需求 2.3 的 9 项，顺序与隐私政策第二十一节一致。
    private static func items() -> [(title: String, body: String)] {
        return [
            (
                OWSLocalizedString("TELLOMI_CROSS_BORDER_ITEM_WHERE_TITLE", comment: "Cross-border notice item 1 title: whether data leaves mainland China."),
                OWSLocalizedString("TELLOMI_CROSS_BORDER_ITEM_WHERE_BODY", comment: "Cross-border notice item 1 body: where servers and storage are located."),
            ),
            (
                OWSLocalizedString("TELLOMI_CROSS_BORDER_ITEM_RECIPIENTS_TITLE", comment: "Cross-border notice item 2 title: overseas recipients."),
                OWSLocalizedString("TELLOMI_CROSS_BORDER_ITEM_RECIPIENTS_BODY", comment: "Cross-border notice item 2 body: who receives the data outside mainland China."),
            ),
            (
                OWSLocalizedString("TELLOMI_CROSS_BORDER_ITEM_CONTACT_TITLE", comment: "Cross-border notice item 3 title: contact."),
                OWSLocalizedString("TELLOMI_CROSS_BORDER_ITEM_CONTACT_BODY", comment: "Cross-border notice item 3 body: how to contact the personal information protection team."),
            ),
            (
                OWSLocalizedString("TELLOMI_CROSS_BORDER_ITEM_PURPOSE_TITLE", comment: "Cross-border notice item 4 title: purposes of processing."),
                OWSLocalizedString("TELLOMI_CROSS_BORDER_ITEM_PURPOSE_BODY", comment: "Cross-border notice item 4 body: purposes of processing."),
            ),
            (
                OWSLocalizedString("TELLOMI_CROSS_BORDER_ITEM_METHOD_TITLE", comment: "Cross-border notice item 5 title: how the data is processed."),
                OWSLocalizedString("TELLOMI_CROSS_BORDER_ITEM_METHOD_BODY", comment: "Cross-border notice item 5 body: end-to-end encryption and what is processed in plaintext."),
            ),
            (
                OWSLocalizedString("TELLOMI_CROSS_BORDER_ITEM_KINDS_TITLE", comment: "Cross-border notice item 6 title: kinds of personal information."),
                OWSLocalizedString("TELLOMI_CROSS_BORDER_ITEM_KINDS_BODY", comment: "Cross-border notice item 6 body: kinds of personal information transferred."),
            ),
            (
                OWSLocalizedString("TELLOMI_CROSS_BORDER_ITEM_RIGHTS_TITLE", comment: "Cross-border notice item 7 title: your rights."),
                OWSLocalizedString("TELLOMI_CROSS_BORDER_ITEM_RIGHTS_BODY", comment: "Cross-border notice item 7 body: how to exercise personal information rights."),
            ),
            (
                OWSLocalizedString("TELLOMI_CROSS_BORDER_ITEM_PROCEDURE_TITLE", comment: "Cross-border notice item 8 title: legal procedure for the transfer."),
                OWSLocalizedString("TELLOMI_CROSS_BORDER_ITEM_PROCEDURE_BODY", comment: "Cross-border notice item 8 body: legal procedure for the transfer (pending legal review)."),
            ),
            (
                OWSLocalizedString("TELLOMI_CROSS_BORDER_ITEM_CONSENT_TITLE", comment: "Cross-border notice item 9 title: separate consent."),
                OWSLocalizedString("TELLOMI_CROSS_BORDER_ITEM_CONSENT_BODY", comment: "Cross-border notice item 9 body: this page is the separate consent and can be withdrawn."),
            ),
        ]
    }
}

extension UIViewController {
    /// 跨境单独告知（tellomi/tellomi#1133）。同意 → 记录后关掉这一页再回调；不同意 → 留在这一页。
    func presentTellomiCrossBorderNotice(onAgree: @escaping () -> Void) {
        present(TellomiCrossBorderNoticeViewController(onAgree: onAgree), animated: true)
    }
}
