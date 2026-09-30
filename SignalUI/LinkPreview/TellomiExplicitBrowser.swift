//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

public import SafariServices
public import UIKit

/// ADR-0063 §4.9 打开顺序的第 3 步「用**浏览器**打开」在 iOS 上的底层接入：`SFSafariViewController`。
///
/// - 第一跳直接加载，不会被装了的 App 的通用链接接走（用户在页面里再点通用链接仍可能进 App，所以准确说是「第一跳只进浏览器」）；
/// - 带 Safari 的欺诈网站警告（§6.1 第二层）；
/// - 只接受 http / https：`intent:` / `javascript:` / `data:` / `file:` 以及其它任何 scheme **永远不产生跳转**（§4.9、§6.1）。
///   这也是崩溃防护：`SFSafariViewController` 收到非 http(s) 的 URL 会直接抛异常。
///
/// 聊天里点卡片 / 点正文链接按 `rust/links` 的 `open_plan` 走（`ConversationViewController.tellomiOpenExternalLink`）：`browser` 那一步用它。
public enum TellomiExplicitBrowser {

    /// 能交给显式浏览器的 URL；不能的返回 nil（调用方什么都不做）。
    public static func navigableUrl(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            return nil
        }
        guard let host = url.host, !host.isEmpty else {
            return nil
        }
        return url
    }

    public static func makeViewController(for url: URL) -> SFSafariViewController? {
        guard let url = navigableUrl(url) else {
            return nil
        }
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        configuration.barCollapsingEnabled = true
        let viewController = SFSafariViewController(url: url, configuration: configuration)
        viewController.dismissButtonStyle = .close
        return viewController
    }

    /// 在显式浏览器里打开；URL 不能打开时不做任何事，返回 false。
    @discardableResult
    @MainActor
    public static func open(_ url: URL, from presenter: any TellomiExplicitBrowserPresenting) -> Bool {
        guard let viewController = makeViewController(for: url) else {
            return false
        }
        presenter.presentExplicitBrowser(viewController)
        return true
    }
}

/// 测试里换成记录用的假对象，核「不能打开的 URL 一次都没有 present」。
public protocol TellomiExplicitBrowserPresenting {
    @MainActor
    func presentExplicitBrowser(_ viewController: SFSafariViewController)
}

extension UIViewController: TellomiExplicitBrowserPresenting {
    @MainActor
    public func presentExplicitBrowser(_ viewController: SFSafariViewController) {
        present(viewController, animated: true)
    }
}
