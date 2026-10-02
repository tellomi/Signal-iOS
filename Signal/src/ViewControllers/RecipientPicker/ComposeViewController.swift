//
// Copyright 2019 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

class ComposeViewController: RecipientPickerContainerViewController {

    override func viewDidLoad() {
        super.viewDidLoad()

        title = OWSLocalizedString("MESSAGE_COMPOSEVIEW_TITLE", comment: "Title for the compose view.")

        view.backgroundColor = Theme.backgroundColor

        recipientPicker.shouldShowInvites = true
        recipientPicker.shouldShowNewGroup = true
        recipientPicker.groupsToShow = .groupsThatUserIsMemberOfWhenSearching
        recipientPicker.shouldHideLocalRecipient = false
        recipientPicker.delegate = self

        addRecipientPicker()

        navigationItem.rightBarButtonItem = .cancelButton(dismissingFrom: self)
    }

    /// Presents the conversation for the given address and dismisses this
    /// controller such that the conversation is visible.
    func newConversation(address: SignalServiceAddress) {
        AssertIsOnMainThread()
        owsAssertDebug(address.isValid)

        let thread = SSKEnvironment.shared.databaseStorageRef.write { transaction in
            TSContactThread.getOrCreateThread(
                withContactAddress: address,
                transaction: transaction,
            )
        }
        self.newConversation(thread: thread)
    }

    /// Presents the conversation for the given thread and dismisses this
    /// controller such that the conversation is visible.
    func newConversation(thread: TSThread) {
        presentingViewController?.dismiss(animated: true)
        if let transitionCoordinator = presentingViewController?.transitionCoordinator {
            // When transitionCoordinator is present, coordinate the immediate presentation of
            // the conversationVC with the animated dismissal of the compose VC
            transitionCoordinator.animate { _ in
                UIView.performWithoutAnimation {
                    SignalApp.shared.presentConversationForThread(
                        threadUniqueId: thread.uniqueId,
                        action: .compose,
                        animated: false,
                    )
                }
            }
        } else {
            // There isn't a transition coordinator present for some reason, revert to displaying
            // the conversation VC in parallel with the animated dismissal of the compose VC
            SignalApp.shared.presentConversationForThread(
                threadUniqueId: thread.uniqueId,
                action: .compose,
                animated: false,
            )
        }
    }

    func showNewGroupUI() {
        navigationController?.pushViewController(NewGroupMembersViewController(), animated: true)
    }
}

extension ComposeViewController: RecipientPickerDelegate, UsernameLinkScanDelegate {

    func recipientPicker(
        _ recipientPickerViewController: RecipientPickerViewController,
        selectionStyleForRecipient recipient: PickedRecipient,
        transaction: DBReadTransaction,
    ) -> UITableViewCell.SelectionStyle {
        return .default
    }

    func recipientPicker(
        _ recipientPickerViewController: RecipientPickerViewController,
        didSelectRecipient recipient: PickedRecipient,
    ) {
        switch recipient.identifier {
        case .address(let address):
            newConversation(address: address)
        case .group(let groupThread):
            newConversation(thread: groupThread)
        }
    }

    func recipientPicker(
        _ recipientPickerViewController: RecipientPickerViewController,
        accessoryMessageForRecipient recipient: PickedRecipient,
        transaction: DBReadTransaction,
    ) -> String? {
        switch recipient.identifier {
        case .address:
            return nil
        case .group(let thread):
            guard SSKEnvironment.shared.blockingManagerRef.isThreadBlocked(thread, transaction: transaction) else { return nil }
            return MessageStrings.conversationIsBlocked
        }
    }

    func recipientPicker(
        _ recipientPickerViewController: RecipientPickerViewController,
        attributedSubtitleForRecipient recipient: PickedRecipient,
        transaction: DBReadTransaction,
    ) -> NSAttributedString? {
        switch recipient.identifier {
        case .address(let address):
            guard !address.isLocalAddress else {
                return nil
            }
            if let bioForDisplay = SSKEnvironment.shared.profileManagerRef.userProfile(for: address, tx: transaction)?.bioForDisplay {
                return NSAttributedString(string: bioForDisplay)
            }
            return nil
        case .group:
            return nil
        }
    }

    func recipientPickerNewGroupButtonWasPressed() {
        showNewGroupUI()
    }
}

// MARK: - Tellomi（tellomi/tellomi#1108）

