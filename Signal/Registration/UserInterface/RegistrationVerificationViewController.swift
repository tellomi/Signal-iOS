//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

public import SignalServiceKit
import SignalUI

// MARK: - RegistrationVerificationValidationError

public enum RegistrationVerificationValidationError: Equatable {
    case invalidVerificationCode(invalidCode: String)

    /// We tried to send via sms and failed, but voice code might work
    /// so we are on this screen now. An error should be shown.
    case failedInitialTransport(failedTransport: Registration.CodeTransport)

    /// A third party provider failed to send an sms or call to the session's number.
    /// May be permanent (the user should probably use a different number)
    /// or transient (the user should try again later).
    /// Regardless we let the user submit a code or retry.
    case providerFailure(isPermanent: Bool)

    /// Requesting a code failed with some unknown error; show a
    /// generic dialog and let the user dismiss. They might have actually
    /// gotten a code, so let them submit or resend.
    case genericCodeRequestError(isNetworkError: Bool)

    // These three errors are what happens when we try and
    // take the three respective actions but are rejected
    // with a timeout. The State should have timeout information.
    case smsResendTimeout
    case voiceResendTimeout
    case submitCodeTimeout
}

// MARK: - RegistrationVerificationState

public struct RegistrationVerificationState: Equatable {
    let e164: E164
    let nextSMSDate: Date?
    let nextCallDate: Date?
    let nextVerificationAttemptDate: Date?
    // If false, no option to go back and change e164 will be shown.
    let canChangeE164: Bool
    let showHelpText: Bool
    let validationError: RegistrationVerificationValidationError?

    public enum ExitConfiguration: Equatable {
        case noExitAllowed
        case exitReRegistration
        case exitChangeNumber
    }

    let exitConfiguration: ExitConfiguration
}

// MARK: - RegistrationVerificationPresenter

protocol RegistrationVerificationPresenter: AnyObject {
    func returnToPhoneNumberEntry()
    func requestSMSCode()
    func requestVoiceCode()
    func submitVerificationCode(_ code: String)
    func exitRegistration()
}

// MARK: - RegistrationVerificationViewController

class RegistrationVerificationViewController: OWSViewController {
    init(
        state: RegistrationVerificationState,
        presenter: RegistrationVerificationPresenter,
    ) {
        self.state = state
        self.presenter = presenter

        super.init()

        navigationItem.hidesBackButton = true
    }

    @available(*, unavailable)
    override init() {
        owsFail("This should not be called")
    }

    func updateState(_ state: RegistrationVerificationState) {
        self.state = state
    }

    deinit {
        nowTimer?.invalidate()
        nowTimer = nil
    }

    // MARK: Internal state

    private var state: RegistrationVerificationState {
        didSet { configureUI() }
    }

    private weak var presenter: RegistrationVerificationPresenter?

    private var now = Date() {
        didSet { configureUI() }
    }

    private var nowTimer: Timer?

    private var canRequestSMSCode: Bool {
        guard let nextDate = state.nextSMSDate else { return false }
        return nextDate <= now
    }

    private var canRequestVoiceCode: Bool {
        guard let nextDate = state.nextCallDate else { return false }
        return nextDate <= now
    }

    private var previouslyRenderedValidationError: RegistrationVerificationValidationError?

    // MARK: Rendering

    private lazy var titleLabel: UILabel = {
        let result = UILabel.titleLabelForRegistration(text: OWSLocalizedString(
            "ONBOARDING_VERIFICATION_TITLE_LABEL",
            comment: "Title label for the onboarding verification page",
        ))
        result.accessibilityIdentifier = "registration.verification.titleLabel"
        return result
    }()

    private func explanationLabelText() -> String {
        let format = OWSLocalizedString(
            "ONBOARDING_VERIFICATION_TITLE_DEFAULT_FORMAT",
            comment: "Format for the title of the 'onboarding verification' view. Embeds {{the user's phone number}}.",
        )
        return String.nonPluralLocalizedStringWithFormat(format, state.e164.stringValue.e164FormattedAsPhoneNumberWithoutBreaks)
    }

