//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SafariServices
import SignalServiceKit
import SignalUI

// MARK: - RegistrationProfileState

public struct RegistrationProfileState: Equatable {
    let e164: E164
    let phoneNumberDiscoverability: PhoneNumberDiscoverability
    /// Tellomi（tellomi/tellomi#1266）：重新注册时不显示「用户名（选填）」，交给设置页。
    var showsTellomiUsername: Bool = true
}

// MARK: - RegistrationProfilePresenter

// Tellomi（tellomi/tellomi#1215 第二刀）：标成 @MainActor——只由页面（主线程）调用、只由导航控制器实现；新加的两个 async 方法要在主线程读协调器状态
@MainActor
protocol RegistrationProfilePresenter: AnyObject {
    // Tellomi（tellomi/tellomi#1215 第二刀）：选填用户名，由注册协调器用注册拿到的凭证显式认证去保留 / 确认
    func reserveTellomiUsername(nickname: String) async -> TellomiRegistrationUsername.ReservationOutcome
    func confirmTellomiUsername(_ reservedUsername: Usernames.HashedUsername) async -> TellomiRegistrationUsername.ConfirmationOutcome

    func goToNextStep(
        givenName: OWSUserProfile.NameComponent,
        familyName: OWSUserProfile.NameComponent?,
        avatarData: Data?,
        phoneNumberDiscoverability: PhoneNumberDiscoverability,
    )
}

// MARK: - RegistrationProfileViewController

class RegistrationProfileViewController: OWSViewController {
    var state: RegistrationProfileState

    init(
        state: RegistrationProfileState,
        presenter: RegistrationProfilePresenter,
    ) {
        self.presenter = presenter
        self.state = state

        super.init()

        navigationItem.hidesBackButton = true
    }

    @available(*, unavailable)
    override init() {
        owsFail("This should not be called")
    }

    // MARK: Internal state

    private weak var presenter: RegistrationProfilePresenter?

    private var givenNameComponent: OWSUserProfile.NameComponent? {
        return OWSUserProfile.NameComponent(truncating: givenNameTextField.text ?? "")
    }

    private var avatarData: Data? {
        didSet { updateUI() }
    }

    // MARK: Tellomi（tellomi/tellomi#1215 第二刀）：选填用户名

    enum TellomiUsernameStatus: Equatable {
        case none
        case localError(TellomiRegistrationUsername.LocalError)
        case checking
        case reserved(Usernames.HashedUsername)
        case notAvailable
        case cooldown(days: Int)
        case tooManyAttempts
        case checkFailed
    }

    /// 单测、截图直接读写它；页面上的状态行、候选、「下一步」都从它算。
    var tellomiUsernameStatus: TellomiUsernameStatus = .none {
        didSet { updateTellomiUsernameUI() }
    }

    var tellomiUsernameCandidates: [String] = [] {
        didSet { updateTellomiUsernameUI() }
    }

    /// 已经确认成了账号的用户名：之后保存资料失败再点「下一步」时不再确认第二次（再确认就算改名，会开始 30 天冷却）。
    private(set) var isTellomiUsernameConfirmed = false

    private var isConfirmingTellomiUsername = false
    private var tellomiUsernameTask: Task<Void, Never>?

    /// 与 Telegram 两端同一个节奏：去掉习惯打的 `@`；格式不对立刻说；格式对了立刻显示「正在检查…」，停顿之后才去服务端。
    /// 停顿取上游 UsernameSelection 的 0.5 秒（Signal 没有单独的查重接口，查重就是保留，有频率限制）。
    private static let tellomiUsernameDebounce: UInt64 = 500_000_000

    var tellomiUsernameText: String {
        return usernameTextField.text ?? ""
    }

    /// 没填 = 不设用户名，可以进入；填了就要保留成功（或已经确认过）才行。
    var isTellomiUsernameAcceptable: Bool {
        if tellomiUsernameText.isEmpty || isTellomiUsernameConfirmed {
            return true
        }
        if case .reserved = tellomiUsernameStatus {
            return true
        }
        return false
    }

    // MARK: UI

    private lazy var titleLabel: UILabel = {
        let result = UILabel.titleLabelForRegistration(text: OWSLocalizedString(
            "REGISTRATION_PROFILE_SETUP_TITLE",
            comment: "During registration, users set up their profile. This is the title on the screen where this is done.",
        ))
        result.accessibilityIdentifier = "registration.profile.titleLabel"
        return result
    }()

