//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

/// 聊天里点到的、不是 Tellomi 自己对象的链接，按 rust/links 的 `open_plan` 打开（ADR-0063 §4.9、§5.5、§6.1）。
/// 点卡片和点正文里的链接都走 `handleUrl`，所以都到这里。目标永远是消息里那条 URL，计划只说怎么交出去、按什么顺序试：
/// `installed_app_only` → `UIApplication.open(url, options: [.universalLinksOnly: true])`（系统认这个通用链接才进 App，没有确认框）；
/// `scheme` → 注册表里的 App scheme；`browser` → `SFSafariViewController`（带 Safari 的欺诈网站警告）；`copy_link` → 复制并提示。
/// 域名冒充知名域名时先问一次，可以继续打开。没有注册表（或它出错）就照 Signal 原样打开。
extension ConversationViewController {

    func tellomiOpenExternalLink(_ url: URL) {
        switch TellomiLinkOpener.decide(url: url.absoluteString, classifier: TellomiLinkRegistry.classifier) {
        case .signalDefault:
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        case .openNothing:
            // 只记这一件事，不记 URL（§6.5）。
            Logger.warn("Not opening a link that is not http(s).")
        case .open(let plan):
            tellomiRun(plan)
        case .confirmThenOpen(let plan, let lookalike):
            OWSActionSheets.showConfirmationAlert(
                message: String(
                    format: OWSLocalizedString(
                        "TELLOMI_LINK_OPEN_LOOKALIKE_MESSAGE",
                        comment: "Tellomi (ADR-0063 §6.1): asks before opening a link whose domain imitates a well-known one; %1$@ is the well-known domain",
                    ),
                    lookalike,
                ),
                proceedTitle: OWSLocalizedString(
                    "TELLOMI_LINK_OPEN_OPEN_ANYWAY",
                    comment: "Tellomi (ADR-0063 §6.1): button that opens a link whose domain imitates a well-known one anyway",
                ),
                proceedAction: { [weak self] _ in
                    self?.tellomiRun(plan)
                },
                fromViewController: self,
            )
        }
    }

    private func tellomiRun(_ plan: TellomiOpenPlan) {
        let launcher = TellomiUIKitLauncher(presenter: self)
        Task { @MainActor in
            let took = await TellomiLinkOpener.run(steps: plan.steps, launcher: launcher)
            // 只记哪一步接住了，不记 URL（§6.5）。
            Logger.info("Opened a link via \(took ?? "nothing")")
        }
    }
}

@MainActor
final class TellomiUIKitLauncher: TellomiLinkLauncher {
    private weak var presenter: ConversationViewController?

    init(presenter: ConversationViewController?) {
        self.presenter = presenter
    }

    /// tell.cc 的对象在 `handleUrl` 里已经分流到 Tellomi 自己的路由了，走不到这里。
    func inApp(_ url: URL) async -> Bool {
        return false
    }

    func installedAppOnly(_ url: URL) async -> Bool {
        return await UIApplication.shared.open(url, options: [.universalLinksOnly: true])
    }

    func scheme(_ url: URL) async -> Bool {
        return await UIApplication.shared.open(url, options: [:])
    }

    func browser(_ url: URL) async -> Bool {
        guard let presenter else {
            return false
        }
        return TellomiExplicitBrowser.open(url, from: presenter)
    }

    func copyLink(_ url: URL) async -> Bool {
        UIPasteboard.general.string = url.absoluteString
        presenter?.presentToastCVC(OWSLocalizedString(
            "TELLOMI_LINKS_LINK_COPIED",
            comment: "Tellomi (ADR-0063 §5.5): toast after the link was copied because nothing could open it",
        ))
        return true
    }
}