    private lazy var explanationLabel: UILabel = {
        let result = UILabel.explanationLabelForRegistration(text: explanationLabelText())
        result.accessibilityIdentifier = "registration.verification.explanationLabel"
        return result
    }()

    private lazy var wrongNumberButton: UIButton = {
        let button = UIButton(
            configuration: .mediumBorderless(title: OWSLocalizedString(
                "ONBOARDING_VERIFICATION_BACK_LINK",
                comment: "Label for the link that lets users change their phone number in the onboarding views.",
            )),
            primaryAction: UIAction { [weak self] _ in
                self?.didTapWrongNumberButton()
            },
        )
        button.accessibilityIdentifier = "registration.verification.wrongNumberButton"
        return button
    }()

    private lazy var verificationCodeView: RegistrationVerificationCodeView = {
        let result = RegistrationVerificationCodeView()
        result.delegate = self
        return result
    }()

    /// Tellomi：输错验证码时的行内提示（上游用底部弹窗，还叫用户去「重新发送」——而每个会话只有 3 条短信额度；tellomi/tellomi#1209）。
    private lazy var codeErrorLabel: UILabel = {
        let label = UILabel()
        label.font = .dynamicTypeSubheadlineClamped
        label.textColor = .Signal.red
        label.textAlignment = .center
        label.numberOfLines = 0
        label.isHidden = true
        label.accessibilityIdentifier = "registration.verification.codeErrorLabel"
        return label
    }()

    private lazy var helpButton: UIButton = {
        let button = UIButton(
            configuration: .mediumBorderless(title: Self.showsTellomiHelp ? RegistrationVerificationHelpSheetViewController.tellomiTitle : OWSLocalizedString(
                "ONBOARDING_VERIFICATION_HELP_LINK",
                comment: "Label for a button to get help entering a verification code when registering.",
            )),
            primaryAction: UIAction { [weak self] _ in
                self?.didTapHelpButton()
            },
        )
        button.accessibilityIdentifier = "registration.verification.helpButton"
        return button
    }()

    private func simpleMultilineButton(
        accessibilityIdentifierSuffix: String,
        primaryAction: UIAction,
    ) -> UIButton {
        let result = UIButton(
            configuration: .plain(),
            primaryAction: primaryAction,
        )
        result.configuration?.title = title
        result.configuration?.titleTextAttributesTransformer = .defaultFont(.dynamicTypeSubheadlineClamped)
        result.configuration?.baseForegroundColor = .Signal.accent
        result.enableMultilineLabel()
        result.accessibilityIdentifier = "registration.verification.\(accessibilityIdentifierSuffix)"
        result.setContentHuggingVerticalHigh()
        return result
    }

    private lazy var resendSMSCodeButton = simpleMultilineButton(
        accessibilityIdentifierSuffix: "resendSMSCodeButton",
        primaryAction: UIAction { [weak self] _ in
            self?.didTapResendSMSCode()
        },
    )

    private lazy var requestVoiceCodeButton = simpleMultilineButton(
        accessibilityIdentifierSuffix: "requestVoiceCodeButton",
        primaryAction: UIAction { [weak self] _ in
            self?.didTapSendVoiceCode()
        },
    )

