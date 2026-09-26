//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import SignalServiceKit
import SignalUI

protocol LinkDeviceViewControllerDelegate: AnyObject {
    typealias LinkNSyncData = (ephemeralBackupKey: MessageRootBackupKey, tokenId: DeviceProvisioningTokenId)
    @MainActor
    func didFinishLinking(_ linkNSyncData: LinkNSyncData?, from linkDeviceViewController: LinkDeviceViewController)
}

class LinkDeviceViewController: OWSViewController {

    weak var delegate: LinkDeviceViewControllerDelegate?
    private var context = ViewControllerContext.shared

    private var hasShownEducationSheet: Bool
    private weak var educationSheet: HeroSheetViewController?

    // Tellomi（#1219）：只认对准画面中心、连续对准 0.5 秒的码，免得扫到旁边别人屏幕上的关联码（见 TellomiQrFocus）
    private lazy var qrCodeScanViewController = QRCodeScanViewController(appearance: .framed, tellomiRequiresCenteredStableCode: true)

    init(skipEducationSheet: Bool) {
        self.hasShownEducationSheet = skipEducationSheet
        super.init()
    }

    // MARK: -

    override func viewDidLoad() {
        super.viewDidLoad()

        title = CommonStrings.scanQRCodeTitle

#if TESTABLE_BUILD
        navigationItem.rightBarButtonItem = .init(
            title: LocalizationNotNeeded("ENTER"),
            primaryAction: UIAction { [weak self] _ in self?.manuallyEnterLinkURL() },
        )
#endif

        qrCodeScanViewController.delegate = self

        addChild(qrCodeScanViewController)
        view.addSubview(qrCodeScanViewController.view)

        qrCodeScanViewController.view.autoPinEdgesToSuperviewEdges()
        qrCodeScanViewController.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        if !UIDevice.current.isIPad {
            UIDevice.current.ows_setOrientation(.portrait)
        }

        if !hasShownEducationSheet {
            let animationName = if traitCollection.userInterfaceStyle == .dark {
                "linking-device-dark"
            } else {
                "linking-device-light"
            }

            let sheet = HeroSheetViewController(
                hero: .animation(named: animationName, height: 192),
                title: OWSLocalizedString(
                    "LINK_DEVICE_SCANNING_INSTRUCTIONS_SHEET_TITLE",
                    comment: "Title for QR Scanning screen instructions sheet",
                ),
                body: OWSLocalizedString(
                    "LINK_DEVICE_SCANNING_INSTRUCTIONS_SHEET_BODY",
                    comment: "Title for QR Scanning screen instructions sheet",
                ),
                primaryButton: .dismissing(title: CommonStrings.okayButton),
            )

            DispatchQueue.main.async {
                self.present(sheet, animated: true)
                self.hasShownEducationSheet = true
                self.educationSheet = sheet
            }
        }
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        UIDevice.current.isIPad ? .all : .portrait
    }

    private func dismissEducationSheetIfNecessary(completion: @escaping () -> Void) {
        if let educationSheet {
            educationSheet.dismiss(animated: true, completion: completion)
        } else {
            completion()
        }
    }

    private func safePresent(_ viewController: UIViewController) {
        dismissEducationSheetIfNecessary { [weak self] in
            self?.present(viewController, animated: true)
        }
    }

    // MARK: -

    private func confirmProvisioning(deviceProvisioningUrl: DeviceProvisioningURL) {
        switch deviceProvisioningUrl.linkType {
        case .linkDevice:
            break
        case .quickRestore:
            owsFailDebug("can't link with a quick restore url")
            return
        }
        if
            deviceProvisioningUrl.capabilities.contains(.linknsync)
        {
            let linkOrSyncSheet: LinkOrSyncPickerSheet = .load(
                didDismiss: {
                    self.popToLinkedDeviceList()
                },
                linkAndSync: {
                    self.provisionWithUrl(deviceProvisioningUrl, shouldLinkNSync: true)
                },
                linkOnly: {
                    self.provisionWithUrl(deviceProvisioningUrl, shouldLinkNSync: false)
                },
            )

            self.safePresent(linkOrSyncSheet)
        } else {
            let title = NSLocalizedString(
                "LINK_DEVICE_PERMISSION_ALERT_TITLE",
                comment: "confirm the users intent to link a new device",
            )
            let linkingDescription = NSLocalizedString(
                "LINK_DEVICE_PERMISSION_ALERT_BODY",
                comment: "confirm the users intent to link a new device",
            )

            let actionSheet = ActionSheetController(title: title, message: linkingDescription)
            actionSheet.addAction(ActionSheetAction(
                title: CommonStrings.cancelButton,
                style: .cancel,
                handler: { _ in
                    DispatchQueue.main.async {
                        self.popToLinkedDeviceList()
                    }
                },
            ))
            actionSheet.addAction(ActionSheetAction(
                title: NSLocalizedString("CONFIRM_LINK_NEW_DEVICE_ACTION", comment: "Button text"),
                style: .default,
                handler: { _ in
                    self.provisionWithUrl(deviceProvisioningUrl, shouldLinkNSync: false)
                },
            ))
            safePresent(actionSheet)
        }
    }

