//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Photos
import PhotosUI
import PureLayout
import SignalServiceKit
import SignalUI

protocol UsernameLinkScanDelegate: AnyObject {
    func usernameLinkScanned(_ usernameLink: Usernames.UsernameLink)
    /// Tellomi（tellomi/tellomi#947）：扫到 `tell.cc/<用户名>`、`tell.cc/u#u/<用户名>`；`username` 已是能直接去查的全名。
    func plainUsernameScanned(_ username: String)
}

/// Tellomi（tellomi/tellomi#947，需求 `share-qr-and-invite.md` §3.2「扫一扫统一」）：一个扫码器认所有 Tellomi 的码。
/// 上游只认 `signal.me/#eu/…`，别的一律静默忽略——Desktop 的 `tell.cc/u#eu` 码、裸 `tell.cc/<用户名>` 码扫了没有任何反应。
enum TellomiScannedCode: Equatable {
    /// `tell.cc/u#eu/…`、旧 `signal.me/#eu/…`（`Usernames.UsernameLink` 已认 tell.cc）
    case usernameLink(Usernames.UsernameLink)
    /// `tell.cc/<用户名>`、`tell.cc/u#u/<用户名>`
    case plainUsername(String)
    /// `tell.cc/g#…`、旧 `signal.group/#…`；存扫到的原链接（`PossibleGroupInviteLinkUrl.rawValue`）
    case groupInvite(URL)
    /// 设备链接码（`tellomi://linkdevice`、旧 `sgnl://linkdevice`）；存扫到的原文，处理时再解析
    case deviceLink(String)
    /// 快速恢复码（`tellomi://rereg`、旧 `sgnl://rereg`，新手机上显示的那个）
    case quickRestore(String)
    /// 其它网址 / 文字：显示内容 +「打开」/「复制」，不再静默忽略
    case other(String)

    init(scannedString: String) {
        let trimmed = scannedString.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed) {
            if let username = TellomiLinks.plainUsername(in: url) {
                self = .plainUsername(username)
                return
            }
            if let usernameLink = Usernames.UsernameLink(usernameLinkUrl: url) {
                self = .usernameLink(usernameLink)
                return
            }
            if let groupInvite = PossibleGroupInviteLinkUrl.parseFrom(url) {
                self = .groupInvite(groupInvite.rawValue)
                return
            }
            if let provisioningUrl = DeviceProvisioningURL(urlString: trimmed) {
                switch provisioningUrl.linkType {
                case .linkDevice:
                    self = .deviceLink(trimmed)
                case .quickRestore:
                    self = .quickRestore(trimmed)
                }
                return
            }
        }
        self = .other(trimmed)
    }
}

class UsernameLinkScanQRCodeViewController: OWSViewController, OWSNavigationChildController {
    var preferredNavigationBarStyle: OWSNavigationBarStyle { .blur }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        .portrait
    }

    weak var scanDelegate: UsernameLinkScanDelegate?

    init(scanDelegate: UsernameLinkScanDelegate) {
        self.scanDelegate = scanDelegate

        super.init()
    }

    private var context: ViewControllerContext { .shared }

    // MARK: - Views

    private lazy var scanViewController = {
        let scanViewController = QRCodeScanViewController(
            appearance: .framed,
            showUploadPhotoButton: true,
        )

        scanViewController.delegate = self

        return scanViewController
    }()

    private lazy var instructionsLabel: UILabel = {
        let label = UILabel()

        label.numberOfLines = 0
        label.textAlignment = .center
        label.lineBreakMode = .byWordWrapping
        label.text = OWSLocalizedString(
            "USERNAME_LINK_SCAN_QR_CODE_INSTRUCTIONS_LABEL",
            comment: "Text providing instructions on how to use the username link QR code scanning.",
        )

        // Always use dark theme since it sits over the scan mask.
        label.textColor = .white

        return label
    }()

    // MARK: - Lifecycle

    var navbarBackgroundColorOverride: UIColor? {
        return OWSTableViewController2.tableBackgroundColor(
            isUsingPresentedStyle: true,
        )
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        addChild(scanViewController)

        let instructionsWrapperView: UIView = {
            let wrapper = UIView()
            wrapper.layoutMargins = UIEdgeInsets(hMargin: 16, vMargin: 20)

            wrapper.addSubview(instructionsLabel)
            instructionsLabel.autoPinEdgesToSuperviewMargins()

            return wrapper
        }()

        view.addSubview(scanViewController.view)
        view.addSubview(instructionsWrapperView)

        scanViewController.view.autoPinEdgesToSuperviewEdges()
        instructionsWrapperView.autoPinEdges(toSuperviewSafeAreaExcludingEdge: .bottom)

        themeDidChange()
        contentSizeCategoryDidChange()
    }

    override func contentSizeCategoryDidChange() {
        instructionsLabel.font = .dynamicTypeSubheadline
    }

    // MARK: Actions
}

