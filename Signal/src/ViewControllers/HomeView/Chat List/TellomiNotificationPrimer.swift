//
// Copyright 2026 Tellomi
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UserNotifications

/// Tellomi（tellomi/tellomi#1218 F-01、#1112）：注册完成后**第一次进首屏**时的通知说明页，以及拒了之后的提示条判定。
///
/// 注册流程里不再要任何权限（`RegistrationCoordinatorImpl.requiresSystemPermissions`），拿推送令牌也不再顺手弹框
/// （`PushRegistrationManager.requestPushTokens`）。通知改在这里问：先讲清用途，点「继续」才出系统授权框。
/// - **只有一个按钮「继续」**：Apple HIG · Privacy——权限说明页只能一个按钮，写「继续 / 下一步」，不能有关闭 / 取消，
///   不能叫「允许」，不画指向「允许」的提示。所以 `canBeDismissed = false`，也不画拖动条。
/// - 只出一次：点了「继续」就记下；拒了的由会话列表顶部的「通知已关闭 · 去设置」常驻提示（`CLVReminderViews`）。
/// - 已经问过的（老版本注册时授过 / 拒过）不出：`.notDetermined` 才出。
///
/// Telegram reference（只看机制，一行没搬）：iOS `submodules/TelegramUI/Sources/ApplicationContext.swift` 登录后按分组实验
/// 出 `PermissionController` 闪屏（`TelegramPermissionsUI/Sources/PermissionControllerNode.swift`，按钮叫「允许」），
/// 或直接弹系统框；Android `DialogsActivity` 先弹系统框、被拒才出可划走的 `NotificationPermissionDialog`。
/// Tellomi 反过来：先说明、只一个「继续」、只问一次。
enum TellomiNotificationPrimer {
    private static let store = KeyValueStore(collection: "TellomiNotificationPrimer")
    private static let hasShownKey = "hasShown"

    /// 说明页该不该出：系统还没问过（`.notDetermined`），并且这台设备上还没出过。纯函数，便于单测。
    static func shouldShowPrimer(authorizationStatus: UNAuthorizationStatus, hasShown: Bool) -> Bool {
        return authorizationStatus == .notDetermined && !hasShown
    }

    /// 「通知已关闭」提示条该不该挂：用户在系统框里拒了，或者之后在系统设置里关了（`.denied`）。
    /// `.notDetermined` 是还没问过，不挂——不能在说明页之前先把结论写出来。
    static func shouldShowDisabledReminder(authorizationStatus: UNAuthorizationStatus) -> Bool {
        return authorizationStatus == .denied
    }

    static func hasShown(tx: DBReadTransaction) -> Bool {
        return store.getBool(hasShownKey, defaultValue: false, transaction: tx)
    }

    static func markShown(tx: DBWriteTransaction) {
        store.setBool(true, key: hasShownKey, transaction: tx)
    }

    static func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        return await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}

// MARK: -

/// 说明页本身。点「继续」：先记下「出过了」，再请求授权（系统框在这时才出现），然后收起。
final class TellomiNotificationPrimerSheet: HeroSheetViewController {
    override var canBeDismissed: Bool { false }
    override var handleBackgroundColor: UIColor { .clear }

    init(onAuthorizationAnswered: @escaping @MainActor () -> Void) {
        super.init(
            hero: .image(.notificationMegaphone),
            title: OWSLocalizedString(
                "TELLOMI_NOTIFICATION_PRIMER_TITLE",
                comment: "Title of the one-time sheet shown on the chat list after registration, explaining why Tellomi asks for notification permission.",
            ),
            body: OWSLocalizedString(
                "TELLOMI_NOTIFICATION_PRIMER_BODY",
                comment: "Body of the one-time notification permission explanation sheet. Explains the purpose and that the system will ask next.",
            ),
            primaryButton: HeroSheetViewController.Button(
                title: OWSLocalizedString(
                    "TELLOMI_NOTIFICATION_PRIMER_CONTINUE",
                    comment: "The only button on the notification permission explanation sheet. Must read 'Continue', never 'Allow'.",
                ),
                action: { sheet in
                    SSKEnvironment.shared.databaseStorageRef.write { tx in
                        TellomiNotificationPrimer.markShown(tx: tx)
                    }
                    Task { @MainActor in
                        await AppEnvironment.shared.pushRegistrationManagerRef.registerUserNotificationSettings()
                        sheet.dismiss(animated: true)
                        onAuthorizationAnswered()
                    }
                },
            ),
        )
    }
}