    override func viewDidLoad() {
        super.viewDidLoad()

        navigationItem.setHidesBackButton(true, animated: false)
        view.backgroundColor = .Signal.background

        // Buttons at the bottom
        let resendButtonsContainer = UIStackView(arrangedSubviews: [
            resendSMSCodeButton,
            requestVoiceCodeButton,
        ])
        resendButtonsContainer.directionalLayoutMargins = .init(hMargin: 0, vMargin: 16)
        resendButtonsContainer.isLayoutMarginsRelativeArrangement = true
        resendButtonsContainer.axis = .horizontal
        resendButtonsContainer.distribution = .fillEqually
        resendButtonsContainer.spacing = 16

        // Main content stack embedded in a scroll view.
        let stackView = addStaticContentStackView(
            arrangedSubviews: [
                titleLabel,
                explanationLabel,
                wrongNumberButton,
                verificationCodeView,
                codeErrorLabel,
                helpButton,
                .vStretchingSpacer(),
                resendButtonsContainer,
            ],
            isScrollable: true,
            shouldAvoidKeyboard: true,
        )
        stackView.setCustomSpacing(24, after: wrongNumberButton)
        stackView.setCustomSpacing(24, after: verificationCodeView)

        configureUI()

        // We don't need this timer in all cases but it's simpler to start it in all cases.
        nowTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.now = Date()
        }
    }

    private var isViewAppeared = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        verificationCodeView.becomeFirstResponder()

        showValidationErrorUiIfNecessary()

        isViewAppeared = true
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        isViewAppeared = false
    }

    private func configureUI() {
        switch state.exitConfiguration {
        case .noExitAllowed:
            navigationItem.leftBarButtonItem = nil

        case .exitReRegistration:
            navigationItem.leftBarButtonItem = .contextMenuButton(actions: [
                UIAction(
                    title: OWSLocalizedString(
                        "EXIT_REREGISTRATION",
                        comment: "Button to exit re-registration, shown in context menu.",
                    ),
                    handler: { [weak self] _ in
                        self?.presenter?.exitRegistration()
                    },
                ),
            ])

        case .exitChangeNumber:
            navigationItem.leftBarButtonItem = .contextMenuButton(actions: [
                UIAction(
                    title: OWSLocalizedString(
                        "EXIT_CHANGE_NUMBER",
                        comment: "Button to exit change number, shown in context menu.",
                    ),
                    handler: { [weak self] _ in
                        self?.presenter?.exitRegistration()
                    },
                ),
            ])
        }

        updateButtonWithTimer(
            button: resendSMSCodeButton,
            date: state.nextSMSDate,
            enabledString: OWSLocalizedString(
                "ONBOARDING_VERIFICATION_RESEND_CODE_BUTTON",
                comment: "Label for button to resend SMS verification code.",
            ),
            countdownFormat: OWSLocalizedString(
                "ONBOARDING_VERIFICATION_RESEND_CODE_COUNTDOWN_FORMAT",
                comment: "Format string for button counting down time until SMS code can be resent. Embeds {{time remaining}}.",
            ),
        )
        updateButtonWithTimer(
            button: requestVoiceCodeButton,
            // Tellomi：服务端没开语音时「呼叫我」是死路，直接不显示（tellomi/tellomi#1209）。
            date: TSConstants.voiceVerificationAvailable ? state.nextCallDate : nil,
            enabledString: OWSLocalizedString(
                "ONBOARDING_VERIFICATION_CALL_ME_BUTTON",
                comment: "Label for button to perform verification with a phone call.",
            ),
            countdownFormat: OWSLocalizedString(
                "ONBOARDING_VERIFICATION_CALL_ME_COUNTDOWN_FORMAT",
                comment: "Format string for button counting down time until phone call verification can be performed. Embeds {{time remaining}}.",
            ),
        )

        if isViewAppeared {
            showValidationErrorUiIfNecessary()
        }

        explanationLabel.text = explanationLabelText()
        wrongNumberButton.isHidden = !state.canChangeE164
        // Tellomi（tellomi/tellomi#1214，ADR-0051 §二，taishi 审查 b6）：一进页面就显示「收不到验证码？」。
        // 上游要提交过 3 次验证码才出现（showHelpText），收不到短信的人没有码可交，面板里的出路就一直藏着。
        helpButton.isHidden = !(state.showHelpText || Self.showsTellomiHelp)

        verificationCodeView.updateColors()
    }

    private lazy var retryAfterFormatter: DateFormatter = {
        let result = DateFormatter()
        result.dateFormat = "m:ss"
        result.timeZone = TimeZone(identifier: "UTC")!
        return result
    }()

    private func updateButtonWithTimer(
        button: UIButton,
        date: Date?,
        enabledString: String,
        countdownFormat: String,
    ) {
        // UIButton will flash when we update the title.
        UIView.performWithoutAnimation {
            defer { button.layoutIfNeeded() }

            guard let date else {
                button.isHidden = true
                button.isEnabled = false
                return
            }

            if date <= now {
                button.isEnabled = true
                button.configuration?.title = enabledString
            } else {
                button.isEnabled = false
                button.configuration?.title = {
                    let timeRemaining = max(date.timeIntervalSince(now), 0)
                    let durationString = retryAfterFormatter.string(from: Date(timeIntervalSinceReferenceDate: timeRemaining))
                    return String.nonPluralLocalizedStringWithFormat(countdownFormat, durationString)
                }()
            }
        }
    }

    private func showValidationErrorUiIfNecessary() {
        let oldError = previouslyRenderedValidationError
        let newError = state.validationError

        previouslyRenderedValidationError = newError

        guard let newError, oldError != newError else { return }
        switch newError {
        case .invalidVerificationCode(let code):
            showInlineCodeError(OWSLocalizedString(
                "REGISTRATION_VERIFICATION_ERROR_INVALID_CODE_INLINE",
                comment: "Shown inline under the verification code field when the entered code is wrong.",
            ))
            // Tellomi：输错的这串先红着停一下再清空，让人看清错的是哪串（Telegram CodeInputView.animateError 同样是 0.85 秒；
            // tellomi/tellomi#1214）。这期间用户已经改了就不清。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { [weak self] in
                guard let self, self.verificationCodeView.verificationCode == code else { return }
                self.verificationCodeView.clear()
            }

        case .providerFailure(let isPermanent):
            let message: String
            if isPermanent {
                // Tellomi：服务商判定永久失败时，上游这里说「请在几小时后重试」，会诱导用户反复重试；
                // 改为说清只开放中国大陆 + 客服（tellomi/tellomi#1209）。大陆以外的号码走不到这里：
                // 服务端对它们回的是 permanentFailure=false，首次注册时协调器直接把人送回手机号页。
                message = OWSLocalizedString(
                    "REGISTRATION_SMS_CODE_FAILED_NO_VOICE_ERROR",
                    comment: "Error message when sending a verification code via SMS failed and no other way of sending the code is available.",
                )
            } else {
                message = OWSLocalizedString(
                    "REGISTRATION_PROVIDER_FAILURE_MESSAGE_TRANSIENT",
                    comment: "Error shown if an SMS/call service provider is temporarily unable to send a verification code to the provided number.",
                )
            }
            OWSActionSheets.showActionSheet(title: nil, message: message)

        case .genericCodeRequestError(let isNetworkError):
            let title: String?
            let message: String
            if isNetworkError {
                title = OWSLocalizedString(
                    "REGISTRATION_NETWORK_ERROR_TITLE",
                    comment: "A network error occurred during registration, and an error is shown to the user. This is the title on that error sheet.",
                )
                message = OWSLocalizedString(
                    "REGISTRATION_NETWORK_ERROR_BODY",
                    comment: "A network error occurred during registration, and an error is shown to the user. This is the body on that error sheet.",
                )
            } else {
                title = nil
                message = CommonStrings.somethingWentWrongTryAgainLaterError
            }
            OWSActionSheets.showActionSheet(title: title, message: message)

        case .failedInitialTransport(let failedTransport):
            // Tellomi：服务端没开语音时，上游这里的「改用语音通话接收」是一条死路（tellomi/tellomi#1209）。
            // 只说清发不出去；服务端只放行中国大陆号码时，别的地区也落在这里。
            if case .sms = failedTransport, !TSConstants.voiceVerificationAvailable {
                OWSActionSheets.showActionSheet(
                    title: nil,
                    message: OWSLocalizedString(
                        "REGISTRATION_SMS_CODE_FAILED_NO_VOICE_ERROR",
                        comment: "Error message when sending a verification code via SMS failed and no other way of sending the code is available.",
                    ),
                )
                return
            }
            let errorMessage: String
            let alternativeTransportButtonText: String
            let alternativeTransport: Registration.CodeTransport
            switch failedTransport {
            case .sms:
                errorMessage = OWSLocalizedString(
                    "REGISTRATION_SMS_CODE_FAILED_TRY_VOICE_ERROR",
                    comment: "Error message when sending a verification code via sms failed, but resending via voice call might succeed.",
                )
                alternativeTransportButtonText = OWSLocalizedString(
                    "REGISTRATION_SMS_CODE_FAILED_TRY_VOICE_BUTTON",
                    comment: "Button when sending a verification code via sms failed, but resending via voice call might succeed.",
                )
                alternativeTransport = .voice
            case .voice:
                errorMessage = OWSLocalizedString(
                    "REGISTRATION_VOICE_CODE_FAILED_TRY_SMS_ERROR",
                    comment: "Error message when sending a verification code via voice call failed, but resending via sms might succeed.",
                )
                alternativeTransportButtonText = OWSLocalizedString(
                    "REGISTRATION_VOICE_CODE_FAILED_TRY_SMS_BUTTON",
                    comment: "Button when sending a verification code via voice call failed, but resending via sms might succeed.",
                )
                alternativeTransport = .sms
            }
            let actionSheet = ActionSheetController(title: nil, message: errorMessage)
            actionSheet.addAction(.init(
                title: alternativeTransportButtonText,
                handler: { [weak self] _ in
                    switch alternativeTransport {
                    case .sms:
                        self?.presenter?.requestSMSCode()
                    case .voice:
                        self?.presenter?.requestVoiceCode()
                    }
                },
            ))
            actionSheet.addAction(.cancel)
            self.present(actionSheet, animated: true)
            return

        case .smsResendTimeout, .voiceResendTimeout:
            let message = OWSLocalizedString(
                "REGISTER_RATE_LIMITING_ALERT",
                comment: "Body of action sheet shown when rate-limited during registration.",
            )
            OWSActionSheets.showActionSheet(title: nil, message: message)

        case .submitCodeTimeout:
            guard let nextVerificationAttemptDate = state.nextVerificationAttemptDate else {
                return
            }
            let now = Date()
            if now >= nextVerificationAttemptDate {
                return
            }
            let format = OWSLocalizedString(
                "REGISTRATION_SUBMIT_CODE_RATE_LIMIT_ALERT_FORMAT",
                comment: "Alert shown when submitting a verification code too many times. Embeds {{ duration }}, such as \"5:00\"",
            )

            let formatter: DateFormatter = {
                let result = DateFormatter()
                result.dateFormat = "m:ss"
                result.timeZone = TimeZone(identifier: "UTC")!
                return result
            }()

            let timeRemaining = max(nextVerificationAttemptDate.timeIntervalSince(now), 0)
            let durationString = formatter.string(from: Date(timeIntervalSinceReferenceDate: timeRemaining))
            let message = String.nonPluralLocalizedStringWithFormat(format, durationString)
            OWSActionSheets.showActionSheet(title: nil, message: message)
        }
    }

    // MARK: Events

    private func didTapWrongNumberButton() {
        Logger.info("")

        presenter?.returnToPhoneNumberEntry()
    }

    private func didTapHelpButton() {
        Logger.info("")

        guard Self.showsTellomiHelp else {
            self.present(RegistrationVerificationHelpSheetViewController(), animated: true)
            return
        }
        let sheet = RegistrationVerificationHelpSheetViewController(tellomiHelp: .init(
            phoneNumber: state.e164.stringValue.e164FormattedAsPhoneNumberWithoutBreaks,
            // 和页面上的「错误的号码？」一样：重新注册 / 换号流程里号码是固定的，不给改号码的出口。
            onChangeNumber: state.canChangeE164 ? { [weak self] in
                self?.dismiss(animated: true) {
                    self?.presenter?.returnToPhoneNumberEntry()
                }
            } : nil,
            onContactSupport: { [weak self] in
                self?.dismiss(animated: true) {
                    self?.composeSupportEmail()
                }
            },
        ))
        self.present(sheet, animated: true)
    }

    /// Tellomi 的部署（没连 Signal 官方服务）用自己的「收不到验证码？」面板（tellomi/tellomi#1214）。
    fileprivate static var showsTellomiHelp: Bool { !TSConstants.isUsingProductionService }

    private func composeSupportEmail() {
        Task { @MainActor in
            do {
                try await ComposeSupportEmailOperation.sendEmail(model: SupportEmailModel(
                    userDescription: nil,
                    emojiMood: nil,
                    supportFilter: "Registration - verification code (iOS)",
                    debugLogPolicy: nil,
                    hasRecentChallenge: false,
                    backupPlan: .disabled,
                ))
            } catch {
                OWSActionSheets.showErrorAlert(message: error.userErrorDescription)
            }
        }
    }

    private func didTapResendSMSCode() {
        Logger.info("")

        guard canRequestSMSCode else { return }

        presentActionSheet(.forRegistrationVerificationConfirmation(
            mode: .sms,
            e164: state.e164.stringValue,
            didConfirm: { [weak self] in self?.presenter?.requestSMSCode() },
            didRequestEdit: { [weak self] in self?.presenter?.returnToPhoneNumberEntry() },
        ))
    }

    private func didTapSendVoiceCode() {
        Logger.info("")

        guard canRequestVoiceCode else { return }

        presentActionSheet(.forRegistrationVerificationConfirmation(
            mode: .voice,
            e164: state.e164.stringValue,
            didConfirm: { [weak self] in self?.presenter?.requestVoiceCode() },
            didRequestEdit: { [weak self] in self?.presenter?.returnToPhoneNumberEntry() },
        ))
    }
}