// MARK: - Scan delegate

extension UsernameLinkScanQRCodeViewController: QRCodeScanDelegate {
    var shouldShowUploadPhotoButton: Bool { true }

    func didTapUploadPhotoButton(_ qrCodeScanViewController: QRCodeScanViewController) {
        var config = PHPickerConfiguration()
        config.filter = .images
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        self.present(picker, animated: true)
    }

    func qrCodeScanViewScanned(
        qrCodeData: Data?,
        qrCodeString: String?,
    ) -> QRCodeScanOutcome {
        guard let qrCodeString else {
            UsernameLogger.shared.error("Unexpectedly missing QR code string!")
            return .continueScanning
        }

        return handleTellomiScannedString(qrCodeString, source: .camera)
    }

    /// 码从哪来：相机现场扫的，还是相册里的一张图（相册来源对设备码 / 恢复码要多一道提醒，见下）。
    enum TellomiScanSource {
        case camera
        case photoLibrary
    }

    func handleTellomiScannedString(_ qrCodeString: String, source: TellomiScanSource) -> QRCodeScanOutcome {
        guard let scanDelegate else {
            UsernameLogger.shared.error("Missing scan delegate!")
            return .continueScanning
        }

        // Tellomi（tellomi/tellomi#947）：认全 Tellomi 的码；别的内容也给出反应，不再静默忽略
        switch TellomiScannedCode(scannedString: qrCodeString) {
        case .usernameLink(let usernameLink):
            scanDelegate.usernameLinkScanned(usernameLink)
        case .plainUsername(let username):
            scanDelegate.plainUsernameScanned(username)
        case .groupInvite(let url):
            guard let groupInviteLink = PossibleGroupInviteLinkUrl.parseFrom(url) else {
                owsFailDebug("Group invite link no longer parses")
                return .continueScanning
            }
            GroupInviteLinksUI.openGroupInviteLink(groupInviteLink, fromViewController: self)
        case .deviceLink:
            presentTellomiDeviceLinkPrompt()
        case .quickRestore(let text):
            guard let provisioningUrl = DeviceProvisioningURL(urlString: text) else {
                owsFailDebug("Quick restore code no longer parses")
                return .continueScanning
            }
            switch source {
            case .camera:
                handleTellomiQuickRestoreCode(provisioningUrl)
            case .photoLibrary:
                presentTellomiQuickRestoreFromPhotoWarning()
            }
        case .other(let text):
            presentTellomiScannedContent(text)
        }
        return .stopScanning
    }

    func qrCodeScanViewDismiss(
        _ qrCodeScanViewController: QRCodeScanViewController,
    ) {
        dismiss(animated: true)
    }
}

// MARK: - Tellomi（tellomi/tellomi#947）

private extension UsernameLinkScanQRCodeViewController {
    /// 关掉扫码器（以及它所在的整叠弹出页），再做下一步。
    func dismissToRootThen(_ then: @escaping () -> Void) {
        guard let rootViewController = view.window?.rootViewController else {
            owsFailDebug("Missing root view controller")
            return
        }
        if rootViewController.presentedViewController != nil {
            rootViewController.dismiss(animated: true, completion: then)
        } else {
            then()
        }
    }