    private lazy var explanationView: LinkingTextView = {
        let result = LinkingTextView()
        result.attributedText = .composed(of: [
            OWSLocalizedString(
                "REGISTRATION_PROFILE_SETUP_SUBTITLE",
                comment: "During registration, users set up their profile. This is the subtitle on the screen where this is done. It tells users about the privacy of their profile. A \"learn more\" link will be added to the end of this string.",
            ),
            " ",
            CommonStrings.learnMore.styled(with: {
                // We'd like a link that doesn't go anywhere, because we'd like to handle the
                // tapping ourselves. We use a "fake" URL because BonMot needs one.
                return StringStyle.Part.link(URL.Support.profilesAndMessageRequests)
            }()),
        ])
        result.textColor = .Signal.secondaryLabel
        result.font = .dynamicTypeBody
        result.textAlignment = .center
        result.delegate = self
        return result
    }()

    private let avatarSize: CGFloat = 64
    private lazy var avatarView: AvatarImageView = {
        let result = AvatarImageView()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.addConstraints([
            result.widthAnchor.constraint(equalToConstant: avatarSize),
            result.heightAnchor.constraint(equalToConstant: avatarSize),
        ])
        result.accessibilityIdentifier = "registration.profile.avatarView"
        result.addGestureRecognizer(UITapGestureRecognizer(
            target: self,
            action: #selector(didTapAvatar),
        ))
        result.isUserInteractionEnabled = true
        return result
    }()

    private lazy var cameraIconButton: UIButton = {
        let buttonSize: CGFloat = 28

        var buttonConfiguration: UIButton.Configuration?
        if #available(iOS 26, *) {
            buttonConfiguration = .prominentClearGlass()
        }
        if buttonConfiguration == nil {
            buttonConfiguration = .filled()
            buttonConfiguration?.baseBackgroundColor = .Signal.background
            buttonConfiguration?.baseForegroundColor = .Signal.secondaryLabel
        }
        buttonConfiguration?.cornerStyle = .capsule
        buttonConfiguration?.image = UIImage(named: "camera-compact")

        let button = UIButton(
            configuration: buttonConfiguration!,
            primaryAction: UIAction { [weak self] _ in self?.didTapAvatar() },
        )
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addConstraints([
            button.widthAnchor.constraint(equalToConstant: buttonSize),
            button.heightAnchor.constraint(equalToConstant: buttonSize),
        ])

