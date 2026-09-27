//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import SignalUI
import XCTest

@testable import Signal
@testable import SignalServiceKit

/// 设置 → 账号 →「退出登录」的替代方案页（需求 §3.2 / §3.5，ADR-0072），以及这一组文案。
@MainActor
final class TellomiLogoutOptionsTest: SignalBaseTest {

    private final class NoopDeviceService: OWSDeviceService {
        func refreshDevices() async throws -> Bool { false }
        func unlinkDevice(deviceId: DeviceId) async throws {}
        func renameDevice(device: OWSDevice, newName: String) async throws {}
    }

    private func makeLogout(deviceIds: [DeviceId]) -> TellomiAccountLogout {
        let db = DependenciesBridge.shared.db
        let deviceStore = DependenciesBridge.shared.deviceStore
        db.write { tx in
            _ = deviceStore.replaceAll(
                with: deviceIds.map { OWSDevice(deviceId: $0, createdAt: .distantPast, lastSeenAt: Date(), name: nil) },
                tx: tx,
            )
        }
        return TellomiAccountLogout(
            db: db,
            deviceService: NoopDeviceService(),
            deviceStore: deviceStore,
            networkManager: MockNetworkManager(),
            registrationStateChangeManager: MockRegistrationStateChangeManager(),
            registrationSessionManager: RegistrationSessionManagerMock(),
            isReachable: { false },
            forgetUploadedPushToken: {},
        )
    }

    private func makePage(deviceIds: [DeviceId], canChangeNumber: Bool = true) -> TellomiLogoutOptionsViewController {
        let page = TellomiLogoutOptionsViewController(
            logout: makeLogout(deviceIds: deviceIds),
            changePhoneNumber: canChangeNumber ? {} : nil,
        )
        page.loadViewIfNeeded()
        return page
    }

    private func localized(_ key: String) -> String {
        OWSLocalizedString(key, comment: "")
    }

    // MARK: - 页面结构

    func testAlternativesComeFirstAndTheRedButtonIsLast() {
        let page = makePage(deviceIds: [.primary])

        XCTAssertEqual(page.title, localized("TELLOMI_LOGOUT_OPTIONS_TITLE"))
        let sections = page.contents.sections
        XCTAssertEqual(sections.count, 2, "替代方案 + 退出登录；没有已链接设备就不显示开关")
        XCTAssertEqual(sections[0].headerTitle, localized("TELLOMI_LOGOUT_OPTIONS_INTRO"))
        XCTAssertEqual(sections[0].items.count, 3, "屏幕锁定 · 管理存储空间 · 更换手机号")
        XCTAssertEqual(sections[1].items.count, 1)
    }

    func testLinkedDevicesSwitchOnlyShowsWhenThereAreLinkedDevices() {
        let page = makePage(deviceIds: [.primary, DeviceId(validating: 2)!])

        let sections = page.contents.sections
        XCTAssertEqual(sections.count, 3, "替代方案 + 「同时让已链接的设备退出」+ 退出登录")
        XCTAssertEqual(sections[1].items.count, 1)
    }

    func testChangeNumberRowIsHiddenWhenChangingNumberIsNotAllowed() {
        let page = makePage(deviceIds: [.primary], canChangeNumber: false)
        XCTAssertEqual(page.contents.sections[0].items.count, 2)
    }

    // MARK: - 文案

    private static let keys = [
        "TELLOMI_LOGOUT_SETTINGS_ROW",
        "TELLOMI_LOGOUT_OPTIONS_TITLE",
        "TELLOMI_LOGOUT_OPTIONS_INTRO",
        "TELLOMI_LOGOUT_OPTION_SCREEN_LOCK_TITLE",
        "TELLOMI_LOGOUT_OPTION_SCREEN_LOCK_BODY",
        "TELLOMI_LOGOUT_OPTION_STORAGE_TITLE",
        "TELLOMI_LOGOUT_OPTION_STORAGE_BODY",
        "TELLOMI_LOGOUT_OPTION_CHANGE_NUMBER_TITLE",
        "TELLOMI_LOGOUT_OPTION_CHANGE_NUMBER_BODY",
        "TELLOMI_LOGOUT_UNLINK_DEVICES_SWITCH",
        "TELLOMI_LOGOUT_OPTIONS_BUTTON",
        "TELLOMI_LOGOUT_CONFIRM_TITLE",
        "TELLOMI_LOGOUT_CONFIRM_BODY",
        "TELLOMI_LOGOUT_CONFIRM_KEEP_DATA",
        "TELLOMI_LOGOUT_CONFIRM_DELETE_DATA",
        "TELLOMI_LOGOUT_DELETE_CONFIRM_TITLE",
        "TELLOMI_LOGOUT_DELETE_CONFIRM_BODY",
        "TELLOMI_LOGOUT_DELETE_CONFIRM_BUTTON",
        "TELLOMI_LOGOUT_NETWORK_ERROR",
        "TELLOMI_LOGOUT_LAST_LOGIN_TITLE",
        "TELLOMI_LOGOUT_NEW_NUMBER_CONFIRM_BODY_FORMAT",
    ]

