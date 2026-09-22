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

        let aboutSection = OWSTableSection()
        aboutSection.headerTitle = OWSLocalizedString("ABOUT_SECTION_TITLE", comment: "Title for the 'about' help section")
        // Tellomi（#984，owner 2026-09-23 定）：三行并列，和 Android 的 HelpSettingsFragment 一字一句对齐。
        //   Copyright Signal Messenger        ← 上游署名，AGPL 要求派生作品保留，不能换成我们自己
        //   Modifications Copyright Tellomi   ← 我们对修改部分的署名
        //   Licensed under the AGPLv3
        // 上游还有第四行「Signal is a 501c3 nonprofit」，去掉了：Tellomi 不是非营利组织，
        // 换个名字就是一句关于自身法律主体的假话。
        //
        // 注意这条**之前是错的**：它把上游那行整个换成了「Copyright Tellomi」，
        // 等于在 AGPL 派生作品里移除原作者署名（而同一段注释却写着「版权与许可证要保留」）。
        aboutSection.footerTitle = OWSLocalizedString(
            "ABOUT_SECTION_FOOTER_TELLOMI",
            comment: "Footer for the 'about' help section: copyright and license only.",
        )
        aboutSection.add(.copyableItem(
            label: OWSLocalizedString("SETTINGS_VERSION", comment: ""),
            value: AppVersionImpl.shared.prettyAppVersion,
        ))
        aboutSection.add(.disclosureItem(
            withText: OWSLocalizedString("SETTINGS_LEGAL_TERMS_CELL", comment: ""),
            actionBlock: { [weak self] in
                let url = TSConstants.legalTermsUrl
                let vc = SFSafariViewController(url: url)
                self?.present(vc, animated: true, completion: nil)
            },
        ))
        contents.add(aboutSection)

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