        return button
    }()

    private func textField(
        placeholder: String,
        textContentType: UITextContentType,
        accessibilityIdentifierSuffix: String,
    ) -> UITextField {
        let result = OWSTextField()
        result.font = .dynamicTypeBodyClamped
        result.textColor = .Signal.label
        if #available(iOS 26, *) {
            result.tintColor = result.textColor
        }
        result.adjustsFontForContentSizeCategory = true
        result.textAlignment = .natural
        result.autocorrectionType = .no
        result.spellCheckingType = .no
        result.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [.foregroundColor: UIColor.Signal.secondaryLabel])
        result.textContentType = textContentType
        result.accessibilityIdentifier = "registration.profile.\(accessibilityIdentifierSuffix)"
        result.delegate = self
        result.addAction(
            UIAction { [weak self] _ in self?.didTextFieldChange() },
            for: .editingChanged,
        )
        result.autoSetDimension(.height, toSize: 50, relation: .greaterThanOrEqual)
        return result
    }

    // Tellomi（tellomi/tellomi#1215）：只留一个「名字」框，填全名，保存时全进 given name（family name 留空）。
    // 上游是名 / 姓两个框（中日韩系统下姓在前），中文用户习惯一个框填全名。
    // 占位符用新键：上游那条英文是「First Name」，这个框填的是全名（taishi 审查 2026-09-24）
    private lazy var givenNameTextField: UITextField = textField(
        placeholder: OWSLocalizedString(
            "REGISTRATION_PROFILE_SETUP_NAME_FIELD_PLACEHOLDER_TELLOMI",
            value: "Name",
            comment: "During registration, users set up their profile in a single field that holds their full name. This is the placeholder for that field.",
        ),
        textContentType: .name,
        accessibilityIdentifierSuffix: "givenName",
    )

    private lazy var nameStackView: UIView = {
        let stackView = UIStackView(arrangedSubviews: [givenNameTextField])
        stackView.axis = .vertical
        if #available(iOS 26, *) {
            stackView.backgroundColor = .Signal.secondaryBackground
            // Stack view has a background so horizontal margins are necessary.
            stackView.directionalLayoutMargins = .init(top: 0, leading: 16, bottom: 0, trailing: 8)
            stackView.isLayoutMarginsRelativeArrangement = true
            stackView.cornerConfiguration = .uniformCorners(radius: 26)
        } else {
            givenNameTextField.addBottomStroke(color: .Signal.opaqueSeparator, strokeWidth: hairlineWidth)
        }
        return stackView
    }()

    // Tellomi（tellomi/tellomi#1215 第二刀）：用户名（选填），在名字下面
    private lazy var usernameTextField: UITextField = {
        let result = textField(
            placeholder: OWSLocalizedString(
                "REGISTRATION_PROFILE_USERNAME_PLACEHOLDER_TELLOMI",
                comment: "Tellomi: during registration, placeholder of the optional username field below the name field.",
            ),
            textContentType: .username,
            accessibilityIdentifierSuffix: "username",
        )
        result.autocapitalizationType = .none
        result.keyboardType = .asciiCapable
        result.returnKeyType = .done
        result.rightViewMode = .always
        return result
    }()

    private lazy var usernameStackView: UIView = {
        let stackView = UIStackView(arrangedSubviews: [usernameTextField])
        stackView.axis = .vertical
        if #available(iOS 26, *) {
            stackView.backgroundColor = .Signal.secondaryBackground
            stackView.directionalLayoutMargins = .init(top: 0, leading: 16, bottom: 0, trailing: 8)
            stackView.isLayoutMarginsRelativeArrangement = true
            stackView.cornerConfiguration = .uniformCorners(radius: 26)
        } else {
            usernameTextField.addBottomStroke(color: .Signal.opaqueSeparator, strokeWidth: hairlineWidth)
        }
        return stackView
    }()

    /// 说明行一直占一行：出错、在查、你的链接都在这一行，界面不跳。
    private lazy var usernameStatusLabel: UILabel = {
        let label = UILabel()
        label.font = .dynamicTypeFootnoteClamped
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.accessibilityIdentifier = "registration.profile.usernameStatus"
        return label
    }()

    private lazy var usernameCandidatesStackView: UIStackView = {
        let stackView = UIStackView()
        stackView.axis = .horizontal
        stackView.spacing = 8
        stackView.alignment = .center
        stackView.accessibilityIdentifier = "registration.profile.usernameCandidates"
        return stackView
    }()

    private lazy var usernameCheckingIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.hidesWhenStopped = true
        return indicator
    }()

    private lazy var usernameReservedImageView: UIImageView = {
        let imageView = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
        imageView.tintColor = .Signal.accent
        return imageView
    }()

    // Tellomi（tellomi/tellomi#1215）：「谁可以通过手机号找到我」去掉（没有 CDSI 时不起作用），换成一句实话：
    // 号码默认不分享（`PhoneNumberSharingMode` 默认就是不显示）。
    private lazy var phoneNumberNotShownLabel: UILabel = {
        let label = UILabel()
        label.text = OWSLocalizedString(
            "REGISTRATION_PROFILE_SETUP_PHONE_NUMBER_NOT_SHOWN_TELLOMI",
            value: "Your phone number isn't shown to anyone by default.",
            comment: "During registration, users set up their profile. Shown below the name field instead of the phone number privacy setting.",
        )
        label.font = .dynamicTypeSubheadlineClamped
        label.textColor = .Signal.secondaryLabel
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        label.accessibilityIdentifier = "registration.profile.phoneNumberNotShown"
        return label
    }()

    private lazy var phoneNumberPrivacyButton: PhoneNumberPrivacyButton = {
        let button = PhoneNumberPrivacyButton(phoneNumberDiscoverability: state.phoneNumberDiscoverability)
        button.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                let vc = RegistrationPhoneNumberDiscoverabilityViewController(
                    state: RegistrationPhoneNumberDiscoverabilityState(
                        e164: self.state.e164,
                        phoneNumberDiscoverability: self.state.phoneNumberDiscoverability,
                    ),
                    presenter: self,
                )
                self.presentFormSheet(OWSNavigationController(rootViewController: vc), animated: true)
            },
            for: .primaryActionTriggered,
        )
        return button
    }()

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .Signal.background

        navigationItem.rightBarButtonItem = .nextButton { [weak self] in
            self?.didTapNext()
        }

        let avatarContainerView = UIView.container()
        avatarContainerView.addSubview(avatarView)
        avatarContainerView.addSubview(cameraIconButton)
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        cameraIconButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            avatarView.topAnchor.constraint(equalTo: avatarContainerView.topAnchor),
            avatarView.centerXAnchor.constraint(equalTo: avatarContainerView.centerXAnchor),
            avatarView.bottomAnchor.constraint(equalTo: avatarContainerView.bottomAnchor),

            // Looks better with tiny offset.
            cameraIconButton.bottomAnchor.constraint(equalTo: avatarView.bottomAnchor, constant: 1),
            cameraIconButton.trailingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 1),
        ])

        let stackView = addStaticContentStackView(
            arrangedSubviews: [
                titleLabel,
                explanationView,
                avatarContainerView,
                nameStackView,
                usernameStackView,
                usernameStatusLabel,
                usernameCandidatesStackView,
                phoneNumberNotShownLabel,
                .vStretchingSpacer(),
            ],
            isScrollable: true,
            shouldAvoidKeyboard: true,
        )
        stackView.spacing = 24
        stackView.setCustomSpacing(12, after: titleLabel)
        stackView.setCustomSpacing(12, after: nameStackView)
        stackView.setCustomSpacing(6, after: usernameStackView)
        // 候选行隐藏时，状态行直接接下面那句说明，间距要够
        stackView.setCustomSpacing(16, after: usernameStatusLabel)
        stackView.setCustomSpacing(16, after: usernameCandidatesStackView)

        // Tellomi（tellomi/tellomi#1215 第二刀）：下面还有用户名框，名字框按回车跳过去；
        // 重新注册时没有用户名框（#1266），回车就是下一步
        usernameStackView.isHidden = !state.showsTellomiUsername
        usernameStatusLabel.isHidden = !state.showsTellomiUsername
        givenNameTextField.returnKeyType = state.showsTellomiUsername ? .next : .done
        usernameTextField.addAction(
            UIAction { [weak self] _ in self?.didUsernameTextFieldChange() },
            for: .editingChanged,
        )
        updateTellomiUsernameUI()

        updateUI()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        // Small devices may obscure parts of the UI behind the keyboard, especially with larger font sizes.
        // Check against iPhone SE 1st Gen's screen height as it is the smallest device that supports iOS 15.
        let isTallEnoughScreen = if #available(iOS 16, *) { true } else { view.frame.height > 568 }
        if isTallEnoughScreen {
            givenNameTextField.becomeFirstResponder()
        }
    }

    private func updateUI() {
        navigationItem.rightBarButtonItem?.isEnabled = givenNameComponent != nil && isTellomiUsernameAcceptable && !isConfirmingTellomiUsername

        // Tellomi（tellomi/tellomi#1215）：没选照片时，默认头像随名字实时变（中文取最后两个字）
        avatarView.image = avatarData?.asImage ?? SSKEnvironment.shared.databaseStorageRef.read { transaction in
            SSKEnvironment.shared.avatarBuilderRef.defaultAvatarImageForLocalUser(
                diameterPoints: UInt(avatarSize),
                previewName: givenNameTextField.text ?? "",
                transaction: transaction,
            )
        }
    }

    // MARK: Events

    private func didTextFieldChange() {
        updateUI()
    }

    @objc
    private func didTapAvatar() {
        Logger.info("")

        let vc = AvatarSettingsViewController(
            context: .profile,
            currentAvatarImage: avatarData?.asImage,
        ) { [weak self] newAvatarImage in
            guard let self else { return }
            if let newAvatarImage {
                self.avatarData = OWSProfileManager.avatarData(avatarImage: newAvatarImage)
            } else {
                self.avatarData = nil
            }
        }
        presentFormSheet(OWSNavigationController(rootViewController: vc), animated: true)
    }

    private func didTapNext() {
        Logger.info("")
        goToNextStepIfPossible()
    }

    private func goToNextStepIfPossible() {
        Logger.info("")

        guard let givenNameComponent else {
            // This can happen if you try to advance via the keyboard.
            return
        }

        // Tellomi（tellomi/tellomi#1215 第二刀）：填了用户名就先确认、成功才保存资料；确认失败人还在这一页
        guard isTellomiUsernameAcceptable, !isConfirmingTellomiUsername else {
            return
        }
        if !isTellomiUsernameConfirmed, !tellomiUsernameText.isEmpty, case .reserved(let reservedUsername) = tellomiUsernameStatus {
            confirmTellomiUsernameThenGoToNextStep(reservedUsername)
            return
        }

        presenter?.goToNextStep(
            givenName: givenNameComponent,
            familyName: nil,
            avatarData: avatarData,
            phoneNumberDiscoverability: state.phoneNumberDiscoverability,
        )
    }

    // MARK: Tellomi username

    private func didUsernameTextFieldChange() {
        if tellomiUsernameText.hasPrefix("@") {
            usernameTextField.text = String(tellomiUsernameText.drop(while: { $0 == "@" }))
        }
        checkTellomiUsername(debounce: true)
    }

    private func checkTellomiUsername(debounce: Bool) {
        tellomiUsernameTask?.cancel()
        tellomiUsernameCandidates = []

        let nickname = tellomiUsernameText
        if nickname.isEmpty {
            tellomiUsernameStatus = .none
            return
        }
        if let error = TellomiRegistrationUsername.check(nickname) {
            tellomiUsernameStatus = .localError(error)
            return
        }

        tellomiUsernameStatus = .checking
        tellomiUsernameTask = Task { @MainActor [weak self] in
            if debounce {
                try? await Task.sleep(nanoseconds: Self.tellomiUsernameDebounce)
            }
            guard !Task.isCancelled, let self, let presenter = self.presenter else {
                return
            }
            let outcome = await presenter.reserveTellomiUsername(nickname: nickname)
            // 只认最后一次：回来时框里已经改了，这个结果就丢掉
            guard !Task.isCancelled, self.tellomiUsernameText == nickname, !self.isTellomiUsernameConfirmed else {
                return
            }
            self.applyTellomiReservationOutcome(outcome, nickname: nickname)
        }
    }

    func applyTellomiReservationOutcome(_ outcome: TellomiRegistrationUsername.ReservationOutcome, nickname: String) {
        switch outcome {
        case .reserved(let reservedUsername):
            tellomiUsernameStatus = .reserved(reservedUsername)
        case .notAvailable:
            tellomiUsernameStatus = .notAvailable
            tellomiUsernameCandidates = TellomiRegistrationUsername.candidates(for: nickname)
        case .cooldown(let days):
            tellomiUsernameStatus = .cooldown(days: days)
        case .tooManyAttempts:
            tellomiUsernameStatus = .tooManyAttempts
        case .failed:
            tellomiUsernameStatus = .checkFailed
        }
        // 读屏：查的结果出来了念一遍（边打边出的格式错误看得见，不逐字念）
        UIAccessibility.post(notification: .announcement, argument: tellomiUsernameStatusText)
    }

    private func didTapTellomiUsernameCandidate(_ candidate: String) {
        usernameTextField.text = candidate
        checkTellomiUsername(debounce: false)
    }

    private func confirmTellomiUsernameThenGoToNextStep(_ reservedUsername: Usernames.HashedUsername) {
        guard let presenter else {
            return
        }
        isConfirmingTellomiUsername = true
        updateUI()

        ModalActivityIndicatorViewController.present(fromViewController: self, canCancel: false, asyncBlock: { [weak self] modal in
            let outcome = await presenter.confirmTellomiUsername(reservedUsername)
            modal.dismiss {
                self?.didConfirmTellomiUsername(outcome)
            }
        })
    }

    private func didConfirmTellomiUsername(_ outcome: TellomiRegistrationUsername.ConfirmationOutcome) {
        isConfirmingTellomiUsername = false
        switch outcome {
        case .confirmed:
            // 确认成功后用户名框锁住：再确认就算改名
            isTellomiUsernameConfirmed = true
            usernameTextField.isEnabled = false
            tellomiUsernameCandidates = []
            updateUI()
            goToNextStepIfPossible()
        case .rejected:
            // 保留过期或被人抢了：重新保留一次，可用就再点「下一步」，不可用就给候选
            Logger.warn("Username reservation was rejected at confirmation. Reserving again.")
            checkTellomiUsername(debounce: false)
        case .failed:
            updateUI()
            OWSActionSheets.showErrorAlert(message: CommonStrings.somethingWentWrongTryAgainLaterError)
        }
    }

    var tellomiUsernameStatusText: String {
        switch tellomiUsernameStatus {
        case .none:
            // 占住一行高度，界面不跳
            return " "
        case .localError(.tooShort):
            return OWSLocalizedString("REGISTRATION_PROFILE_USERNAME_TOO_SHORT_TELLOMI", comment: "Tellomi: registration username is shorter than 3 characters.")
        case .localError(.tooLong):
            return OWSLocalizedString("REGISTRATION_PROFILE_USERNAME_TOO_LONG_TELLOMI", comment: "Tellomi: registration username is longer than 20 characters.")
        case .localError(.invalidCharacters):
            return OWSLocalizedString("REGISTRATION_PROFILE_USERNAME_INVALID_CHARACTERS_TELLOMI", comment: "Tellomi: registration username contains characters other than letters, numbers and underscores.")
        case .localError(.mustStartWithLetter):
            return OWSLocalizedString("REGISTRATION_PROFILE_USERNAME_START_WITH_LETTER_TELLOMI", comment: "Tellomi: registration username does not start with a letter.")
        case .checking:
            return OWSLocalizedString("REGISTRATION_PROFILE_USERNAME_CHECKING_TELLOMI", comment: "Tellomi: registration username is being checked with the server.")
        case .reserved:
            return String(
                format: OWSLocalizedString("REGISTRATION_PROFILE_USERNAME_YOUR_LINK_TELLOMI", comment: "Tellomi: registration username is available. Embeds {{ the link, like tell.cc/kaixin }}."),
                "\(TellomiLinks.host)/\(tellomiUsernameText.lowercased())",
            )
        case .notAvailable:
            return OWSLocalizedString("REGISTRATION_PROFILE_USERNAME_NOT_AVAILABLE_TELLOMI", comment: "Tellomi: registration username is taken or reserved.")
        case .cooldown(let days):
            return String.localizedStringWithFormat(
                OWSLocalizedString(
                    "REGISTRATION_PROFILE_USERNAME_COOLDOWN_TELLOMI_%d",
                    tableName: "PluralAware",
                    comment: "Tellomi: a recycled phone number inherited the previous owner's 30-day username change cooldown. Embeds {{ %d the days left }}. Must fit on one line.",
                ),
                days,
            )
        case .tooManyAttempts:
            return OWSLocalizedString("REGISTRATION_PROFILE_USERNAME_TOO_MANY_ATTEMPTS_TELLOMI", comment: "Tellomi: registration username reservation was rate limited for less than an hour.")
        case .checkFailed:
            return OWSLocalizedString("REGISTRATION_PROFILE_USERNAME_CHECK_FAILED_TELLOMI", comment: "Tellomi: registration username could not be checked because of a network or server error.")
        }
    }

    private func updateTellomiUsernameUI() {
        guard isViewLoaded else {
            return
        }

        usernameStatusLabel.text = tellomiUsernameStatusText
        switch tellomiUsernameStatus {
        case .localError, .notAvailable, .cooldown, .tooManyAttempts, .checkFailed:
            usernameStatusLabel.textColor = .Signal.red
        case .none, .checking, .reserved:
            usernameStatusLabel.textColor = .Signal.secondaryLabel
        }

        switch tellomiUsernameStatus {
        case .checking:
            usernameCheckingIndicator.startAnimating()
            usernameTextField.rightView = usernameCheckingIndicator
        case .reserved:
            usernameCheckingIndicator.stopAnimating()
            usernameTextField.rightView = usernameReservedImageView
        default:
            usernameCheckingIndicator.stopAnimating()
            usernameTextField.rightView = nil
        }

        usernameCandidatesStackView.removeAllSubviews()
        if !tellomiUsernameCandidates.isEmpty {
            let tryLabel = UILabel()
            tryLabel.text = OWSLocalizedString("REGISTRATION_PROFILE_USERNAME_TRY_TELLOMI", comment: "Tellomi: label before the suggested usernames when the one typed is not available.")
            tryLabel.font = .dynamicTypeFootnoteClamped
            tryLabel.textColor = .Signal.secondaryLabel
            usernameCandidatesStackView.addArrangedSubview(tryLabel)
            for candidate in tellomiUsernameCandidates {
                var configuration = UIButton.Configuration.gray()
                configuration.title = candidate
                configuration.cornerStyle = .capsule
                configuration.buttonSize = .small
                let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
                    self?.didTapTellomiUsernameCandidate(candidate)
                })
                button.accessibilityIdentifier = "registration.profile.usernameCandidate"
                usernameCandidatesStackView.addArrangedSubview(button)
            }
            usernameCandidatesStackView.addArrangedSubview(.hStretchingSpacer())
        }
        usernameCandidatesStackView.isHidden = tellomiUsernameCandidates.isEmpty

        updateUI()
    }
}

