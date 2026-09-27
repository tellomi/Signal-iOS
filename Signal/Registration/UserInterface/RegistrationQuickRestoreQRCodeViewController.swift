//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import SwiftUI

protocol RegistrationMethodPresenter: AnyObject {
    func cancelChosenRestoreMethod()
}

protocol RegistrationQuickRestoreQRCodePresenter: RegistrationMethodPresenter {
    func didReceiveRegistrationMessage(_ message: RegistrationProvisioningMessage)
}

class RegistrationQuickRestoreQRCodeViewController: BaseQuickRestoreQRCodeViewController {
    private weak var presenter: RegistrationQuickRestoreQRCodePresenter?

    /// Tellomi：socket 管理器可以从外面传进来（默认和上游一样自己 new 一个），单测才能换成不连网的替身。
    init(
        presenter: RegistrationQuickRestoreQRCodePresenter,
        provisioningSocketManager: ProvisioningSocketManager = ProvisioningSocketManager(linkType: .quickRestore),
    ) {
        self.presenter = presenter
        super.init(provisioningSocketManager: provisioningSocketManager)
    }

    override func cancel() {
        super.cancel()
        presenter?.cancelChosenRestoreMethod()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        // Tellomi（tellomi/tellomi#1133）：没同意跨境时基类先弹告知，这时先不等消息；同意之后在 crossBorderNoticeAgreed() 里等。
        // 不然会等两次，第二次 waitForMessage 报 OWSAssertionError（Debug 构建直接断言）。
        guard TellomiCrossBorderConsent.hasAgreed else { return }
        waitForRegistrationMessage()
    }

    /// Tellomi（tellomi/tellomi#1338，需求 6.6）：告知改成 overFullScreen 的小弹窗后，关掉弹窗时本页不再走 viewDidAppear，
    /// 原来靠那一次开始等消息；现在同意之后直接开始等。
    override func crossBorderNoticeAgreed() {
        super.crossBorderNoticeAgreed()
        waitForRegistrationMessage()
    }

    private func waitForRegistrationMessage() {
        Task { [self] in
            do {
                let message = try await waitForMessage()
                presenter?.didReceiveRegistrationMessage(message)
            } catch {
                let title = OWSLocalizedString(
                    "REGISTRATION_SCAN_QR_CODE_FAILED_TITLE",
                    comment: "Title of error notifying restore failed.",
                )
                let body = OWSLocalizedString(
                    "REGISTRATION_SCAN_QR_CODE_FAILED_BODY",
                    comment: "Body of error notifying restore failed.",
                )
                let sheet = HeroSheetViewController(
                    hero: .circleIcon(
                        icon: .alert,
                        iconSize: 36,
                        tintColor: UIColor.Signal.label,
                        backgroundColor: UIColor.Signal.background,
                    ),
                    title: title,
                    body: body,
                    primaryButton: .init(title: CommonStrings.okayButton, action: { [weak self] _ in
                        self?.reset()
                        self?.presentedViewController?.dismiss(animated: true)
                    }),
                )
                present(sheet, animated: true)
            }
        }
    }
}
