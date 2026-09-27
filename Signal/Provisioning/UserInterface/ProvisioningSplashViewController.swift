//
// Copyright 2019 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SafariServices
import SignalServiceKit
import SignalUI
import UIKit

class ProvisioningSplashViewController: ProvisioningBaseViewController {

    var prefersNavigationBarHidden: Bool {
        true
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        navigationItem.hidesBackButton = true

        let modeSwitchButton = UIButton(
            configuration: .plain(),
            primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                self.provisioningController.provisioningSplashRequestedModeSwitch(viewController: self)
            },
        )
        modeSwitchButton.configuration?.image = .linkSlash
        modeSwitchButton.tintColor = .ows_gray25
        view.addSubview(modeSwitchButton)
        modeSwitchButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            modeSwitchButton.widthAnchor.constraint(equalToConstant: 40),
            modeSwitchButton.heightAnchor.constraint(equalToConstant: 40),
            modeSwitchButton.trailingAnchor.constraint(equalTo: contentLayoutGuide.trailingAnchor),
            modeSwitchButton.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor),
        ])

        // Image at the top.
        // Tellomi（owner 2026-09-27，docs/brand/README.md「插画」）：Signal 的插画换成开屏轮播的第一张 Open Doodles（荡秋千），静态；插画是装饰，读屏跳过。
        let imageView = UIImageView(image: UIImage(named: "tellomi_splash_swinging"))
        imageView.accessibilityIdentifier = "tellomi.provisioningSplash.illustration"
        imageView.accessibilityElementsHidden = true
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

        let titleText = {
            if TSConstants.isUsingProductionService {
                return OWSLocalizedString(
                    "ONBOARDING_SPLASH_TITLE",
                    comment: "Title of the 'onboarding splash' view.",
                )
            } else {
                return "Internal Staging Build\n\(AppVersionImpl.shared.currentAppVersion)"
            }
        }()
        let titleLabel = UILabel.titleLabelForRegistration(text: titleText)
        titleLabel.accessibilityIdentifier = "onboarding.splash." + "titleLabel"

        // Terms of service and privacy policy.
        let tosPPButton = UIButton(
            configuration: .smallBorderless(title: OWSLocalizedString(
                "ONBOARDING_SPLASH_TERM_AND_PRIVACY_POLICY",
                comment: "Link to the 'terms and privacy policy' in the 'onboarding splash' view.",
            )),
            primaryAction: UIAction { [weak self] _ in
                self?.present(SFSafariViewController(url: TSConstants.legalTermsUrl), animated: true)

            },
        )
        tosPPButton.configuration?.baseForegroundColor = .Signal.secondaryLabel
        tosPPButton.accessibilityTraits.insert(.link)
        tosPPButton.enableMultilineLabel()
        tosPPButton.accessibilityIdentifier = "onboarding.splash.explanationLabel"

        let continueButton = UIButton(
            configuration: .largePrimary(title: CommonStrings.continueButton),
            primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    await self.provisioningController.provisioningSplashDidComplete(viewController: self)
                }
            },
        )
        continueButton.accessibilityIdentifier = "onboarding.splash.continueButton"

        let stackView = addStaticContentStackView(arrangedSubviews: [
            heroImageContainer,
            titleLabel,
            tosPPButton,
            continueButton.enclosedInVerticalStackView(isFullWidthButton: true),
        ])
        stackView.setCustomSpacing(44, after: imageView)
        stackView.setCustomSpacing(82, after: tosPPButton)

        view.bringSubviewToFront(modeSwitchButton)
    }
}
