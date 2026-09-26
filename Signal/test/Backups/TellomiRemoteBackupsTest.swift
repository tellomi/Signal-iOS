//
// Copyright 2026 Tellomi
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import Testing
@testable import Signal

/// Tellomi（tellomi/tellomi#1193，#984 的 iOS 半边）：阶段一不做远端备份（上游的「Signal 备份」免费 / 付费套餐），
/// megaphone、首屏提示、通知等各处「去备份」的入口都不能把人带到远端备份页（选择方案页页脚写着「Signal 是一个非营利性平台」）。
struct TellomiRemoteBackupsTest {
    @Test
    func remoteBackupsAreOff() {
        // 要打开远端备份，先接上备份服务端与 CDN、支付通道，再改这里
        #expect(TSConstants.remoteBackupsEnabled == false)
    }

    @Test
    func onlyLocalBackupPagesOpen() {
        #expect(ChatListViewController.tellomiCanOpenBackupSettings(page: .remote()) == false)
        #expect(ChatListViewController.tellomiCanOpenBackupSettings(page: .local))
        // 落地页只在有本地备份的构建里开：正式构建里它就是远端页
        #expect(ChatListViewController.tellomiCanOpenBackupSettings(page: .landingPage) == BuildFlags.LocalFileBackups.settingsUI)
    }
}
