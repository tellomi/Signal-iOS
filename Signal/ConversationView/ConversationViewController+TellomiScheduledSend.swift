//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

/// Tellomi（tellomi/tellomi#1519 M-4）：会话输入框里写的字，长按发送键定时发送。
///
/// 照 Telegram 两端（只读，代码是自己写的）：长按发送键 → 发送键左边是「发出去是什么样」的文字气泡，下面一个菜单
/// （iOS `ChatSendMessageContextScreen` 的 `MessageItemView`，安卓 `MessageSendPreview`），里面「定时发送」，
/// 收藏里是「设置提醒」→ 选时间 → 排好，打开这个会话的定时消息。改消息时没有（TG 安卓 `editingMessageObject == null`）。
/// 「静音发送」「对方上线时发送」不做（spec D4）。
extension ConversationViewController {

    func tellomiPresentTextSendPreview(from button: UIButton) {
        guard
            hasViewWillAppearEverBegun,
            let inputToolbar,
            inputToolbar.editTarget == nil,
            inputToolbar.canSendTextMessage,
            let messageBody = inputToolbar.messageBodyForSending,
            !messageBody.text.isEmpty
        else {
            return
        }
        let text = SSKEnvironment.shared.databaseStorageRef.read { tx in
            messageBody.hydrating(mentionHydrator: ContactsMentionHydrator.mentionHydrator(transaction: tx)).asPlaintext()
        }
        let schedule = TellomiSendPreviewViewController.Action(
            title: TellomiScheduleTimeSheet.title(isReminder: thread.isNoteToSelf),
            image: UIImage(systemName: "calendar.badge.clock"),
            keepsPresented: false,
        ) { [weak self] in
            self?.tellomiPresentTextScheduleSheet()
        }
        let preview = TellomiSendPreviewViewController(
            tiles: [],
            caption: text,
            captionAboveMedia: false,
            bubbleColor: viewState.conversationStyle.bubbleChatColorOutgoing,
            actions: [schedule],
            sourceButton: button,
            onSend: { [weak self] in self?.sendButtonPressed() },
        )
        present(preview, animated: false)
    }

    private func tellomiPresentTextScheduleSheet() {
        let sheet = TellomiScheduleTimeSheet(isReminder: thread.isNoteToSelf) { [weak self] date in
            Task { await self?.tellomiScheduleTextMessage(at: date) }
        }
        sheet.present(from: self)
    }

    /// 同 `tryToSendTextMessage` 的前半段（拉黑先解除、安全码先确认），然后排成定时消息：输入框、引用、草稿照发送一样清掉，
    /// 打开定时消息（同 TG 两端）。到点才建消息、才分享资料（执行器做）。
    @MainActor
    func tellomiScheduleTextMessage(at date: Date) async {
        guard
            hasViewWillAppearEverBegun,
            let inputToolbar,
            inputToolbar.editTarget == nil,
            let messageBody = inputToolbar.messageBodyForSending,
            !messageBody.text.isEmpty
        else {
            return
        }
        if isBlockedConversation() {
            let isBlocked = await showUnblockConversationUI()
            guard !isBlocked else { return }
        }
        let identityIsConfirmed = await showSafetyNumberConfirmationIfNecessary(
            from: self,
            confirmationText: SafetyNumberStrings.confirmSendButton,
            untrustedThreshold: Date().addingTimeInterval(-OWSIdentityManagerImpl.Constants.defaultUntrustedInterval),
        )
        guard identityIsConfirmed else { return }

        do {
            try await TellomiScheduledMessageSender.shared.schedule(
                body: messageBody,
                attachments: [],
                isViewOnce: false,
                thread: thread,
                quotedReplyDraft: inputToolbar.quotedReplyDraft,
                linkPreviewDraft: inputToolbar.linkPreviewDraft,
                captionAboveMedia: false,
                at: date,
            )
        } catch TellomiScheduledMessageSender.ScheduleError.tooManyScheduled {
            OWSActionSheets.showActionSheet(message: TellomiScheduledMessageSender.ScheduleError.tooManyScheduled.localizedDescription)
            return
        } catch {
            Logger.warn("Couldn't schedule a text message: \(error)")
            OWSActionSheets.showErrorAlert(message: CommonStrings.somethingWentWrongError)
            return
        }

        inputToolbar.quotedReplyDraft = nil
        inputToolbar.clearTextMessage(animated: true)
        let thread = self.thread
        SSKEnvironment.shared.databaseStorageRef.asyncWrite { tx in
            guard let thread = TSThread.fetchViaCache(uniqueId: thread.uniqueId, transaction: tx) else { return }
            thread.updateWithDraft(draftMessageBody: nil, replyInfo: nil, editTargetTimestamp: nil, transaction: tx)
        }
        tellomiOpenScheduledMessages()
    }
}
