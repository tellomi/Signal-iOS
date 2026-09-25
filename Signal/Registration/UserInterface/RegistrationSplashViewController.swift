//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SafariServices
import SignalServiceKit
public import SignalUI

// MARK: - RegistrationSplashPresenter

public protocol RegistrationSplashPresenter: AnyObject {
    func continueFromSplash()
    func setHasOldDevice(_ hasOldDevice: Bool)

    func switchToDeviceLinkingMode()
}

// MARK: - RegistrationSplashViewController

public class RegistrationSplashViewController: OWSViewController, OWSNavigationChildController {

    public var prefersNavigationBarHidden: Bool {
        true
    }

    private weak var presenter: RegistrationSplashPresenter?

    public init(presenter: RegistrationSplashPresenter) {
        self.presenter = presenter
        super.init()
    }

    override public func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .Signal.background

        if UIDevice.current.isIPad {
            let modeSwitchButton = UIButton(
                configuration: .plain(),
                primaryAction: UIAction { [weak self] _ in
                    self?.didTapModeSwitch()
                },
            )
            modeSwitchButton.configuration?.image = .link
            modeSwitchButton.tintColor = .ows_gray25

            view.addSubview(modeSwitchButton)
            modeSwitchButton.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                modeSwitchButton.widthAnchor.constraint(equalToConstant: 40),
                modeSwitchButton.heightAnchor.constraint(equalToConstant: 40),
                modeSwitchButton.trailingAnchor.constraint(equalTo: contentLayoutGuide.trailingAnchor),
                modeSwitchButton.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor),
            ])
        }

        // Image at the top.
        let imageView = UIImageView(image: UIImage(named: "onboarding_splash_hero"))
        imageView.contentMode = .scaleAspectFit
        imageView.layer.minificationFilter = .trilinear
        imageView.layer.magnificationFilter = .trilinear
        imageView.setCompressionResistanceLow()
        imageView.setContentHuggingVerticalLow()
        let heroImageContainer = UIView.container()
        heroImageContainer.addSubview(imageView)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        // Center image vertically in the available space above title text.
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: heroImageContainer.centerXAnchor),
            imageView.widthAnchor.constraint(equalTo: heroImageContainer.widthAnchor),
            imageView.centerYAnchor.constraint(equalTo: heroImageContainer.centerYAnchor),
            imageView.heightAnchor.constraint(equalTo: heroImageContainer.heightAnchor, constant: 0.8),
        ])

        // Welcome text.
        // Tellomi：上游按「是不是 Signal 生产服务」决定标题，非生产显示「Internal Staging Build + 版本号」。
        // Tellomi 的所有构建都连自建服务端（TSConstants 永远走 staging 那一档），于是每个对外的包首屏都是这行英文调试串。
        // 版本号在「设置 → 帮助」里有，这里一律用正式标题（tellomi/tellomi#1209）。
        let titleText = OWSLocalizedString(
            "ONBOARDING_SPLASH_TITLE",
            comment: "Title of the 'onboarding splash' view.",
        )
        let titleLabel = UILabel.titleLabelForRegistration(text: titleText)

        // Tellomi：上游这里是「Signal 是一个非营利组织」。整行去掉，不做替换——
        // Tellomi 不是非营利组织，换成「Tellomi 是一个非营利组织」是假陈述；
        // 留着原文又是在我们自己的登录页上写别人的名字。捐赠 / 非营利那一整类文案同理，
        // 都在 build/brand-strings-todo.txt 里等 owner 定，不由脚本自动替换。

        // Terms of service and privacy policy.
        let tosPPButton = UIButton(
            configuration: .smallBorderless(title: OWSLocalizedString(
                "ONBOARDING_SPLASH_TERM_AND_PRIVACY_POLICY",
                comment: "Link to the 'terms and privacy policy' in the 'onboarding splash' view.",
            )),
            primaryAction: UIAction { [weak self] _ in
                self?.showTOSPP()
            },
        )
        tosPPButton.configuration?.baseForegroundColor = .Signal.secondaryLabel
        tosPPButton.accessibilityTraits.insert(.link)
        tosPPButton.enableMultilineLabel()

        // Large buttons enclosed in a container with some extra horizontal padding.
        let continueButton = UIButton(
            configuration: .largePrimary(title: CommonStrings.continueButton),
            primaryAction: UIAction { [weak self] _ in
                self?.continuePressed()
            },
        )

        let restoreOrTransferButton = UIButton(
            configuration: .largeSecondary(title: OWSLocalizedString(
                "ONBOARDING_SPLASH_RESTORE_OR_TRANSFER_BUTTON_TITLE",
                comment: "Button for restoring or transferring account in the 'onboarding splash' view.",
            )),
            primaryAction: UIAction { [weak self] _ in
                self?.didTapRestoreOrTransfer()
            },
        )
        restoreOrTransferButton.enableMultilineLabel()

        let largeButtonsContainer = UIStackView.verticalButtonStack(buttons: [continueButton, restoreOrTransferButton])

        // Main content view.
        let stackView = addStaticContentStackView(arrangedSubviews: [
            heroImageContainer,
            titleLabel,
            tosPPButton,
            largeButtonsContainer,
        ])
        stackView.setCustomSpacing(44, after: imageView)
        stackView.setCustomSpacing(24, after: titleLabel)
        stackView.setCustomSpacing(80, after: tosPPButton)

        view.sendSubviewToBack(stackView)
    }

    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        // Tellomi：第一次打开先弹一次隐私提示（2019《认定方法》：首次运行要用弹窗等明显方式提示隐私政策；
        // tellomi/tellomi#1211）。同意之前这一页的按钮都被挡在提示后面。
        if !TellomiLegalConsent.hasAcceptedFirstLaunchNotice, presentedViewController == nil {
            presentTellomiFirstLaunchNotice()
        }
    }

    // MARK: - Events

    private func didTapModeSwitch() {
        Logger.info("")
        presenter?.switchToDeviceLinkingMode()
    }

    private func showTOSPP() {
        let safariVC = SFSafariViewController(url: TSConstants.legalTermsUrl)
        present(safariVC, animated: true)
    }

    private func continuePressed() {
        Logger.info("")
        presenter?.continueFromSplash()
    }

    private func didTapRestoreOrTransfer() {
        Logger.info("")
        let sheet = RestoreOrTransferPickerController(
            setHasOldDeviceBlock: { [weak self] hasOldDevice in
                self?.dismiss(animated: true) {
                    self?.presenter?.setHasOldDevice(hasOldDevice)
                }
            },
        )
        self.present(sheet, animated: true)
    }
}