/// 联系人一级 Tab：列表 = 已经建立联系的人（Signal connections：已注册，且是系统联系人或已互相共享资料），不列群、不列自己。
/// 顶部：按用户名查找（选人控件自带那一行，进去的页面里能扫码）· 扫描二维码 · 邀请好友；点一个人打开会话。
///
/// 不申请通讯录权限（#1108 判据：没有 CDSI 的构建里不出现通讯录权限弹窗）：没有 CDSI 时选人控件顶部的权限提醒 / 用途说明都不放；
/// 「邀请好友」用系统分享面板发下载链接（和 Android 的邀请页一样），不走上游 `InviteFlow`——那条路的短信 / 邮件都要先读通讯录。
class TellomiContactsViewController: RecipientPickerContainerViewController {

    /// 和上游邀请短信里的链接一样（`InviteFlow.installUrl`）。
    static let installUrl = "https://tellomi.app/download/"

    override func viewDidLoad() {
        super.viewDidLoad()

        title = HomeTabBarController.Tabs.contacts.title
        view.backgroundColor = Theme.backgroundColor

        Self.configure(recipientPicker)
        recipientPicker.tellomiExtraStaticItems = [
            OWSTableItem.disclosureItem(
                icon: .qrCode,
                withText: CommonStrings.scanQRCodeTitle,
                actionBlock: { [weak self] in
                    self?.presentUsernameQRCodeScanner()
                },
            ),
            OWSTableItem.disclosureItem(
                icon: .settingsInvite,
                withText: OWSLocalizedString("SETTINGS_INVITE_TITLE", comment: "Title for the 'invite contacts' view."),
                actionBlock: { [weak self] in
                    self?.shareInvite()
                },
            ),
        ]
        recipientPicker.delegate = self

        addRecipientPicker()
    }

    /// 只列个人，不列群、不列自己；没有「新建群组」；「没有联系人」那一页不放邀请按钮（它走要读通讯录的邀请流程）。
    static func configure(_ recipientPicker: RecipientPickerViewController) {
        recipientPicker.shouldShowInvites = false
        recipientPicker.shouldShowNewGroup = false
        recipientPicker.groupsToShow = .noGroups
        recipientPicker.shouldHideLocalRecipient = true
        recipientPicker.tellomiSkipsNoContactsView = true
        // 通讯录权限只在 CDSI 可用时、在联系人页说明用途后申请（#1108）；没有 CDSI 就一直不提
        recipientPicker.tellomiHidesContactAccessReminder = !TSConstants.cdsiAvailable
    }

    static func inviteText() -> String {
        return OWSLocalizedString("SMS_INVITE_BODY", comment: "body sent to contacts when inviting to Install Signal") + " " + installUrl
    }

    private func shareInvite() {
        let activityViewController = UIActivityViewController(activityItems: [Self.inviteText()], applicationActivities: nil)
        activityViewController.popoverPresentationController?.sourceView = view
        present(activityViewController, animated: true)
    }

    private func openConversation(address: SignalServiceAddress) {
        let thread = SSKEnvironment.shared.databaseStorageRef.write { transaction in
            TSContactThread.getOrCreateThread(withContactAddress: address, transaction: transaction)
        }
        Self.open(threadUniqueId: thread.uniqueId)
    }

    /// 在联系人 Tab 里打开会话，返回回到联系人（#1108，审计 A-41）。
    private static func open(threadUniqueId: String) {
        guard let splitViewController = SignalApp.shared.conversationSplitViewController else {
            SignalApp.shared.presentConversationForThread(threadUniqueId: threadUniqueId, action: .compose, animated: true)
            return
        }
        splitViewController.presentThreadFromContactsTab(threadUniqueId: threadUniqueId, animated: true)
    }
}

extension TellomiContactsViewController: RecipientPickerDelegate, UsernameLinkScanDelegate {

    func recipientPicker(
        _ recipientPickerViewController: RecipientPickerViewController,
        selectionStyleForRecipient recipient: PickedRecipient,
        transaction: DBReadTransaction,
    ) -> UITableViewCell.SelectionStyle {
        return .default
    }

    func recipientPicker(
        _ recipientPickerViewController: RecipientPickerViewController,
        didSelectRecipient recipient: PickedRecipient,
    ) {
        switch recipient.identifier {
        case .address(let address):
            openConversation(address: address)
        case .group(let groupThread):
            Self.open(threadUniqueId: groupThread.uniqueId)
        }
    }

    func recipientPickerNewGroupButtonWasPressed() {}
}
