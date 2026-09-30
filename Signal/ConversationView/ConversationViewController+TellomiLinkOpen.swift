//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

/// 聊天里点到的、不是 Tellomi 自己对象的链接，按 rust/links 的 `open_plan` 打开（ADR-0063 §4.9、§5.5、§6.1）。
/// 点卡片和点正文里的链接都走 `handleUrl`，所以都到这里；怎么按计划试、试不动怎么办在 `TellomiExternalLinkOpener`，
/// 消息详情、「所有媒体」的链接列表、长文本、故事里点链接走的是同一个出口。
extension ConversationViewController {

    func tellomiOpenExternalLink(_ url: URL) {
        // tell.cc 的对象在 `handleUrl` 里已经分流到 Tellomi 自己的路由了，所以 `in_app` 这一步在这里不接。
        // 「已复制链接」的提示要避开输入框，用聊天页自己的 toast。
        TellomiExternalLinkOpener.open(
            url,
            from: self,
            inApp: .handledByCaller,
            toast: { [weak self] in self?.presentToastCVC($0) },
        )
    }
}