// MARK: - Tellomi：行内验证码错误

extension RegistrationVerificationViewController {
    private func showInlineCodeError(_ message: String) {
        codeErrorLabel.text = message
        codeErrorLabel.isHidden = false
        verificationCodeView.setHasError(true)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        if !UIAccessibility.isReduceMotionEnabled {
            let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
            shake.timingFunction = CAMediaTimingFunction(name: .easeOut)
            shake.duration = 0.45
            shake.values = [-12, 12, -9, 9, -5, 5, -2, 0]
            verificationCodeView.layer.add(shake, forKey: "tellomi.codeError.shake")
        }
        UIAccessibility.post(notification: .announcement, argument: message)
        // 提交时输入框会失去焦点；出错后直接让用户重输。
        _ = verificationCodeView.becomeFirstResponder()
    }

    private func hideInlineCodeError() {
        guard !codeErrorLabel.isHidden else { return }
        codeErrorLabel.isHidden = true
        verificationCodeView.setHasError(false)
    }
}

// MARK: - RegistrationVerificationCodeViewDelegate

extension RegistrationVerificationViewController: RegistrationVerificationCodeViewDelegate {
    func codeViewDidChange() {
        if !verificationCodeView.verificationCode.isEmpty {
            hideInlineCodeError()
        }
        if verificationCodeView.isComplete {
            Logger.info("Submitting verification code")
            verificationCodeView.resignFirstResponder()
            // Clear any errors so we render new ones.
            previouslyRenderedValidationError = nil
            presenter?.submitVerificationCode(verificationCodeView.verificationCode)
        }
    }
}

