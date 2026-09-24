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

        // Tellomi：上游「恢复或转移账户」和「继续」一样大，而 Tellomi 能走通的只有一条路（iPhone 到 iPhone 直连传输），
        // 大多数人是第一次注册。降成主按钮下面一行文字链，和 Telegram 欢迎页把次要动作放在主按钮下方一行文字里一样
        // （tellomi/tellomi#1216）。以后有了云备份，入口还在这里，只是里面多几条路。
        let restoreOrTransferButton = UIButton(
            configuration: .mediumBorderless(title: OWSLocalizedString(
                "ONBOARDING_SPLASH_NEW_PHONE_LINK_TITLE",
                comment: "Tellomi: One-line text link under the 'Continue' button in the 'onboarding splash' view, for people moving to a new phone.",
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
            registerDirectlyBlock: { [weak self] in
                self?.dismiss(animated: true) {
                    self?.presenter?.continueFromSplash()
                }
            },
        )
        self.present(sheet, animated: true)
    }
}

private class RestoreOrTransferPickerController: StackSheetViewController {

    override var placeOnGlassIfAvailable: Bool { false }

    private let setHasOldDeviceBlock: (Bool) -> Void
    private let registerDirectlyBlock: () -> Void
    init(setHasOldDeviceBlock: @escaping (Bool) -> Void, registerDirectlyBlock: @escaping () -> Void) {
        self.setHasOldDeviceBlock = setHasOldDeviceBlock
        self.registerDirectlyBlock = registerDirectlyBlock
        super.init()
    }

    override open var sheetBackgroundColor: UIColor { .Signal.secondaryBackground }

    override func viewDidLoad() {
        super.viewDidLoad()
        stackView.spacing = 16

        if !TSConstants.backupServiceAvailable {
            addTellomiChoices()
            return
        }

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

    /// Tellomi：没有备份服务时，上游「旧手机不在身边」后面只剩走不通的路——「恢复 Tellomi 安全备份」要输恢复密钥，
    /// 而这套部署根本没有备份服务；本地文件备份恢复只在 Debug 包里有（`BuildFlags.LocalFileBackups.restore`）。
    /// 所以这里只列两条真能走通的：旧 iPhone 在身边就扫码直连传输；否则直接注册，并说清以前的聊天记录不会跟过来
    /// （tellomi/tellomi#1216）。
    private func addTellomiChoices() {
        stackView.addArrangedSubview(UIButton.registrationChoiceButton(
            title: OWSLocalizedString(
                "ONBOARDING_SPLASH_TELLOMI_HAVE_OLD_IPHONE_TITLE",
                comment: "Tellomi: Title for the 'my old iPhone is here' choice after tapping 'New phone?' in the 'onboarding splash' view.",
            ),
            subtitle: OWSLocalizedString(
                "ONBOARDING_SPLASH_TELLOMI_HAVE_OLD_IPHONE_BODY",
                comment: "Tellomi: Explanation of the 'my old iPhone is here' choice: scan a QR code with the old iPhone to transfer the account and messages directly.",
            ),
            iconName: "qr-code-48",
            primaryAction: UIAction { [weak self] _ in
                self?.setHasOldDeviceBlock(true)
            },
        ))
        stackView.addArrangedSubview(UIButton.registrationChoiceButton(
            title: OWSLocalizedString(
                "ONBOARDING_SPLASH_TELLOMI_REGISTER_DIRECTLY_TITLE",
                comment: "Tellomi: Title for the choice to register directly (old phone is not at hand, or is an Android phone) after tapping 'New phone?' in the 'onboarding splash' view.",
            ),
            subtitle: OWSLocalizedString(
                "ONBOARDING_SPLASH_TELLOMI_REGISTER_DIRECTLY_BODY",
                comment: "Tellomi: Explanation of the 'register directly' choice: registering works, but earlier messages won't come to this phone.",
            ),
            iconName: "continue-48",
            primaryAction: UIAction { [weak self] _ in
                self?.registerDirectlyBlock()
            },
        ))
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
