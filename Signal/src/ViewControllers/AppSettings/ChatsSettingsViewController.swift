//
// Copyright 2021 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import IntentsUI
import SignalServiceKit
import SignalUI

class ChatsSettingsViewController: OWSTableViewController2 {

    override func viewDidLoad() {
        super.viewDidLoad()

        title = OWSLocalizedString("SETTINGS_CHATS", comment: "Title for the 'chats' link in settings.")

        updateTableContents()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateTableContents),
            name: .syncManagerConfigurationSyncDidComplete,
            object: nil,
        )
    }

    @objc
    private func updateTableContents() {
        let contents = OWSTableContents()

        let linkPreviewSection = OWSTableSection()
        // Tellomi（ADR-0063 §8.1 第 9 行、§九.3，tellomi/tellomi#1423）：说清发送链接时设备会访问该网站
        linkPreviewSection.footerTitle = OWSLocalizedString(
            "TELLOMI_SETTINGS_LINK_PREVIEWS_FOOTER",
            comment: "Footer for the setting that enables link previews. Says plainly that, when on, the device visits the website when the user sends a link.",
        )
        linkPreviewSection.add(.switch(
            withText: OWSLocalizedString(
                "SETTINGS_LINK_PREVIEWS",
                comment: "Setting for enabling & disabling link previews.",
            ),
            isOn: {
                SSKEnvironment.shared.databaseStorageRef.read { DependenciesBridge.shared.linkPreviewSettingStore.areLinkPreviewsEnabled(tx: $0) }
            },
            actionBlock: { [weak self] uiSwitch in
                self?.didToggleLinkPreviewsEnabled(uiSwitch)
            },
        ))
        contents.add(linkPreviewSection)
        contents.add(tellomiShortLinkSection())

        let sharingSuggestionsSection = OWSTableSection()
        sharingSuggestionsSection.footerTitle = OWSLocalizedString(
            "SETTINGS_SHARING_SUGGESTIONS_NOTIFICATIONS_FOOTER",
            comment: "Footer for setting for enabling & disabling contact and notification sharing with iOS.",
        )

        sharingSuggestionsSection.add(.switch(
            withText: OWSLocalizedString(
                "SETTINGS_SHARING_SUGGESTIONS",
                comment: "Setting for enabling & disabling iOS contact sharing.",
            ),
            isOn: {
                SSKEnvironment.shared.databaseStorageRef.read { SSKPreferences.areIntentDonationsEnabled(transaction: $0) }
            },
            actionBlock: { [weak self] uiSwitch in
                self?.didToggleSharingSuggestionsEnabled(uiSwitch)
            },
        ))
        contents.add(sharingSuggestionsSection)

        let contactSection = OWSTableSection()
        contactSection.footerTitle = OWSLocalizedString(
            "SETTINGS_APPEARANCE_AVATAR_FOOTER",
            comment: "Footer for avatar section in appearance settings",
        )
        contactSection.add(.switch(
            withText: OWSLocalizedString(
                "SETTINGS_APPEARANCE_AVATAR_PREFERENCE_LABEL",
                comment: "Title for switch to toggle preference between contact and profile avatars",
            ),
            isOn: {
                SSKEnvironment.shared.databaseStorageRef.read { SSKPreferences.preferContactAvatars(transaction: $0) }
            },
            actionBlock: { [weak self] uiSwitch in
                self?.didToggleAvatarPreference(uiSwitch)
            },
        ))
        contents.add(contactSection)

        let keepMutedChatsArchived = OWSTableSection()
        keepMutedChatsArchived.add(.switch(
            withText: OWSLocalizedString("SETTINGS_KEEP_MUTED_ARCHIVED_LABEL", comment: "When a chat is archived and receives a new message, it is unarchived. Turning this switch on disables this feature if the chat in question is also muted. This string is a brief label for a switch paired with a longer description underneath, in the Chats settings."),
            isOn: {
                SSKEnvironment.shared.databaseStorageRef.read { SSKPreferences.shouldKeepMutedChatsArchived(transaction: $0) }
            },
            actionBlock: { [weak self] uiSwitch in
                self?.didToggleShouldKeepMutedChatsArchivedSwitch(uiSwitch)
            },
        ))
        keepMutedChatsArchived.footerTitle = OWSLocalizedString(
            "SETTINGS_KEEP_MUTED_ARCHIVED_DESCRIPTION",
            comment: "When a chat is archived and receives a new message, it is unarchived. Turning this switch on disables this feature if the chat in question is also muted. This string is a thorough description paired with a labeled switch above, in the Chats settings.",
        )
        contents.add(keepMutedChatsArchived)

        let clearHistorySection = OWSTableSection()
        clearHistorySection.add(.item(
            name: OWSLocalizedString("SETTINGS_CLEAR_HISTORY", comment: ""),
            textColor: .Signal.red,
            accessibilityIdentifier: UIView.accessibilityIdentifier(in: self, name: "clear_chat_history"),
            actionBlock: { [weak self] in
                self?.didTapClearHistory()
            },
        ))
        contents.add(clearHistorySection)

        self.contents = contents
    }

    private func didToggleLinkPreviewsEnabled(_ sender: UISwitch) {
        Logger.info("toggled to: \(sender.isOn)")
        let db = DependenciesBridge.shared.db
        db.write { tx in
            let linkPreviewSettingManager = DependenciesBridge.shared.linkPreviewSettingManager
            linkPreviewSettingManager.setAreLinkPreviewsEnabled(sender.isOn, shouldSendSyncMessage: true, tx: tx)
        }
        // Tellomi：「展开短链接」跟着总开关变灰 / 变亮
        updateTableContents()
    }

    /// Tellomi（ADR-0063 §8.1 第 9 行、§九.4，owner 2026-09-27）：「展开短链接」，默认开、只存本机、不跨设备同步。
    /// 链接预览总开关关着的时候它不起作用，所以一起变灰。
    private func tellomiShortLinkSection() -> OWSTableSection {
        let section = OWSTableSection()
        section.footerTitle = OWSLocalizedString(
            "TELLOMI_SETTINGS_EXPAND_SHORT_LINKS_FOOTER",
            comment: "Footer for the 'Expand Short Links' setting: before making a preview, the device asks the short-link service for the original address; the service sees one visit; the setting is kept on this device only.",
        )
        section.add(.switch(
            withText: OWSLocalizedString(
                "TELLOMI_SETTINGS_EXPAND_SHORT_LINKS",
                comment: "Setting for enabling & disabling expanding short links (such as b23.tv) before generating a link preview.",
            ),
            accessibilityIdentifier: "tellomi_expand_short_links",
            isOn: {
                DependenciesBridge.shared.db.read { TellomiLinkPreviewLocalSettings.isShortLinkExpansionEnabled(tx: $0) }
            },
            isEnabled: {
                DependenciesBridge.shared.db.read { DependenciesBridge.shared.linkPreviewSettingStore.areLinkPreviewsEnabled(tx: $0) }
            },
            actionBlock: { uiSwitch in
                Logger.info("toggled expand short links to: \(uiSwitch.isOn)")
                DependenciesBridge.shared.db.write { tx in
                    TellomiLinkPreviewLocalSettings.setShortLinkExpansionEnabled(uiSwitch.isOn, tx: tx)
                }
            },
        ))
        return section
    }

    private func didToggleSharingSuggestionsEnabled(_ sender: UISwitch) {
        Logger.info("toggled to: \(sender.isOn)")

        if sender.isOn {
            SSKEnvironment.shared.databaseStorageRef.write { transaction in
                SSKPreferences.setAreIntentDonationsEnabled(true, transaction: transaction)
            }
        } else {
            INInteraction.deleteAll { error in
                if let error {
                    owsFailDebug("Failed to disable sharing suggestions \(error)")
                    sender.setOn(true, animated: true)
                    OWSActionSheets.showActionSheet(title: OWSLocalizedString(
                        "SHARING_SUGGESTIONS_DISABLE_ERROR",
                        comment: "Title of alert indicating sharing suggestions failed to deactivate",
                    ))
                } else {
                    SSKEnvironment.shared.databaseStorageRef.write { transaction in
                        SSKPreferences.setAreIntentDonationsEnabled(false, transaction: transaction)
                    }
                }
            }
        }
    }

    private func didToggleAvatarPreference(_ sender: UISwitch) {
        Logger.info("toggled to: \(sender.isOn)")
        let currentValue = SSKEnvironment.shared.databaseStorageRef.read { SSKPreferences.preferContactAvatars(transaction: $0) }
        guard currentValue != sender.isOn else { return }

        SSKEnvironment.shared.databaseStorageRef.write { SSKPreferences.setPreferContactAvatars(sender.isOn, transaction: $0) }
    }

    private func didToggleShouldKeepMutedChatsArchivedSwitch(_ sender: UISwitch) {
        Logger.info("toggled to \(sender.isOn)")
        let currentValue = SSKEnvironment.shared.databaseStorageRef.read { SSKPreferences.shouldKeepMutedChatsArchived(transaction: $0) }
        guard currentValue != sender.isOn else { return }

        SSKEnvironment.shared.databaseStorageRef.write { SSKPreferences.setShouldKeepMutedChatsArchived(sender.isOn, transaction: $0) }

        SSKEnvironment.shared.storageServiceManagerRef.recordPendingLocalAccountUpdates()
    }

    // MARK: -

    private func didTapClearHistory() {
        let primaryConfirmDeletionTitle = OWSLocalizedString(
            "SETTINGS_DELETE_HISTORYLOG_CONFIRMATION",
            comment: "Alert message before user confirms clearing history",
        )
        let secondaryConfirmDeletionTitle = OWSLocalizedString(
            "SETTINGS_DELETE_HISTORYLOG_CONFIRMATION_SECONDARY_TITLE",
            comment: "Secondary alert title before user confirms clearing history",
        )
        let secondaryConfirmDeletionMessage = OWSLocalizedString(
            "SETTINGS_DELETE_HISTORYLOG_CONFIRMATION_SECONDARY_MESSAGE",
            comment: "Secondary alert message before user confirms clearing history",
        )
        let confirmDeletionButtonTitle = OWSLocalizedString(
            "SETTINGS_DELETE_HISTORYLOG_CONFIRMATION_BUTTON",
            comment: "Confirmation text for button which deletes all message, calling, attachments, etc.",
        )

        // Show two layers of confirmation here – this is a maximally
        // destructive action.
        OWSActionSheets.showConfirmationAlert(
            title: primaryConfirmDeletionTitle,
            proceedTitle: confirmDeletionButtonTitle,
            proceedStyle: .destructive,
        ) { [weak self] _ in
            OWSActionSheets.showConfirmationAlert(
                title: secondaryConfirmDeletionTitle,
                message: secondaryConfirmDeletionMessage,
                proceedTitle: confirmDeletionButtonTitle,
                proceedStyle: .destructive,
            ) { [weak self] _ in
                self?.clearHistoryBehindSpinner()
            }
        }
    }

    private func clearHistoryBehindSpinner() {
        let threadDeletionManager = DependenciesBridge.shared.threadDeletionManager

        ModalActivityIndicatorViewController.present(
            fromViewController: self,
            title: CommonStrings.deletingModal,
            canCancel: false,
            presentationDelay: 0.5,
            backgroundBlockQueueQos: .userInitiated,
            backgroundBlock: { modal in
                self.clearHistoryWithSneakyTransaction(
                    threadDeletionManager: threadDeletionManager,
                )

                DispatchQueue.main.async {
                    modal.dismiss()
                }
            },
        )
    }

    private func clearHistoryWithSneakyTransaction(
        threadDeletionManager: any ThreadDeletionManager,
    ) {
        Logger.info("")
        let db = DependenciesBridge.shared.db
        let tsAccountManager = DependenciesBridge.shared.tsAccountManager

        db.write { tx in
            let localIdentifiers = tsAccountManager.localIdentifiers(tx: tx).owsFailUnwrap("never registered")

            threadDeletionManager.deleteThreads(
                TSThread.anyFetchAll(transaction: tx),
                sendDeleteForMeSyncMessage: true,
                updateStorageService: true,
                localIdentifiers: localIdentifiers,
                tx: tx,
            )

            // Need to instantiate these to remove them, since `StoryMessage`
            // has an `anyDidRemove` hook.
            for storyMessage in StoryMessage.anyFetchAll(transaction: tx) {
                storyMessage.anyRemove(transaction: tx)
            }
        }

        AttachmentStream.deleteAllAttachmentFiles()
    }
}