    private func bundle(for language: String) throws -> Bundle {
        let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"), language)
        return try XCTUnwrap(Bundle(path: path), language)
    }

    /// 中文按需求逐字（issue #1414 / 需求 §3.2 定稿）。测试进程只跑英文，所以直接读 zh_CN.lproj。
    func testSimplifiedChineseCopyIsExact() throws {
        let zhCN = try bundle(for: "zh_CN")
        let expected = [
            "TELLOMI_LOGOUT_SETTINGS_ROW": "退出登录",
            "TELLOMI_LOGOUT_OPTIONS_TITLE": "退出登录",
            "TELLOMI_LOGOUT_OPTIONS_INTRO": "退出前，看看这些能不能帮到你：",
            "TELLOMI_LOGOUT_OPTION_SCREEN_LOCK_TITLE": "屏幕锁定",
            "TELLOMI_LOGOUT_OPTION_SCREEN_LOCK_BODY": "担心别人看到？打开后要先解锁才能进入 Tellomi。",
            "TELLOMI_LOGOUT_OPTION_STORAGE_TITLE": "管理存储空间",
            "TELLOMI_LOGOUT_OPTION_STORAGE_BODY": "空间不够？清理不需要的图片和文件。",
            "TELLOMI_LOGOUT_OPTION_CHANGE_NUMBER_TITLE": "更换手机号",
            "TELLOMI_LOGOUT_OPTION_CHANGE_NUMBER_BODY": "换了手机号？聊天记录和联系人都会保留。",
            "TELLOMI_LOGOUT_UNLINK_DEVICES_SWITCH": "同时让已链接的设备退出",
            "TELLOMI_LOGOUT_OPTIONS_BUTTON": "退出登录",
            "TELLOMI_LOGOUT_CONFIRM_TITLE": "退出登录？",
            "TELLOMI_LOGOUT_CONFIRM_BODY": "聊天记录会保留在这台手机上，用同一个手机号重新登录后恢复。退出期间别人发来的消息会在服务器上等你，最多保留 30 天。",
            "TELLOMI_LOGOUT_CONFIRM_KEEP_DATA": "退出登录",
            "TELLOMI_LOGOUT_CONFIRM_DELETE_DATA": "退出并删除本机数据",
            "TELLOMI_LOGOUT_DELETE_CONFIRM_TITLE": "删除本机数据？",
            "TELLOMI_LOGOUT_DELETE_CONFIRM_BODY": "这台手机上的聊天记录和文件会全部删除，不能恢复。你的账号不受影响，可以在任何设备上重新登录。",
            "TELLOMI_LOGOUT_DELETE_CONFIRM_BUTTON": "删除并退出",
            "TELLOMI_LOGOUT_NETWORK_ERROR": "退出登录需要联网，请稍后再试。",
            "TELLOMI_LOGOUT_LAST_LOGIN_TITLE": "上次登录",
            "TELLOMI_LOGOUT_NEW_NUMBER_CONFIRM_BODY_FORMAT": "用新号码登录会删除这台手机上 %@ 的聊天记录。确定继续吗？",
        ]
        XCTAssertEqual(Set(expected.keys), Set(Self.keys))
        for (key, value) in expected {
            XCTAssertEqual(zhCN.localizedString(forKey: key, value: nil, table: nil), value, key)
        }
        XCTAssertEqual(
            String(format: zhCN.localizedString(forKey: "TELLOMI_LOGOUT_NEW_NUMBER_CONFIRM_BODY_FORMAT", value: nil, table: nil), "+86 138****5678"),
            "用新号码登录会删除这台手机上 +86 138****5678 的聊天记录。确定继续吗？",
        )
    }

    /// Tellomi 维护的四种语言（和跨境告知 #1381 一样）每一条都有；其余语言缺键时退回英文（TellomiLocalization）。
    func testEveryMaintainedLanguageHasEveryString() throws {
        for language in ["en", "zh_CN", "zh_HK", "zh_TW"] {
            let languageBundle = try bundle(for: language)
            for key in Self.keys {
                let value = languageBundle.localizedString(forKey: key, value: nil, table: nil)
                XCTAssertNotEqual(value, key, "\(language) is missing \(key)")
                XCTAssertFalse(value.contains("注销") || value.contains("註銷"), "\(language) \(key)：退出登录不是注销账号")
            }
            XCTAssertTrue(
                languageBundle.localizedString(forKey: "TELLOMI_LOGOUT_NEW_NUMBER_CONFIRM_BODY_FORMAT", value: nil, table: nil).contains("%@"),
                language,
            )
        }
    }
}