    private func provisionWithUrl(
        _ deviceProvisioningUrl: DeviceProvisioningURL,
        shouldLinkNSync: Bool,
    ) {
        Task { [self] in
            do {
                let (ephemeralBackupKey, tokenId) = try await context.provisioningManager.provision(
                    with: deviceProvisioningUrl,
                    shouldLinkNSync: shouldLinkNSync,
                )
                Logger.info("Successfully provisioned device.")

                self.delegate?.didFinishLinking(
                    ephemeralBackupKey.map { ($0, tokenId) },
                    from: self,
                )
            } catch {
                Logger.error("Failed to provision device with error: \(error)")
                let actionSheet = self.retryActionSheetController(error: error, retryBlock: { [weak self] in
                    self?.provisionWithUrl(deviceProvisioningUrl, shouldLinkNSync: shouldLinkNSync)
                })
                self.safePresent(actionSheet)
            }
        }
    }

    private func retryActionSheetController(error: Error, retryBlock: @escaping () -> Void) -> ActionSheetController {
        switch error {
        case let error as DeviceLimitExceededError:
            let actionSheet = ActionSheetController(
                title: error.errorDescription,
                message: error.recoverySuggestion,
            )
            actionSheet.addAction(ActionSheetAction(
                title: CommonStrings.okButton,
                handler: { [weak self] _ in
                    self?.popToLinkedDeviceList()
                },
            ))
            return actionSheet

        case _ where Self.tellomiIsExpiredOrForeignCode(error):
            // Tellomi（#1219）：「重试」只会再往同一个地址发一次、再拿一次 404，所以这里给「重新扫描」。
            let actionSheet = ActionSheetController(
                title: OWSLocalizedString("LINKING_DEVICE_FAILED_TITLE", comment: "Alert Title"),
                message: Self.tellomiExpiredOrForeignCodeMessage(),
            )
            actionSheet.addAction(ActionSheetAction(
                title: OWSLocalizedString(
                    "LINK_DEVICE_RESTART_TELLOMI_SCAN_AGAIN",
                    comment: "Tellomi (#1219): button that restarts the QR scanner after linking failed",
                ),
                style: .default,
                handler: { [weak self] _ in
                    self?.qrCodeScanViewController.tryToStartScanning()
                },
            ))
            actionSheet.addAction(ActionSheetAction(
                title: CommonStrings.cancelButton,
                style: .cancel,
                handler: { [weak self] _ in
                    DispatchQueue.main.async { self?.popToLinkedDeviceList() }
                },
            ))
            return actionSheet

        default:
            let actionSheet = ActionSheetController(
                title: OWSLocalizedString("LINKING_DEVICE_FAILED_TITLE", comment: "Alert Title"),
                message: Self.tellomiFailureMessage(for: error),
            )
            actionSheet.addAction(ActionSheetAction(
                title: CommonStrings.retryButton,
                style: .default,
                handler: { action in retryBlock() },
            ))
            actionSheet.addAction(ActionSheetAction(
                title: CommonStrings.cancelButton,
                style: .cancel,
                handler: { [weak self] action in
                    DispatchQueue.main.async { self?.dismiss(animated: true) }
                },
            ))
            return actionSheet
        }
    }

