//
// Copyright 2026 Tellomi
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

import SignalServiceKit
@testable import Signal
@testable import SignalUI

/// Tellomi（tellomi/tellomi#1165）：「关于 Tellomi」页的每一行都做它该做的事，地址一个字都不能错（与 Android `AboutSettingsScreenTest` 同一张表）。
final class AboutTellomiViewControllerTest: XCTestCase {
    private final class RecordingActions: AboutTellomiActions {
        var events: [String] = []
        func copy(_ text: String) { events.append("copy:\(text)") }
        func openInAppBrowser(_ url: URL) { events.append("open:\(url.absoluteString)") }
        func writeEmail(to address: String) { events.append("email:\(address)") }
        func showLicenses() { events.append("licenses") }
    }

    private func makeViewController(_ actions: RecordingActions) -> AboutTellomiViewController {
        let viewController = AboutTellomiViewController(actions: actions, versionName: "0.1.2", buildNumber: "175101")
        viewController.loadViewIfNeeded()
        return viewController
    }

    func testTappingTheVersionCopiesTheFullVersion() {
        let actions = RecordingActions()
        makeViewController(actions).didTapVersion()
        XCTAssertEqual(actions.events, ["copy:0.1.2 (175101)"])
    }

    /// 从上到下点一遍所有能点的行：更新 → 官网 → 三个邮箱（点按复制）→ 六份法律文件（App 内浏览器）→ 开源许可 → 源代码
    func testEveryRowDoesWhatItSays() {
        let actions = RecordingActions()
        let viewController = makeViewController(actions)

        for section in viewController.contents.sections {
            for item in section.items {
                item.actionBlock?()
            }
        }

        XCTAssertEqual(actions.events, [
            "open:https://www.tellomi.app/download/",
            "open:https://www.tellomi.app/",
            "copy:support@tellomi.app",
            "copy:privacy@tellomi.app",
            "copy:abuse@tellomi.app",
            "open:https://www.tellomi.app/legal/terms/",
            "open:https://www.tellomi.app/legal/privacy/",
            "open:https://www.tellomi.app/legal/pi-collection/",
            "open:https://www.tellomi.app/legal/third-party/",
            "open:https://www.tellomi.app/legal/permissions/",
            "open:https://www.tellomi.app/legal/complaints/",
            "licenses",
            "open:https://github.com/tellomi",
        ])
    }

    /// 长按邮箱出「写邮件」：只有三个邮箱行有长按菜单
    func testOnlyEmailRowsHaveTheWriteEmailMenu() {
        let viewController = makeViewController(RecordingActions())
        let itemsWithMenus = viewController.contents.sections.flatMap(\.items).filter { $0.contextMenuActionProvider != nil }
        XCTAssertEqual(itemsWithMenus.count, 3)
    }

    /// 页脚三行署名（#984）与「帮助」里原来的一字不差：还是那一个键
    func testFooterKeepsTheAttribution() {
        let viewController = makeViewController(RecordingActions())
        XCTAssertEqual(
            viewController.contents.sections.last?.footerTitle,
            OWSLocalizedString("ABOUT_SECTION_FOOTER_TELLOMI", comment: ""),
        )
    }

    /// 「开源许可」读的是 App 里的 Settings.bundle/Acknowledgements.plist（系统「设置」App 显示的同一份）
    func testLicensesLoadFromTheSettingsBundle() {
        let entries = TellomiAcknowledgements.load()
        XCTAssertGreaterThan(entries.count, 100)
        XCTAssertFalse(entries.contains { $0.title == "Acknowledgements" })
        XCTAssertTrue(entries.allSatisfy { !$0.text.isEmpty })
    }
}