    /// 设备链接码：只指路——说清要到「已关联的设备 → 链接新设备」里现场再扫一次，不直达确认（taishi 审查 2026-09-24）。
    /// 上游有意设这道门槛：扫码入口以外的设备码只指路，防的是把配对码伪装成群邀请让人扫的钓鱼；
    /// 这个扫码器正是用户扫群码的地方，还能从相册选图。与 Android #33、上游应用内相机一致。
    /// 不是主设备就说清要在主手机上扫。
    func presentTellomiDeviceLinkPrompt() {
        let registeredState = try? DependenciesBridge.shared.tsAccountManager.registeredStateWithMaybeSneakyTransaction()
        guard registeredState?.isPrimary == true else {
            let actionSheet = ActionSheetController(message: OWSLocalizedString(
                "USERNAME_LINK_SCAN_DEVICE_LINK_NOT_PRIMARY_TELLOMI",
                comment: "Tellomi: shown when a device-linking QR code is scanned on a device that is not the primary phone.",
            ))
            actionSheet.addAction(ActionSheetAction(title: CommonStrings.okButton) { [weak self] _ in
                self?.scanViewController.tryToStartScanning()
            })
            presentActionSheet(actionSheet)
            return
        }

        let actionSheet = ActionSheetController(message: OWSLocalizedString(
            "LINKED_DEVICE_URL_OPENED_ACTION_SHEET_IN_APP_CAMERA_MESSAGE",
            comment: "Message for an action sheet telling users how to link a device, when trying to open a device-linking URL from the in-app camera.",
        ))
        actionSheet.addAction(ActionSheetAction(title: CommonStrings.continueButton) { [weak self] _ in
            // 收起整叠弹出页再开「已关联设备」：扫码页常压在设置页 / 新建聊天页上，只关自己的话，
            // 接着的 showAppSettings 会被 UIKit 静默拒掉（聊天列表还弹着别的页），用户停在原处（taishi 审查包 5）
            self?.dismissToRootThen {
                SignalApp.shared.showAppSettings(mode: .linkedDevices)
            }
        })
        actionSheet.addAction(ActionSheetAction(title: CommonStrings.cancelButton) { [weak self] _ in
            self?.scanViewController.tryToStartScanning()
        })
        presentActionSheet(actionSheet)
    }

    /// 快速恢复码：与应用内相机扫到时同一个处理（`outgoingDeviceRestorePresenter`）。
    func handleTellomiQuickRestoreCode(_ provisioningUrl: DeviceProvisioningURL) {
        dismissToRootThen {
            guard let frontmostViewController = CurrentAppContext().frontmostViewController() else {
                owsFailDebug("Missing frontmost view controller")
                return
            }
            AppEnvironment.shared.outgoingDeviceRestorePresenter.present(
                provisioningURL: provisioningUrl,
                presentingViewController: frontmostViewController,
                animated: true,
            )
        }
    }

    /// 相册里的快速恢复码：不直接弹「转移帐户」页，照上游对外部链接的做法（`UrlOpener` 的 `.quickRestore`）——
    /// 先提醒只扫 Tellomi 直接显示的码，再打开 Tellomi 相机现场扫（taishi 审查 2026-09-24）。
    func presentTellomiQuickRestoreFromPhotoWarning() {
        let actionSheet = ActionSheetController(message: OWSLocalizedString(
            "QUICK_RESTORE_URL_OPENED_ACTION_SHEET_EXTERNAL_URL_MESSAGE",
            comment: "Message for an action sheet telling users how to use quick restore, when trying to open an external quick restore URL.",
        ))
        actionSheet.addAction(ActionSheetAction(title: CommonStrings.continueButton) { [weak self] _ in
            self?.dismissToRootThen {
                SignalApp.shared.showCameraCaptureView { navController in
                    let sheet = HeroSheetViewController(
                        hero: .image(UIImage(named: "phone-qr")!),
                        title: OWSLocalizedString(
                            "QUICK_RESTORE_URL_OPENED_ACTION_SHEET_EXTERNAL_URL_ACTION_TITLE",
                            comment: "Title for sheet with info about scanning a Quick Restore QR code",
                        ),
                        body: OWSLocalizedString(
                            "QUICK_RESTORE_URL_OPENED_ACTION_SHEET_EXTERNAL_URL_ACTION_BODY",
                            comment: "Body for sheet with info about scanning a Quick Restore QR code",
                        ),
                        primaryButton: .dismissing(title: CommonStrings.okButton),
                    )
                    navController.topViewController?.present(sheet, animated: true)
                }
            }
        })
        actionSheet.addAction(ActionSheetAction(title: CommonStrings.cancelButton) { [weak self] _ in
            self?.scanViewController.tryToStartScanning()
        })
        presentActionSheet(actionSheet)
    }

