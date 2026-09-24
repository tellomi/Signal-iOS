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
    /// `tell.cc/g#…`、旧 `signal.group/#…`；存的是换算后的旧形状
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
        case .deviceLink(let text):
            guard let provisioningUrl = DeviceProvisioningURL(urlString: text) else {
                owsFailDebug("Device link no longer parses")
                return .continueScanning
            }
            handleTellomiDeviceLinkCode(provisioningUrl)
        case .quickRestore(let text):
            guard let provisioningUrl = DeviceProvisioningURL(urlString: text) else {
                owsFailDebug("Quick restore code no longer parses")
                return .continueScanning
            }
            handleTellomiQuickRestoreCode(provisioningUrl)
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

    /// 设备链接码：主设备上直接进「已关联的设备 → 链接新设备」流程——同样先过本机身份校验，再到和扫码后同一个确认框，
    /// 不用再扫一遍（需求 §3.2；做法取自 Pro 另一个会话的参考分支 `mbp/947-direct-link-reference` a6d7416）。
    /// 不是主设备就说清要在主手机上扫。
    func handleTellomiDeviceLinkCode(_ provisioningUrl: DeviceProvisioningURL) {
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

        dismissToRootThen {
            SignalApp.shared.showAppSettings(mode: .linkNewDevice(provisioningUrl))
        }
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

                _ = self.qrCodeScanViewScanned(
                    qrCodeData: nil,
                    qrCodeString: qrCodeMessageString,
                )
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