// MARK: - UITextViewDelegate

extension RegistrationProfileViewController: UITextViewDelegate {
    func textView(
        _ textView: UITextView,
        shouldInteractWith URL: URL,
        in characterRange: NSRange,
        interaction: UITextItemInteraction,
    ) -> Bool {
        if textView == explanationView {
            showLearnMoreUI()
        }
        return false
    }

    private func showLearnMoreUI() {
        let actionSheet = ActionSheetController(
            title: OWSLocalizedString(
                "REGISTRATION_PROFILE_SETUP_MORE_INFO_TITLE",
                comment: "During registration, users set up their profile. They can learn more about the privacy of their profile by clicking a \"learn more\" button. This is the title on a sheet that appears when they do that.",
            ),
            message: OWSLocalizedString(
                "REGISTRATION_PROFILE_SETUP_MORE_INFO_DETAILS",
                comment: "During registration, users set up their profile. They can learn more about the privacy of their profile by clicking a \"learn more\" button. This is the message on a sheet that appears when they do that.",
            ),
        )

        actionSheet.addAction(.init(title: CommonStrings.learnMore) { [weak self] _ in
            guard let self else { return }
            self.present(SFSafariViewController(url: URL.Support.profilesAndMessageRequests), animated: true)
        })

        actionSheet.addAction(.init(title: CommonStrings.okayButton, style: .cancel))

        presentActionSheet(actionSheet)
    }
}

