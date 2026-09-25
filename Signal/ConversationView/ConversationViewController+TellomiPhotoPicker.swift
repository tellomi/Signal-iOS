//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Photos
import SignalServiceKit
import SignalUI

/// Tellomi（tellomi/tellomi#1261）：会话「+ → 照片」打开 Telegram 式的选图网格（`TellomiPhotoPickerViewController`）。
extension ConversationViewController {

    /// 读相册要「照片」权限（上游的系统选择器不要）：没给过就先问；已经拒绝 / 受限制就照旧弹系统选择器，权限引导以 #1115 为准。
    func chooseFromLibraryWithTellomiPicker(fallback: @escaping () -> Void) {
        AssertIsOnMainThread()

        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .denied, .restricted:
            fallback()
        default:
            Task { @MainActor in
                guard await self.ows_askForMediaLibraryPermissions(for: .readWrite) else { return }
                self.presentTellomiPhotoPicker()
            }
        }
    }

    private func presentTellomiPhotoPicker() {
        guard hasViewWillAppearEverBegun, let inputToolbar else { return }

        let picker = TellomiPhotoPickerViewController(
            library: TellomiSystemPhotoLibrary(),
            initialMessageBody: inputToolbar.messageBodyForSending,
            defaultImageQuality: SSKEnvironment.shared.databaseStorageRef.read(block: ImageQuality.fetchValue(tx:)),
            canSendSeparately: true,
            hasQuotedReplyDraft: inputToolbar.quotedReplyDraft != nil,
            attachmentLimits: .currentLimits(),
            approvalDataSource: self,
            stickerSheetDelegate: self,
            // 「只看已选」（P-3）铺会话的聊天背景、说明气泡用会话的颜色。
            chatBackground: viewState.wallpaperViewBuilder?.build().asPreviewView(),
            bubbleColor: viewState.conversationStyle.bubbleChatColorOutgoing,
            camera: TellomiSystemPickerCamera(),
        )
        picker.delegate = self

        dismissKeyBoard()
        let presenter = splitViewController ?? self
        presenter.present(picker, animated: true)
    }
}

extension ConversationViewController: TellomiPhotoPickerDelegate {

    func photoPickerDidCancel(_ picker: TellomiPhotoPickerViewController) {
        // 同上游 sendMediaNavDidCancel：回到附件面板。
        dismiss(animated: true)
        openAttachmentKeyboard()
    }

    /// 相机格：走上游「+ → 相机」同一条路（自己问相机 / 麦克风权限，拍完在它自己的预览页里发），但盖在选图面板上面——
    /// 同 Telegram（`ChatControllerOpenAttachmentMenu.openCamera` 把相机叠在附件菜单上）：取消只关相机、回到面板，已选都还在；
    /// 在相机里发了照常发，发完会话页整个收起（面板里的已选不发，同 Telegram）。
    func photoPickerDidRequestCamera(_ picker: TellomiPhotoPickerViewController) {
        let route = TellomiPickerCameraRoute(picker: picker, conversation: self)
        picker.cameraRoute = route
        tellomiTakePictureOrVideo(presenter: picker, sendMediaNavDelegate: route)
    }

    func photoPicker(
        _ picker: TellomiPhotoPickerViewController,
        send approvedAttachments: ApprovedAttachments,
        messageBody: MessageBody?,
        separately: Bool,
    ) {
        // 从上游预览页发的时候它盖在网格上面，提示与安全码确认都从最上面那一层弹。
        let fromViewController = picker.presentedViewController ?? picker
        let attachmentLimits = picker.attachmentLimits
        ModalActivityIndicatorViewController.present(
            fromViewController: fromViewController,
            title: CommonStrings.preparingModal,
            asyncBlock: { modal in
                if separately {
                    await TellomiPhotoPickerSending.sendSeparately(approvedAttachments, messageBody: messageBody) { part, body in
                        await self.sendAttachments(part, messageBody: body, from: fromViewController, attachmentLimits: attachmentLimits)
                    }
                } else {
                    await self.sendAttachments(approvedAttachments, messageBody: messageBody, from: fromViewController, attachmentLimits: attachmentLimits)
                }
                modal.dismiss(completion: {
                    self.dismiss(animated: true)
                })
            },
        )
    }