    func popToLinkedDeviceList(_ completion: (() -> Void)? = nil) {
        dismissEducationSheetIfNecessary { [weak navigationController] in
            navigationController?.popViewController(animated: true)
            // The method for adding a completion handler to popViewController in
            // UIViewController+SignalUI doesn't play well with UIHostingController
            navigationController?.transitionCoordinator?.animate(alongsideTransition: nil) { _ in
                UIViewController.attemptRotationToDeviceOrientation()
                completion?()
            }
        }
    }

#if TESTABLE_BUILD
    private func manuallyEnterLinkURL() {
        let alertController = UIAlertController(
            title: LocalizationNotNeeded("Manually enter linking code."),
            message: LocalizationNotNeeded("Copy the URL represented by the QR code into the field below."),
            preferredStyle: .alert,
        )
        alertController.addTextField()
        alertController.addAction(UIAlertAction(
            title: CommonStrings.okayButton,
            style: .default,
            handler: { _ in
                guard let qrCodeString = alertController.textFields?.first?.text else { return }
                self.qrCodeScanViewScanned(
                    qrCodeData: nil,
                    qrCodeString: qrCodeString,
                )
            },
        ))
        alertController.addAction(UIAlertAction(
            title: CommonStrings.cancelButton,
            style: .cancel,
        ))
        safePresent(alertController)
    }
#endif
}

extension LinkDeviceViewController: QRCodeScanDelegate {
    @discardableResult
    func qrCodeScanViewScanned(
        qrCodeData: Data?,
        qrCodeString: String?,
    ) -> QRCodeScanOutcome {
        AssertIsOnMainThread()

        guard let qrCodeString else {
            // Only accept QR codes with a valid string payload.
            return .continueScanning
        }

        guard let url = DeviceProvisioningURL(urlString: qrCodeString), url.linkType == .linkDevice else {
            Logger.warn("couldn't parse device provisioning url from QR code")

            let title = NSLocalizedString("LINK_DEVICE_INVALID_CODE_TITLE", comment: "report an invalid linking code")
            let body = NSLocalizedString("LINK_DEVICE_INVALID_CODE_BODY", comment: "report an invalid linking code")

            let actionSheet = ActionSheetController(title: title, message: body)
            actionSheet.addAction(ActionSheetAction(
                title: CommonStrings.cancelButton,
                style: .cancel,
                handler: { _ in
                    DispatchQueue.main.async {
                        self.popToLinkedDeviceList()
                    }
                },
            ))
            actionSheet.addAction(ActionSheetAction(
                title: NSLocalizedString("LINK_DEVICE_RESTART", comment: "attempt another linking"),
                style: .default,
                handler: { _ in
                    self.qrCodeScanViewController.tryToStartScanning()
                },
            ))
            safePresent(actionSheet)

            return .stopScanning
        }

        confirmProvisioning(deviceProvisioningUrl: url)

        return .stopScanning
    }

    func qrCodeScanViewDismiss(_ qrCodeScanViewController: SignalUI.QRCodeScanViewController) {
        AssertIsOnMainThread()
        popToLinkedDeviceList()
    }
}

// MARK: - Tellomi（#1219）

extension LinkDeviceViewController {
    /// `PUT /v1/provisioning/{address}` 回 404：服务端上这个关联地址当时没有设备在等。
    /// 码过期了，或者是别的服务器的码——Signal Desktop 的码连的是 Signal 的服务器，在我们的服务器上永远是 404。
    /// 服务端分不出这两种，所以是同一型。上游显示的是「服务返回无效响应」加「重试」。
    static func tellomiIsExpiredOrForeignCode(_ error: Error) -> Bool {
        error.httpStatusCode == 404
    }

    /// 不点名别的 App（taishi 中转包 8：界面上出不出现「Signal」是品牌决定，先不点名）。
    static func tellomiExpiredOrForeignCodeMessage() -> String {
        OWSLocalizedString(
            "LINK_DEVICE_INVALID_CODE_TELLOMI_EXPIRED_OR_FOREIGN_BODY",
            comment: "Tellomi (#1219): the server has no device waiting at the scanned code (HTTP 404): the code expired, or it isn't a Tellomi code. Doesn't name the other app.",
        )
    }

    /// 连不上服务器、超时、服务器出错（5xx）说清楚是网络或服务器的问题，和 Android 同一句；其余照上游。
    static func tellomiFailureMessage(for error: Error) -> String {
        if error.isNetworkFailureOrTimeout || error.is5xxServiceResponse {
            return OWSLocalizedString(
                "LINKING_DEVICE_FAILED_TELLOMI_NETWORK_BODY",
                comment: "Tellomi (#1219): linking failed because the server could not be reached or returned a server error",
            )
        }
        return error.userErrorDescription
    }
}