// MARK: - UITextFieldDelegate

extension RegistrationProfileViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        switch textField {
        case givenNameTextField:
            // Tellomi（tellomi/tellomi#1215 第二刀）：下面还有用户名框（已确认、锁住时没有下一项）
            if state.showsTellomiUsername, usernameTextField.isEnabled {
                usernameTextField.becomeFirstResponder()
            } else {
                goToNextStepIfPossible()
            }
        case usernameTextField:
            goToNextStepIfPossible()
        default:
            owsFailBeta("Got a \"return\" event for an unexpected text field")
        }
        return false
    }
}

// MARK: - RegistrationPhoneNumberDiscoverabilityPresenter

extension RegistrationProfileViewController: RegistrationPhoneNumberDiscoverabilityPresenter {

    var presentedAsModal: Bool { return true }

    func setPhoneNumberDiscoverability(_ phoneNumberDiscoverability: PhoneNumberDiscoverability) {
        phoneNumberPrivacyButton.phoneNumberDiscoverability = phoneNumberDiscoverability
        self.state = RegistrationProfileState(
            e164: self.state.e164,
            phoneNumberDiscoverability: phoneNumberDiscoverability,
            showsTellomiUsername: self.state.showsTellomiUsername,
        )
        self.presentedViewController?.dismiss(animated: true)
    }
}

