//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

// MARK: - RegistrationCaptchaPresenter

protocol RegistrationCaptchaPresenter: AnyObject {
    func submitCaptcha(_ token: String)
}

// MARK: - RegistrationCaptchaViewController

class RegistrationCaptchaViewController: OWSViewController {
    private weak var presenter: RegistrationCaptchaPresenter?

    init(presenter: RegistrationCaptchaPresenter) {
        self.presenter = presenter

        super.init()

        navigationItem.hidesBackButton = true
    }

    @available(*, unavailable)
    override init() {
        owsFail("This should not be called")
    }

    // MARK: - Rendering

    private lazy var captchaView: CaptchaView = {
        let result = CaptchaView(context: .registration)
        result.delegate = self
        return result
    }()

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .Signal.background

        let titleLabel = UILabel.titleLabelForRegistration(text: OWSLocalizedString(
            "REGISTRATION_CAPTCHA_TITLE",
            comment: "During registration, users may be shown a CAPTCHA to verify that they're human. This text is shown above the CAPTCHA.",
        ))
        titleLabel.setContentHuggingHigh()
        titleLabel.accessibilityIdentifier = "registration.captcha.titleLabel"

        addStaticContentStackView(arrangedSubviews: [titleLabel, captchaView])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        captchaView.loadCaptcha()
    }
}

// MARK: - CaptchaViewDelegate

extension RegistrationCaptchaViewController: CaptchaViewDelegate {
    func captchaView(_: CaptchaView, didCompleteCaptchaWithToken token: String) {
        presenter?.submitCaptcha(token)
    }

    func captchaViewDidFailToCompleteCaptcha(_ captchaView: CaptchaView) {
        // Tellomi：上游在这里立刻重载。页面加载失败（网络不通、验证页打不开）时就变成无限静默重载，
        // 用户只看到一个空白页、这一页又没有返回键。改成说清楚原因，让用户自己点「重试」（tellomi/tellomi#1209）。
        let actionSheet = ActionSheetController(
            title: OWSLocalizedString(
                "REGISTRATION_NETWORK_ERROR_TITLE",
                comment: "A network error occurred during registration, and an error is shown to the user. This is the title on that error sheet.",
            ),
            message: OWSLocalizedString(
                "REGISTRATION_NETWORK_ERROR_BODY",
                comment: "A network error occurred during registration, and an error is shown to the user. This is the body on that error sheet.",
            ),
        )
        actionSheet.addAction(ActionSheetAction(title: CommonStrings.retryButton, style: .default) { _ in
            captchaView.loadCaptcha()
        })
        // 这一页没有返回键：不能让用户把提示关掉、停在空白页上。
        actionSheet.isCancelable = false
        presentActionSheet(actionSheet)
    }
}

// MARK: -

#if DEBUG

private class PreviewRegistrationCaptchaPresenter: RegistrationCaptchaPresenter {
    func submitCaptcha(_ token: String) {
        print("submitCaptcha")
    }
}

@available(iOS 17, *)
#Preview {
    let presenter = PreviewRegistrationCaptchaPresenter()
    return UINavigationController(
        rootViewController: RegistrationCaptchaViewController(
            presenter: presenter,
        ),
    )
}

#endif