private class RestoreOrTransferPickerController: StackSheetViewController {

    override var placeOnGlassIfAvailable: Bool { false }

    private let setHasOldDeviceBlock: (Bool) -> Void
    init(setHasOldDeviceBlock: @escaping (Bool) -> Void) {
        self.setHasOldDeviceBlock = setHasOldDeviceBlock
        super.init()
    }

    override open var sheetBackgroundColor: UIColor { .Signal.secondaryBackground }

    override func viewDidLoad() {
        super.viewDidLoad()
        stackView.spacing = 16

        let hasDeviceButton = UIButton.registrationChoiceButton(
            title: OWSLocalizedString(
                "ONBOARDING_SPLASH_HAVE_OLD_DEVICE_TITLE",
                comment: "Title for the 'have my old device' choice of the 'Restore or Transfer' prompt",
            ),
            subtitle: OWSLocalizedString(
                "ONBOARDING_SPLASH_HAVE_OLD_DEVICE_BODY",
                comment: "Explanation of 'have old device' flow for the 'Restore or Transfer' prompt",
            ),
            iconName: "qr-code-48",
            primaryAction: UIAction { [weak self] _ in
                self?.setHasOldDeviceBlock(true)
            },
        )
        stackView.addArrangedSubview(hasDeviceButton)

        let noDeviceButton = UIButton.registrationChoiceButton(
            title: OWSLocalizedString(
                "ONBOARDING_SPLASH_DO_NOT_HAVE_OLD_DEVICE_TITLE",
                comment: "Title for the 'do not have my old device' choice of the 'Restore or Transfer' prompt",
            ),
            subtitle: OWSLocalizedString(
                "ONBOARDING_SPLASH_DO_NOT_HAVE_OLD_DEVICE_BODY",
                comment: "Explanation of 'do not have old device' flow for the 'Restore or Transfer' prompt",
            ),
            iconName: "no-phone-48",
            primaryAction: UIAction { [weak self] _ in
                self?.setHasOldDeviceBlock(false)
            },
        )
        stackView.addArrangedSubview(noDeviceButton)
    }
}

// MARK: -

#if DEBUG
private class PreviewRegistrationSplashPresenter: RegistrationSplashPresenter {
    func continueFromSplash() {
        print("continueFromSplash")
    }

    func setHasOldDevice(_ hasOldDevice: Bool) {
        print("setHasOldDevice: \(hasOldDevice)")
    }

    func switchToDeviceLinkingMode() {
        print("switchToDeviceLinkingMode")
    }

    func transferDevice() {
        print("transferDevice")
    }
}

@available(iOS 17, *)
#Preview {
    let presenter = PreviewRegistrationSplashPresenter()
    return RegistrationSplashViewController(presenter: presenter)
}
#endif