// MARK: - Phone number privacy button

extension RegistrationProfileViewController {

    private class PhoneNumberPrivacyButton: UIButton {

        private lazy var contentView = PhoneNumberPrivacyButtonContentView(
            configuration: .init(phoneNumberDiscoverability: phoneNumberDiscoverability),
        )

        var phoneNumberDiscoverability: PhoneNumberDiscoverability {
            didSet {
                contentView.configuration = PhoneNumberPrivacyButtonContentConfiguration(
                    phoneNumberDiscoverability: phoneNumberDiscoverability,
                )
            }
        }

        init(phoneNumberDiscoverability: PhoneNumberDiscoverability) {
            self.phoneNumberDiscoverability = phoneNumberDiscoverability

            super.init(frame: .zero)

            configuration = .filled()
            configuration?.baseBackgroundColor = .Signal.background

            addSubview(contentView)
            contentView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
                contentView.topAnchor.constraint(equalTo: topAnchor),
                contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
                contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        // MARK: Accessibility

        override var accessibilityLabel: String? {
            get {
                OWSLocalizedString(
                    "REGISTRATION_PROFILE_SETUP_FIND_MY_NUMBER_TITLE",
                    comment: "During registration, users can choose who can see their phone number.",
                )
            }
            set { super.accessibilityLabel = newValue }
        }

        override var accessibilityValue: String? {
            get { phoneNumberDiscoverability.nameForDiscoverability }
            set { super.accessibilityValue = newValue }
        }

        override var accessibilityHint: String? {
            get { phoneNumberDiscoverability.descriptionForDiscoverability }
            set { super.accessibilityHint = newValue }
        }
    }

