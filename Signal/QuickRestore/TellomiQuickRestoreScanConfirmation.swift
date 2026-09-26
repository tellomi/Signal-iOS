//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

/// Tellomi：相机扫到新手机上的「转移帐户」码（`tellomi://rereg`、旧 `sgnl://rereg`）时，进转移页之前先问一句。
/// Android 同一刀：`TellomiReRegistrationScannedDialog`。
///
/// 上游直接进转移页：只剩一个「转移帐户」按钮，设备没设密码时连认证都算「不需要」（`LocalDeviceAuthentication`
/// 把 `passcodeNotSet` 当 `notRequired`），一点就把帐户交给显示码的那台手机，对方不用短信验证码就能注册这个号。
/// 同一处扫到设备关联码先弹提示，唯独这个没有。国内「扫一扫加好友」是日常动作，被人一句「扫我的码加个好友」骗去扫的场景要挡住。
/// 新手机上的说明仍然教用户用相机扫，所以不改入口，只在前面加这一步。
enum TellomiQuickRestoreScanConfirmation {

    static var title: String {
        OWSLocalizedString(
            "QUICK_RESTORE_SCAN_CONFIRMATION_TITLE_TELLOMI",
            comment: "Tellomi: title of the prompt shown when the in-app camera scans the account-transfer QR code of a new phone.",
        )
    }

    static var message: String {
        OWSLocalizedString(
            "QUICK_RESTORE_SCAN_CONFIRMATION_MESSAGE_TELLOMI",
            comment: "Tellomi: body of the prompt shown when the in-app camera scans the account-transfer QR code of a new phone. Warns that continuing moves the account to that phone.",
        )
    }

    /// 「继续」才进转移页；「取消」回去接着扫。
    static func actionSheet(onContinue: @escaping () -> Void, onCancel: @escaping () -> Void) -> ActionSheetController {
        let actionSheet = ActionSheetController(title: title, message: message)
        actionSheet.addAction(ActionSheetAction(title: CommonStrings.continueButton) { _ in onContinue() })
        actionSheet.addAction(ActionSheetAction(title: CommonStrings.cancelButton, style: .cancel) { _ in onCancel() })
        return actionSheet
    }
}