    /// 其它网址 / 文字：显示内容，网址可以「打开」，都可以「复制」；取消后接着扫。
    func presentTellomiScannedContent(_ text: String) {
        let displayText = text.count > 500 ? String(text.prefix(500)) + "…" : text
        let actionSheet = ActionSheetController(
            title: OWSLocalizedString(
                "USERNAME_LINK_SCAN_RESULT_TITLE_TELLOMI",
                comment: "Tellomi: title of the sheet showing the content of a scanned QR code that is not a Tellomi code.",
            ),
            message: displayText,
        )
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" {
            actionSheet.addAction(ActionSheetAction(title: OWSLocalizedString(
                "MESSAGE_ACTION_LINK_OPEN_LINK",
                comment: "Action sheet button title",
            )) { [weak self] _ in
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
                self?.scanViewController.tryToStartScanning()
            })
        }
        actionSheet.addAction(ActionSheetAction(title: CommonStrings.copyButton) { [weak self] _ in
            UIPasteboard.general.string = text
            self?.presentToast(text: OWSLocalizedString("COPIED_TO_CLIPBOARD", comment: "Indicator that a value has been copied to the clipboard."))
            self?.scanViewController.tryToStartScanning()
        })
        actionSheet.addAction(ActionSheetAction(title: CommonStrings.cancelButton) { [weak self] _ in
            self?.scanViewController.tryToStartScanning()
        })
        presentActionSheet(actionSheet)
    }
}

extension UsernameLinkScanQRCodeViewController: PHPickerViewControllerDelegate {
    private enum QRCodeImagePickerError: Error {
        case noAttachmentImage
        case ciDetectorError
        case noQRCodeFound
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        guard let selectedItem = results.first else {
            picker.dismiss(animated: true)
            return
        }

        let attachmentLimits = OutgoingAttachmentLimits.currentLimits()

        Task { @MainActor in
            async let dismiss: Void = { @MainActor () async -> Void in
                await withCheckedContinuation { continuation in
                    picker.dismiss(animated: true) {
                        continuation.resume()
                    }
                }
            }()

            do {
                let attachment = try await TypedItemProvider.buildVisualMediaAttachment(
                    forItemProvider: selectedItem.itemProvider,
                    attachmentLimits: attachmentLimits,
                )
                guard
                    let image = attachment.rawValue.image(),
                    let ciImage = CIImage(image: image)
                else {
                    throw QRCodeImagePickerError.noAttachmentImage
                }

                guard
                    let qrCodeDetector = CIDetector(
                        ofType: CIDetectorTypeQRCode,
                        context: nil,
                        options: [CIDetectorAccuracy: CIDetectorAccuracyHigh],
                    )
                else {
                    throw QRCodeImagePickerError.ciDetectorError
                }

                let detectedFeatures = qrCodeDetector.features(in: ciImage)

                guard
                    detectedFeatures.count == 1,
                    let qrCodeFeature = detectedFeatures.first as? CIQRCodeFeature,
                    let qrCodeMessageString = qrCodeFeature.messageString
                else {
                    throw QRCodeImagePickerError.noQRCodeFound
                }

                _ = await dismiss

                _ = self.handleTellomiScannedString(qrCodeMessageString, source: .photoLibrary)
            } catch {
                UsernameLogger.shared.error("Error building attachment for QC code scan: \(error)")
                _ = await dismiss
                OWSActionSheets.showErrorAlert(
                    message: CommonStrings.somethingWentWrongError,
                    fromViewController: self,
                )
            }
        }
    }
}
