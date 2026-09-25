//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit
import XCTest

@testable import Signal
@testable import SignalUI

final class PhoneNumberCountryTest: SignalBaseTest {
    func testCountryCodesForSearchTerm() {
        func countryCodes(forSearchTerm searchTerm: String?) -> [String] {
            return PhoneNumberCountry.buildCountries(searchText: searchTerm).map(\.countryCode)
        }
        // Empty search.
        XCTAssertGreaterThan(countryCodes(forSearchTerm: nil).count, 30)
        XCTAssertGreaterThan(countryCodes(forSearchTerm: "").count, 30)
        XCTAssertGreaterThan(countryCodes(forSearchTerm: " ").count, 30)

        // Searches with no results.
        XCTAssertEqual(countryCodes(forSearchTerm: " . ").count, 0)
        XCTAssertEqual(countryCodes(forSearchTerm: " XXXXX ").count, 0)
        XCTAssertEqual(countryCodes(forSearchTerm: " ! ").count, 0)

        // Search by country code.
        XCTAssertEqual(countryCodes(forSearchTerm: "GB"), ["GB"])
        XCTAssertEqual(countryCodes(forSearchTerm: "gb"), ["GB"])
        XCTAssertEqual(countryCodes(forSearchTerm: "GB "), ["GB"])
        XCTAssertEqual(countryCodes(forSearchTerm: " GB"), ["GB"])
        XCTAssert(countryCodes(forSearchTerm: " G").contains("GB"))
        XCTAssertFalse(countryCodes(forSearchTerm: " B").contains("GB"))

        // Search by country name.
        XCTAssertEqual(countryCodes(forSearchTerm: "united kingdom"), ["GB"])
        XCTAssertEqual(countryCodes(forSearchTerm: " UNITED KINGDOM "), ["GB"])
        XCTAssertEqual(countryCodes(forSearchTerm: " UNITED KING "), ["GB"])
        XCTAssertEqual(countryCodes(forSearchTerm: " UNI KING "), ["GB"])
        XCTAssertEqual(countryCodes(forSearchTerm: " u k "), ["GB"])
        XCTAssert(countryCodes(forSearchTerm: " u").contains("GB"))
        XCTAssert(countryCodes(forSearchTerm: " k").contains("GB"))
        XCTAssertFalse(countryCodes(forSearchTerm: " m").contains("GB"))

        // Search by calling code.
        XCTAssert(countryCodes(forSearchTerm: " +44 ").contains("GB"))
        XCTAssert(countryCodes(forSearchTerm: " 44 ").contains("GB"))
        XCTAssert(countryCodes(forSearchTerm: " +4 ").contains("GB"))
        XCTAssert(countryCodes(forSearchTerm: " 4 ").contains("GB"))
        XCTAssertFalse(countryCodes(forSearchTerm: " +123 ").contains("GB"))
        XCTAssertFalse(countryCodes(forSearchTerm: " +444 ").contains("GB"))
    }
}

// MARK: - Tellomi（tellomi/tellomi#1108）

/// 联系人一级 Tab：底栏顺序、下标与 Tab 的对应、联系人页的选人配置、邀请文字。
final class TellomiContactsTabTest: SignalBaseTest {
    func testTabsAreCallsChatsContactsStoriesAndTheAppOpensOnChats() {
        XCTAssertEqual(HomeTabBarController.tabsToShow(areStoriesEnabled: false), [.calls, .chatList, .contacts])
        XCTAssertEqual(HomeTabBarController.tabsToShow(areStoriesEnabled: true), [.calls, .chatList, .contacts, .stories])
        XCTAssertEqual(HomeTabBarController.initialTab, .chatList)
    }

    func testSelectedTabFollowsTheDisplayedOrderNotTheRawValue() {
        let tabs = HomeTabBarController.tabsToShow(areStoriesEnabled: true)
        XCTAssertEqual(HomeTabBarController.tab(atIndex: 0, in: tabs), .calls)
        XCTAssertEqual(HomeTabBarController.tab(atIndex: 1, in: tabs), .chatList)
        XCTAssertEqual(HomeTabBarController.tab(atIndex: 2, in: tabs), .contacts)
        XCTAssertEqual(HomeTabBarController.tab(atIndex: 3, in: tabs), .stories)
        XCTAssertEqual(HomeTabBarController.tab(atIndex: 4, in: tabs), .chatList)
        XCTAssertEqual(HomeTabBarController.index(of: .calls, in: tabs), 0)
        XCTAssertEqual(HomeTabBarController.index(of: .contacts, in: tabs), 2)
        XCTAssertEqual(HomeTabBarController.index(of: .chatList, in: tabs), 1)
        XCTAssertEqual(HomeTabBarController.index(of: .stories, in: tabs), 3)

        // 快拍关掉时它不在底栏上：退回聊天
        let withoutStories = HomeTabBarController.tabsToShow(areStoriesEnabled: false)
        XCTAssertEqual(HomeTabBarController.index(of: .stories, in: withoutStories), 1)
        XCTAssertEqual(HomeTabBarController.index(of: .chatList, in: []), 0)
    }

    func testContactsTabTitle() throws {
        XCTAssertEqual(HomeTabBarController.Tabs.contacts.title, "Contacts")
        for (localization, expected) in [("zh_CN", "联系人"), ("zh_HK", "聯絡人"), ("zh_TW", "聯絡人")] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: localization, ofType: "lproj"), localization)
            let bundle = try XCTUnwrap(Bundle(path: path), localization)
            XCTAssertEqual(bundle.localizedString(forKey: "HOME_VIEW_TELLOMI_CONTACTS_TAB_TITLE", value: nil, table: nil), expected, localization)
        }
    }

    func testContactsListOnlyHasPeopleAndDoesNotNudgeForContactsAccessWithoutCDSI() {
        let recipientPicker = RecipientPickerViewController()
        TellomiContactsViewController.configure(recipientPicker)
        XCTAssertEqual(recipientPicker.groupsToShow, .noGroups)
        XCTAssertTrue(recipientPicker.shouldHideLocalRecipient)
        XCTAssertFalse(recipientPicker.shouldShowNewGroup)
        XCTAssertFalse(recipientPicker.shouldShowInvites)
        XCTAssertTrue(recipientPicker.allowsAddByAddress)
        XCTAssertTrue(recipientPicker.tellomiSkipsNoContactsView)
        XCTAssertEqual(recipientPicker.tellomiHidesContactAccessReminder, !TSConstants.cdsiAvailable)
    }

    func testInviteTextEndsWithTheDownloadLink() {
        let text = TellomiContactsViewController.inviteText()
        XCTAssertTrue(text.hasPrefix(OWSLocalizedString("SMS_INVITE_BODY", comment: "")), text)
        XCTAssertTrue(text.hasSuffix(" https://tellomi.app/download/"), text)
    }
}