// MARK: - RegistrationVerificationHelpSheetViewController

class RegistrationVerificationHelpSheetViewController: InteractiveSheetViewController {

    /// Tellomi（tellomi/tellomi#1214）：「收不到验证码？」面板。上游这里是三条通用提示（信号、能不能接电话、号码对不对），
    /// 没有出口；Tellomi 的用户多在中国大陆，短信常被手机管家的骚扰拦截吞掉，每个注册会话又只有几条短信额度。
    struct TellomiHelp {
        let phoneNumber: String
        /// nil = 这个流程里号码不能改（和 `RegistrationVerificationState.canChangeE164` 一致），不出「改号码」。
        let onChangeNumber: (() -> Void)?
        let onContactSupport: () -> Void
    }

    static var tellomiTitle: String {
        OWSLocalizedString(
            "ONBOARDING_VERIFICATION_TELLOMI_HELP_LINK",
            comment: "Tellomi: Label for the button (and title of the sheet) that helps people who didn't receive the SMS verification code.",
        )
    }

    private let tellomiHelp: TellomiHelp?

    private var intrinsicSizeObservation: NSKeyValueObservation?

    private let scrollView: UIScrollView = {
        let scrollView = UIScrollView()
        scrollView.bounces = false
        scrollView.isScrollEnabled = false
        scrollView.preservesSuperviewLayoutMargins = true
        return scrollView
    }()

