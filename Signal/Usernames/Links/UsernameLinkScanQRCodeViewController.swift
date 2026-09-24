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
}

/// Tellomi（tellomi/tellomi#947）：「扫一扫」统一——头像旁的扫码器认所有 Tellomi 的码
/// （需求 `docs/product/specs/share-qr-and-invite.md` 第 3.2 节）。上游这个扫码器只认加密用户名链接，
/// 扫到 Desktop 的关联码、群邀请、明文用户名都静默忽略，owner 以为坏了。
///
/// 链接类的码和点链接走同一个 `UrlOpener`（Telegram 的扫码页也是把扫到的内容交给全局链接解析：
/// `QrCodeUI/Sources/QrCodeScanScreen.swift` 的 `resolveCode` → `openResolvedUrl`）。
enum TellomiScannedCode {
    /// `tell.cc/u#eu/…`、旧的 `signal.me/#eu/…`：交给原来的 `UsernameLinkScanDelegate`。
    case usernameLink(Usernames.UsernameLink)
    /// `tellomi://linkdevice`、旧的 `sgnl://linkdevice`。
    case linkDevice(DeviceProvisioningURL)
    /// `tellomi://rereg`、旧的 `sgnl://rereg`（新手机快速恢复）。
    case quickRestore(DeviceProvisioningURL)
    /// 明文用户名、群邀请、通话链接等其它 `UrlOpener` 认得的链接。
    case openableUrl(UrlOpener.ParsedUrl)
    /// 其它网址或文字：显示出来，给「打开」「复制」，不再静默忽略。
    case other(String)

    static func classify(_ scannedString: String) -> TellomiScannedCode {
        let trimmed = scannedString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil else {
            return .other(trimmed)
        }
        let legacyUrl = TellomiLinks.legacyEquivalent(of: url)
        if let usernameLink = Usernames.UsernameLink(usernameLinkUrl: legacyUrl) {
            return .usernameLink(usernameLink)
        }
        if let provisioningUrl = DeviceProvisioningURL(urlString: legacyUrl.absoluteString) {
            switch provisioningUrl.linkType {
            case .linkDevice: return .linkDevice(provisioningUrl)
            case .quickRestore: return .quickRestore(provisioningUrl)
            }
        }
        if let parsedUrl = UrlOpener.parseUrl(url, reportUnrecognized: false) {
            return .openableUrl(parsedUrl)
        }
        return .other(trimmed)
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

        switch TellomiScannedCode.classify(qrCodeString) {
        case .usernameLink(let scannedUsernameLink):
            guard let scanDelegate else {
                UsernameLogger.shared.error("Missing scan delegate!")
                return .continueScanning
            }
            scanDelegate.usernameLinkScanned(scannedUsernameLink)
        case .linkDevice(let provisioningUrl):
            handleScannedLinkDeviceCode(provisioningUrl)
        case .quickRestore(let provisioningUrl):
            handleScannedQuickRestoreCode(provisioningUrl)
        case .openableUrl(let parsedUrl):
            openScannedUrl(parsedUrl)
        case .other(let text):
            showScannedText(text)
        }
        return .stopScanning
    }

    func qrCodeScanViewDismiss(
        _ qrCodeScanViewController: QRCodeScanViewController,
    ) {
        dismiss(animated: true)
    }
}

// MARK: - Tellomi（tellomi/tellomi#947）：扫到其它种类的码

extension UsernameLinkScanQRCodeViewController {
    /// 把整摞弹出的页面收起来，再执行 `then`（扫码器本身在设置页的弹窗里）。
    private func dismissToRoot(then: @escaping () -> Void) {
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

    private func handleScannedLinkDeviceCode(_ provisioningUrl: DeviceProvisioningURL) {
        let registeredState = try? DependenciesBridge.shared.tsAccountManager.registeredStateWithMaybeSneakyTransaction()
        guard registeredState?.isPrimary == true else {
            let actionSheet = ActionSheetController(message: OWSLocalizedString(
                "TELLOMI_SCAN_LINK_DEVICE_NOT_PRIMARY",
                comment: "Shown when a device-linking QR code is scanned on a device that is not the primary device.",
            ))
            actionSheet.addAction(ActionSheetAction(title: CommonStrings.okButton) { [weak self] _ in
                self?.scanViewController.tryToStartScanning()
            })
            presentActionSheet(actionSheet)
            return
        }
        // 走「已关联的设备」页：和点「链接新设备」同一个本机身份校验和确认流程，只是不用再扫一遍。
        dismissToRoot {
            SignalApp.shared.showAppSettings(mode: .linkNewDevice(provisioningUrl))
        }
    }

    private func handleScannedQuickRestoreCode(_ provisioningUrl: DeviceProvisioningURL) {
        // 和聊天里的相机扫到快速恢复码时一样（PhotoCaptureViewController）。
        dismissToRoot {
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

    private func openScannedUrl(_ parsedUrl: UrlOpener.ParsedUrl) {
        guard let window = view.window else {
            owsFailDebug("Missing window")
            return
        }
        // 和点链接完全一样（AppDelegate.handleOpenUrl）；UrlOpener 自己会先收起弹出的页面。
        let urlOpener = UrlOpener(
            databaseStorage: SSKEnvironment.shared.databaseStorageRef,
            donationSubscriptionManager: DependenciesBridge.shared.donationSubscriptionManager,
            idealStore: DependenciesBridge.shared.pendingIDEALDonationStore,
            profileBadgeManager: DependenciesBridge.shared.profileBadgeManager,
            tsAccountManager: DependenciesBridge.shared.tsAccountManager,
        )
        urlOpener.openUrl(parsedUrl, in: window)
    }

    private func showScannedText(_ text: String) {
        let actionSheet = ActionSheetController(
            title: OWSLocalizedString(
                "TELLOMI_SCAN_OTHER_CONTENT_TITLE",
                comment: "Title of the sheet shown when a scanned QR code is not a Tellomi link; its text is shown below.",
            ),
            message: text,
        )
        if let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased()) {
            actionSheet.addAction(ActionSheetAction(title: OWSLocalizedString(
                "TELLOMI_SCAN_OPEN_LINK",
                comment: "Button to open a web link found in a scanned QR code in the browser.",
            )) { [weak self] _ in
                UIApplication.shared.open(url)
                self?.scanViewController.tryToStartScanning()
            })
        }
        actionSheet.addAction(ActionSheetAction(title: CommonStrings.copyButton) { [weak self] _ in
            UIPasteboard.general.string = text
            self?.presentToast(text: CommonStrings.copiedToClipboardToast)
            self?.scanViewController.tryToStartScanning()
        })
        actionSheet.addAction(ActionSheetAction(title: CommonStrings.cancelButton, style: .cancel) { [weak self] _ in
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
