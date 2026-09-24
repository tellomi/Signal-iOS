//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SafariServices
import SignalServiceKit
import SignalUI

final class HelpViewController: OWSTableViewController2 {

    override func viewDidLoad() {
        super.viewDidLoad()
        updateTableContents()
    }

    private func updateTableContents() {
        let helpTitle = CommonStrings.help
        let supportCenterLabel = OWSLocalizedString(
            "HELP_SUPPORT_CENTER",
            comment: "Help item that takes the user to the Signal support website",
        )
        let contactLabel = OWSLocalizedString(
            "HELP_CONTACT_US",
            comment: "Help item allowing the user to file a support request",
        )

        let contents = OWSTableContents(title: helpTitle)

        let helpSection = OWSTableSection()
        helpSection.add(.disclosureItem(
            withText: supportCenterLabel,
            actionBlock: { [weak self] in
                let vc = SFSafariViewController(url: URL.Support.generic)
                self?.present(vc, animated: true, completion: nil)
            },
        ))
        helpSection.add(.disclosureItem(
            withText: contactLabel,
            actionBlock: {
                guard ComposeSupportEmailOperation.canSendEmails else {
                    let localizedSheetTitle = OWSLocalizedString(
                        "EMAIL_SIGNAL_TITLE",
                        comment: "Title for the fallback support sheet if user cannot send email",
                    )
                    let localizedSheetMessage = OWSLocalizedString(
                        "EMAIL_SIGNAL_MESSAGE",
                        comment: "Description for the fallback support sheet if user cannot send email",
                    )
                    let fallbackSheet = ActionSheetController(
                        title: localizedSheetTitle,
                        message: localizedSheetMessage,
                    )
                    let buttonTitle = OWSLocalizedString("BUTTON_OKAY", comment: "Label for the 'okay' button.")
                    fallbackSheet.addAction(ActionSheetAction(title: buttonTitle, style: .default))
                    self.presentActionSheet(fallbackSheet)
                    return
                }
                let supportVC = ContactSupportViewController()
                let navVC = OWSNavigationController(rootViewController: supportVC)
                self.presentFormSheet(navVC, animated: true)
            },
        ))
        contents.add(helpSection)

        let loggingSection = OWSTableSection()
        loggingSection.headerTitle = OWSLocalizedString("LOGGING_SECTION", comment: "Title for the 'logging' help section.")
        loggingSection.footerTitle = OWSLocalizedString("LOGGING_SECTION_FOOTER", comment: "Footer for the 'logging' help section.")
        loggingSection.add(.item(
            name: OWSLocalizedString("SETTINGS_ADVANCED_SUBMIT_DEBUGLOG", comment: ""),
            accessibilityIdentifier: UIView.accessibilityIdentifier(in: self, name: "submit_debug_log"),
            actionBlock: { [weak self] in
                guard let self else { return }
                DebugLogs(dumper: .fromGlobals()).promptToSubmitLogs(from: self)
            },
        ))
        contents.add(loggingSection)

        // Tellomi（tellomi/tellomi#1165）：版本、法律条款和页脚三行署名（#984）都搬到「关于 Tellomi」（AboutTellomiViewController），
        // 「帮助」只留支持中心 / 联系我们 / 调试日志。

        self.contents = contents
    }
}

// MARK: -

#if DEBUG

@available(iOS 17, *)
#Preview {
    return HelpViewController()
}

#endif