    private lazy var stackView: UIStackView = {
        let headerLabel = UILabel()
        headerLabel.textAlignment = .center
        headerLabel.font = UIFont.dynamicTypeTitle2.semibold()
        headerLabel.text = tellomiHelp != nil ? Self.tellomiTitle : OWSLocalizedString(
            "ONBOARDING_VERIFICATION_HELP_LINK",
            comment: "Label for a button to get help entering a verification code when registering.",
        )
        headerLabel.numberOfLines = 0
        headerLabel.lineBreakMode = .byWordWrapping

        let stackView = UIStackView(arrangedSubviews: [headerLabel])
        if let tellomiHelp {
            stackView.addArrangedSubviews(tellomiBulletPoints(tellomiHelp))
            stackView.addArrangedSubview(tellomiButtons(tellomiHelp))
        } else {
            stackView.addArrangedSubviews(bulletPoints())
        }
        stackView.spacing = 12
        stackView.setCustomSpacing(20, after: headerLabel)
        stackView.axis = .vertical
        stackView.alignment = .fill
        stackView.preservesSuperviewLayoutMargins = true
        stackView.isLayoutMarginsRelativeArrangement = true
        return stackView
    }()

    init(tellomiHelp: TellomiHelp? = nil) {
        self.tellomiHelp = tellomiHelp
        super.init()

        self.allowsExpansion = false

        // TODO[Registration]: there should be a contact support link here.

        contentView.addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.frameLayoutGuide.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.frameLayoutGuide.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.frameLayoutGuide.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            scrollView.frameLayoutGuide.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])

        let insets = UIEdgeInsets(top: 20, left: 0, bottom: 80, right: 0)
        scrollView.addSubview(stackView)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stackView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: insets.top),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -insets.bottom),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
        ])

        intrinsicSizeObservation = stackView.observe(\.bounds, changeHandler: { [weak self] stackView, _ in
            self?.minimizedHeight = stackView.bounds.height + insets.totalHeight
            self?.scrollView.isScrollEnabled = (self?.maxHeight ?? 0) < stackView.bounds.height
        })
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        scrollView.isScrollEnabled = self.maxHeight < stackView.bounds.height
    }

    private func bulletPoints() -> [UIView] {
        return [
            OWSLocalizedString(
                "ONBOARDING_VERIFICATION_HELP_BULLET_1",
                comment: "First bullet point for the explainer sheet for registering via verification code.",
            ),
            OWSLocalizedString(
                "ONBOARDING_VERIFICATION_HELP_BULLET_2",
                comment: "Second bullet point for the explainer sheet for registering via verification code.",
            ),
            OWSLocalizedString(
                "ONBOARDING_VERIFICATION_HELP_BULLET_3",
                comment: "Third bullet point for the explainer sheet for registering via verification code.",
            ),
        ].map { text in
            return RegistrationVerificationHelpSheetViewController.listPointView(text: text)
        }
    }

    private func tellomiBulletPoints(_ help: TellomiHelp) -> [UIView] {
        var texts = [
            String.nonPluralLocalizedStringWithFormat(
                OWSLocalizedString(
                    "ONBOARDING_VERIFICATION_TELLOMI_HELP_CHECK_NUMBER_FORMAT",
                    comment: "Tellomi: Bullet in the 'didn't get the code?' sheet. Embeds {{the phone number the code was sent to}}.",
                ),
                help.phoneNumber,
            ),
            OWSLocalizedString(
                "ONBOARDING_VERIFICATION_TELLOMI_HELP_SPAM_FILTER",
                comment: "Tellomi: Bullet in the 'didn't get the code?' sheet: the SMS may have been caught by the phone's built-in spam/harassment filter.",
            ),
        ]
        if let quota = TSConstants.smsVerificationCodesPerSession {
            texts.append(String.nonPluralLocalizedStringWithFormat(
                OWSLocalizedString(
                    "ONBOARDING_VERIFICATION_TELLOMI_HELP_WAIT_WITH_QUOTA_FORMAT",
                    comment: "Tellomi: Bullet in the 'didn't get the code?' sheet: SMS messages sometimes arrive late, and one registration can only send a few codes. Embeds {{how many verification codes one registration can send}}.",
                ),
                String(quota),
            ))
        } else {
            texts.append(OWSLocalizedString(
                "ONBOARDING_VERIFICATION_TELLOMI_HELP_WAIT",
                comment: "Tellomi: Bullet in the 'didn't get the code?' sheet: SMS messages sometimes arrive late.",
            ))
        }
        if TSConstants.voiceVerificationAvailable {
            texts.append(OWSLocalizedString(
                "ONBOARDING_VERIFICATION_TELLOMI_HELP_VOICE",
                comment: "Tellomi: Bullet in the 'didn't get the code?' sheet, only shown when the server can call and read out the code.",
            ))
        }
        texts.append(OWSLocalizedString(
            "ONBOARDING_VERIFICATION_TELLOMI_HELP_SUPPORT",
            comment: "Tellomi: Last bullet in the 'didn't get the code?' sheet: email support.",
        ))
        return texts.map { Self.listPointView(text: $0) }
    }

    private func tellomiButtons(_ help: TellomiHelp) -> UIView {
        var buttons: [UIButton] = []
        if let onChangeNumber = help.onChangeNumber {
            let changeNumberButton = UIButton(
                configuration: .mediumBorderless(title: OWSLocalizedString(
                    "ONBOARDING_VERIFICATION_TELLOMI_HELP_CHANGE_NUMBER",
                    comment: "Tellomi: Button in the 'didn't get the code?' sheet that goes back to the phone number screen.",
                )),
                primaryAction: UIAction { _ in onChangeNumber() },
            )
            changeNumberButton.accessibilityIdentifier = "registration.verification.help.changeNumber"
            buttons.append(changeNumberButton)
        }
        let contactSupportButton = UIButton(
            configuration: .mediumBorderless(title: OWSLocalizedString(
                "ONBOARDING_VERIFICATION_TELLOMI_HELP_CONTACT_SUPPORT",
                comment: "Tellomi: Button in the 'didn't get the code?' sheet that composes an email to support.",
            )),
            primaryAction: UIAction { _ in help.onContactSupport() },
        )
        contactSupportButton.accessibilityIdentifier = "registration.verification.help.contactSupport"
        buttons.append(contactSupportButton)
        let row = UIStackView(arrangedSubviews: buttons)
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.spacing = 12
        return row
    }

    private static func listPointView(text: String) -> UIView {
        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.textColor = .Signal.label
        label.font = .dynamicTypeBodyClamped
        label.setCompressionResistanceHigh()

        let bulletPoint = UIView()
        bulletPoint.backgroundColor = UIColor(rgbHex: 0xC4C4C4)
        bulletPoint.autoSetDimensions(to: .init(width: 4, height: 14))

        let stackView = UIStackView(arrangedSubviews: [bulletPoint, label])
        stackView.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 0)
        stackView.isLayoutMarginsRelativeArrangement = true
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = 8

        return stackView
    }
}