    func photoPicker(_ picker: TellomiPhotoPickerViewController, didChangeMessageBody messageBody: MessageBody?) {
        guard hasViewWillAppearEverBegun, let inputToolbar else { return }
        inputToolbar.setMessageBody(messageBody, animated: false)
    }
}

/// Tellomi（#1261 P-8）：从选图面板的相机格打开的相机，事件怎么走。
/// 取消只关相机这一层、回到面板（面板接着取景）；发送、改说明、一次性查看都照会话页自己打开相机时的路子走（发完由会话页整个收起）。
final class TellomiPickerCameraRoute: SendMediaNavDelegate {
    private weak var picker: TellomiPhotoPickerViewController?
    private weak var conversation: ConversationViewController?

    init(picker: TellomiPhotoPickerViewController, conversation: ConversationViewController?) {
        self.picker = picker
        self.conversation = conversation
    }

    /// 只关相机（它自己 dismiss），面板留着；关完面板接着取景。
    func closeCamera(_ camera: UIViewController) {
        camera.dismiss(animated: true) { [weak picker] in
            picker?.cameraDidClose()
        }
    }

    func sendMediaNavDidCancel(_ sendMediaNavigationController: SendMediaNavigationController) {
        closeCamera(sendMediaNavigationController)
    }

    func sendMediaNav(
        _ sendMediaNavigationController: SendMediaNavigationController,
        didApproveAttachments approvedAttachments: ApprovedAttachments,
        messageBody: MessageBody?,
    ) {
        conversation?.sendMediaNav(sendMediaNavigationController, didApproveAttachments: approvedAttachments, messageBody: messageBody)
    }

    func sendMediaNav(_ sendMediaNavigationController: SendMediaNavigationController, didFinishWithTextAttachment textAttachment: UnsentTextAttachment) {
        conversation?.sendMediaNav(sendMediaNavigationController, didFinishWithTextAttachment: textAttachment)
    }

    func sendMediaNav(_ sendMediaNavigationController: SendMediaNavigationController, didChangeMessageBody newMessageBody: MessageBody?) {
        conversation?.sendMediaNav(sendMediaNavigationController, didChangeMessageBody: newMessageBody)
        picker?.updateCaptionFromCamera(newMessageBody)
    }

    func sendMediaNav(_ sendMediaNavigationController: SendMediaNavigationController, didChangeViewOnceState isViewOnce: Bool) {
        conversation?.sendMediaNav(sendMediaNavigationController, didChangeViewOnceState: isViewOnce)
    }
}

/// Tellomi（#1261 P-5「单独发送」）：一张一条，说明（连同 @ 与样式）挂最后一条；上一条没发出去（被拦下 / 取消）就不再发后面的。
/// 引用只挂第一条：会话页每发出一条就清掉引用草稿（上游 `messageWasSent`）。
/// 时间戳不重复、落库顺序与勾的顺序一致：上游 `MessageTimestampGenerator` 连发时逐个 +1，`ThreadUtil.enqueueSendQueue` 串行。
enum TellomiPhotoPickerSending {
    @MainActor
    static func sendSeparately(
        _ approvedAttachments: ApprovedAttachments,
        messageBody: MessageBody?,
        send: (ApprovedAttachments, MessageBody?) async -> Bool,
    ) async {
        let attachments = approvedAttachments.attachments
        for (index, attachment) in attachments.enumerated() {
            let isLast = index == attachments.count - 1
            let part = ApprovedAttachments(nonViewOnceAttachments: [attachment], imageQuality: approvedAttachments.imageQuality)
            guard await send(part, isLast ? messageBody : nil) else {
                return
            }
        }
    }
}
