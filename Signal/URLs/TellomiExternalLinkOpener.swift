//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

/// 点一条来自消息内容的外部链接怎么打开：按 rust/links 的 `open_plan`（ADR-0063 §4.9、§5.5、§6.1，§8.1 第 7 行）。
/// 目标永远是消息里那条 URL，计划只说怎么交出去、按什么顺序试：
/// `installed_app_only` → `UIApplication.open(url, options: [.universalLinksOnly: true])`（系统认这个通用链接才进 App，没有确认框）；
/// `scheme` → 注册表里的 App scheme；`browser` → `SFSafariViewController`（带 Safari 的欺诈网站警告）；`copy_link` → 复制并提示。
/// 支付金融的计划里只有 `browser`：任何一处把消息里的链接直接交给 `UIApplication.open`，装了支付宝的手机都会被通用链接带进 App（§4.9）。
/// 域名冒充知名域名时先问一次，可以继续打开。没有注册表（或它出错）就照 Signal 原样交给系统。
///
/// 聊天页（`ConversationViewController.handleUrl`）、消息详情、「所有媒体」的链接列表、长文本、故事里点链接都走这一个出口；
/// 新增的、会打开消息里 URL 的界面也必须走它，不要自己调 `UIApplication.open`。
enum TellomiExternalLinkOpener {

    /// 计划里 `in_app` 那一步（tell.cc 自己的对象）谁来接。
    enum InAppRoute {
        /// 调用方在进来之前已经把 Tellomi 自己的链接分流走了（聊天页的 `handleUrl`）：走到这里的 `in_app` 当作没接住，往下试。
        case handledByCaller
        /// 这个界面没有 Tellomi 的路由器（消息详情、「所有媒体」、长文本、故事）：和这个出口出现之前一样交给系统。
        /// 只有 tell.cc 自己的对象链接会走到这一步，交给系统不会带进任何第三方 App。
        case handOffToSystem
    }

    enum Outcome: Equatable {
        /// 没有注册表（或它出错）：照 Signal 原样交给了系统。
        case handedToSystem
        /// 计划是空的（不是 http(s)：`intent:`、`javascript:`、`data:`、`file:` 永远不是目标）：什么都没打开。
        case openedNothing
        /// 计划里接住链接的那一步的类型；每一步都没接住是 nil。
        case ran(step: String?)
    }

    /// 界面上怎么打开：`presenter` 用来弹浏览器、确认框和提示。
    @MainActor
    static func open(
        _ url: URL,
        from presenter: UIViewController,
        inApp: InAppRoute,
        toast: (@MainActor (String) -> Void)? = nil,
    ) {
        let launcher = TellomiUIKitLauncher(presenter: presenter, inApp: inApp, toast: toast)
        open(
            url,
            classifier: TellomiLinkRegistry.classifier,
            launcher: launcher,
            systemOpen: { UIApplication.shared.open($0, options: [:], completionHandler: nil) },
            confirmLookalike: { [weak presenter] lookalike, proceed in
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
                    proceedAction: { _ in proceed() },
                    fromViewController: presenter,
                )
            },
        )
    }

    /// 决定和执行；界面的部分（交给系统、浏览器、确认框）都从外面传进来，好在测试里换成记录用的假对象。
    /// `completion` 在链接有了结果时调一次；仿冒域名的确认框用户取消了就一直不会调。
    @MainActor
    static func open(
        _ url: URL,
        classifier: TellomiLinkClassifier,
        launcher: any TellomiLinkLauncher,
        systemOpen: @MainActor (URL) -> Void,
        confirmLookalike: @MainActor (_ lookalike: String, _ proceed: @escaping @MainActor () -> Void) -> Void,
        completion: (@MainActor (Outcome) -> Void)? = nil,
    ) {
        switch TellomiLinkOpener.decide(url: url.absoluteString, classifier: classifier) {
        case .signalDefault:
            systemOpen(url)
            completion?(.handedToSystem)
        case .openNothing:
            // 只记这一件事，不记 URL（§6.5）。
            Logger.warn("Not opening a link that is not http(s).")
            completion?(.openedNothing)
        case .open(let plan):
            run(plan, launcher: launcher, completion: completion)
        case .confirmThenOpen(let plan, let lookalike):
            confirmLookalike(lookalike) {
                run(plan, launcher: launcher, completion: completion)
            }
        }
    }

    @MainActor
    private static func run(
        _ plan: TellomiOpenPlan,
        launcher: any TellomiLinkLauncher,
        completion: (@MainActor (Outcome) -> Void)?,
    ) {
        Task { @MainActor in
            let took = await TellomiLinkOpener.run(steps: plan.steps, launcher: launcher)
            // 只记哪一步接住了，不记 URL（§6.5）。
            Logger.info("Opened a link via \(took ?? "nothing")")
            completion?(.ran(step: took))
        }
    }

    /// 长文本里点到的数据项：只有链接（不是 mailto）走 `open_plan`；电话、日期、地址、邮箱仍然交给系统，和聊天页的 `openLink` 一样。
    static func usesOpenPlan(_ dataItem: TextCheckingDataItem) -> Bool {
        guard dataItem.dataType == .link else {
            return false
        }
        return !dataItem.url.absoluteString.lowercased().hasPrefix("mailto:")
    }
}

/// `open_plan` 每一步在 iOS 上的落点。
@MainActor
final class TellomiUIKitLauncher: TellomiLinkLauncher {

    /// 交给系统打开一个 URL；接住了返回 true。测试里换成记录用的假对象。
    typealias SystemOpen = @MainActor (URL, [UIApplication.OpenExternalURLOptionsKey: Any]) async -> Bool

    private weak var presenter: UIViewController?
    private let inAppRoute: TellomiExternalLinkOpener.InAppRoute
    private let toast: (@MainActor (String) -> Void)?
    private let systemOpen: SystemOpen

    init(
        presenter: UIViewController?,
        inApp: TellomiExternalLinkOpener.InAppRoute = .handledByCaller,
        toast: (@MainActor (String) -> Void)? = nil,
        systemOpen: @escaping SystemOpen = { await UIApplication.shared.open($0, options: $1) },
    ) {
        self.presenter = presenter
        self.inAppRoute = inApp
        self.toast = toast
        self.systemOpen = systemOpen
    }

    func inApp(_ url: URL) async -> Bool {
        switch inAppRoute {
        case .handledByCaller:
            return false
        case .handOffToSystem:
            return await systemOpen(url, [:])
        }
    }

    func installedAppOnly(_ url: URL) async -> Bool {
        return await systemOpen(url, [.universalLinksOnly: true])
    }

    func scheme(_ url: URL) async -> Bool {
        return await systemOpen(url, [:])
    }

    func browser(_ url: URL) async -> Bool {
        guard let presenter else {
            return false
        }
        return TellomiExplicitBrowser.open(url, from: presenter)
    }

    func copyLink(_ url: URL) async -> Bool {
        UIPasteboard.general.string = url.absoluteString
        let text = OWSLocalizedString(
            "TELLOMI_LINKS_LINK_COPIED",
            comment: "Tellomi (ADR-0063 §5.5): toast after the link was copied because nothing could open it",
        )
        if let toast {
            toast(text)
        } else {
            presenter?.presentToast(text: text)
        }
        return true
    }
}