    private struct PhoneNumberPrivacyButtonContentConfiguration: UIContentConfiguration {
        var phoneNumberDiscoverability: PhoneNumberDiscoverability

        func makeContentView() -> UIView & UIContentView {
            PhoneNumberPrivacyButtonContentView(configuration: self)
        }

        func updated(for state: UIConfigurationState) -> PhoneNumberPrivacyButtonContentConfiguration {
            // Looks the same.
            self
        }
    }

    private class PhoneNumberPrivacyButtonContentView: UIView, UIContentView {

        private var _configuration: PhoneNumberPrivacyButtonContentConfiguration!

        var configuration: UIContentConfiguration {
            get { _configuration }
            set {
                guard let configuration = newValue as? PhoneNumberPrivacyButtonContentConfiguration else { return }
                _configuration = configuration
                apply(configuration)
            }
        }

        init(configuration: PhoneNumberPrivacyButtonContentConfiguration) {
            super.init(frame: .zero)

            isUserInteractionEnabled = false
            layoutMargins = .init(hMargin: 0, vMargin: 8)

            let vStack = UIStackView(arrangedSubviews: [titleLabel, subTitleLabel])
            vStack.axis = .vertical
            vStack.spacing = 4

            let disclosureView = UIImageView()
            disclosureView.contentMode = .scaleAspectFit
            disclosureView.setTemplateImage(
                UIImage(imageLiteralResourceName: "chevron-right-20"),
                tintColor: .Signal.tertiaryLabel,
            )
            disclosureView.translatesAutoresizingMaskIntoConstraints = false
            disclosureView.widthAnchor.constraint(equalToConstant: 24).isActive = true

            let hStack = UIStackView(arrangedSubviews: [
                iconView,
                vStack,
                disclosureView,
            ])
            hStack.axis = .horizontal
            hStack.spacing = 12
            hStack.alignment = .center

            addSubview(hStack)
            hStack.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                hStack.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor),
                hStack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor, constant: 8),
                hStack.bottomAnchor.constraint(equalTo: layoutMarginsGuide.bottomAnchor),
                hStack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor, constant: -8),
            ])

            apply(configuration)
        }

        @available(*, unavailable, message: "Use other constructor")
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        private lazy var iconView: UIImageView = {
            let iconView = UIImageView()
            iconView.tintColor = .Signal.label
            iconView.contentMode = .scaleAspectFit
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.widthAnchor.constraint(equalToConstant: 24).isActive = true
            return iconView
        }()

        private lazy var titleLabel: UILabel = {
            let titleLabel = UILabel()
            titleLabel.font = .dynamicTypeBodyClamped
            titleLabel.textColor = .Signal.label
            titleLabel.numberOfLines = 0
            titleLabel.lineBreakMode = .byWordWrapping
            titleLabel.text = OWSLocalizedString(
                "REGISTRATION_PROFILE_SETUP_FIND_MY_NUMBER_TITLE",
                comment: "During registration, users can choose who can see their phone number.",
            )
            return titleLabel
        }()

        private lazy var subTitleLabel: UILabel = {
            let subTitleLabel = UILabel()
            subTitleLabel.font = .dynamicTypeSubheadlineClamped
            subTitleLabel.textColor = .Signal.secondaryLabel
            subTitleLabel.numberOfLines = 0
            subTitleLabel.lineBreakMode = .byWordWrapping
            return subTitleLabel
        }()

        private func apply(_ configuration: PhoneNumberPrivacyButtonContentConfiguration) {
            let discoverability = configuration.phoneNumberDiscoverability

            subTitleLabel.text = discoverability.nameForDiscoverability

            let labelIconName: String = {
                switch discoverability {
                case .everybody:
                    return "group"
                case .nobody:
                    return "lock"
                }
            }()
            iconView.image = UIImage(named: labelIconName)
        }
    }
}

// MARK: - Data <-> UIImage conversions

private extension Data {
    var asImage: UIImage? { .init(data: self) }
}
