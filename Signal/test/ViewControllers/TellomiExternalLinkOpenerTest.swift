//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SafariServices
import UIKit
import XCTest
@testable import Signal
@testable import SignalServiceKit

/// ADR-0063 §4.9 / §8.1 第 7 行：消息里的外部链接不管从哪个界面点开，都走同一个出口（`TellomiExternalLinkOpener`），按 rust/links 的 `open_plan` 办。
/// 支付金融的计划里只有显式浏览器：交给系统的话，装了支付宝的手机会被通用链接直接带进 App。
/// 这里用随包的真注册表，把「交给系统」换成记录用的假对象，核每一种链接**有没有**碰到系统。
@MainActor
final class TellomiExternalLinkOpenerTest: XCTestCase {

    // MARK: - 假对象

    /// 记下每一次「交给系统」：网址，以及是不是「只交给已装的 App」。
    private final class SystemOpenRecorder {
        struct Call: Equatable {
            let url: String
            let universalLinksOnly: Bool
        }

        var calls = [Call]()
        let accepts: Bool

        init(accepts: Bool = false) {
            self.accepts = accepts
        }

        func open(_ url: URL, _ options: [UIApplication.OpenExternalURLOptionsKey: Any]) -> Bool {
            calls.append(Call(url: url.absoluteString, universalLinksOnly: (options[.universalLinksOnly] as? Bool) == true))
            return accepts
        }
    }

    /// 记下弹出来的东西（显式浏览器就是弹一个 `SFSafariViewController`）。
    private final class RecordingPresenter: UIViewController {
        var presented = [UIViewController]()

        override func present(_ viewControllerToPresent: UIViewController, animated flag: Bool, completion: (() -> Void)? = nil) {
            presented.append(viewControllerToPresent)
            completion?()
        }
    }

    private struct Run {
        let outcome: TellomiExternalLinkOpener.Outcome?
        let system: SystemOpenRecorder
        let presenter: RecordingPresenter
        let confirmations: [String]
        let toasts: [String]
    }

    /// 走一遍共用出口，等它有了结果（仿冒域名的确认框：`proceed` 为 true 就当用户点了「仍然打开」，否则当用户取消了，结果是 nil）。
    private func open(
        _ rawUrl: String,
        inApp: TellomiExternalLinkOpener.InAppRoute = .handOffToSystem,
        classifier: TellomiLinkClassifier = TellomiLinkRegistry.classifier,
        systemAccepts: Bool = false,
        proceed: Bool = true,
    ) async throws -> Run {
        let url = try XCTUnwrap(URL(string: rawUrl), rawUrl)
        let system = SystemOpenRecorder(accepts: systemAccepts)
        let presenter = RecordingPresenter()
        var confirmations = [String]()
        var toasts = [String]()
        let launcher = TellomiUIKitLauncher(
            presenter: presenter,
            inApp: inApp,
            toast: { toasts.append($0) },
            systemOpen: { url, options in system.open(url, options) },
        )
        let outcome: TellomiExternalLinkOpener.Outcome? = await withCheckedContinuation { continuation in
            var resumed = false
            func finish(_ outcome: TellomiExternalLinkOpener.Outcome?) {
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: outcome)
            }
            TellomiExternalLinkOpener.open(
                url,
                classifier: classifier,
                launcher: launcher,
                systemOpen: { _ = system.open($0, [:]) },
                confirmLookalike: { lookalike, go in
                    confirmations.append(lookalike)
                    if proceed {
                        go()
                    } else {
                        finish(nil)
                    }
                },
                completion: { finish($0) },
            )
        }
        return Run(outcome: outcome, system: system, presenter: presenter, confirmations: confirmations, toasts: toasts)
    }

    private func requireBundledRegistry() throws {
        try XCTSkipUnless(TellomiLinkRegistry.classifier.isAvailable, "随包注册表没加载")
    }

    // MARK: - 支付金融：只进显式浏览器

    func testAPaymentLinkNeverGoesToTheSystem() async throws {
        try requireBundledRegistry()
        for rawUrl in [
            "https://render.alipay.com/p/s/i/?scheme=alipays%3A%2F%2Fplatformapi%2Fstartapp",
            "https://qr.alipay.com/bax08000abcdefg",
            "https://pay.95516.com/wap/pay",
        ] {
            for route in [TellomiExternalLinkOpener.InAppRoute.handOffToSystem, .handledByCaller] {
                // 系统「愿意」接：如果哪一步把它交给了系统，就会被接走。
                let run = try await open(rawUrl, inApp: route, systemAccepts: true)
                XCTAssertEqual(run.system.calls, [], "支付链接一次都不能交给系统（通用链接会把它带进支付 App）：\(rawUrl)")
                XCTAssertEqual(run.outcome, .ran(step: "browser"), rawUrl)
                XCTAssertEqual(run.presenter.presented.count, 1, "只进显式浏览器：\(rawUrl)")
                XCTAssertTrue(run.presenter.presented.first is SFSafariViewController, rawUrl)
            }
        }
    }

    // MARK: - 第三方链接：先给已装的 App，再浏览器

    func testAnOrdinaryLinkIsOfferedToAnInstalledAppFirst() async throws {
        try requireBundledRegistry()
        let rawUrl = "https://www.wikipedia.org/wiki/Tellomi"

        let taken = try await open(rawUrl, systemAccepts: true)
        XCTAssertEqual(taken.system.calls, [.init(url: rawUrl, universalLinksOnly: true)], "只交给已装的 App，不是把网页交给 Safari")
        XCTAssertEqual(taken.outcome, .ran(step: "installed_app_only"))
        XCTAssertTrue(taken.presenter.presented.isEmpty)

        let notTaken = try await open(rawUrl, systemAccepts: false)
        XCTAssertEqual(notTaken.system.calls, [.init(url: rawUrl, universalLinksOnly: true)])
        XCTAssertEqual(notTaken.outcome, .ran(step: "browser"))
        XCTAssertTrue(notTaken.presenter.presented.first is SFSafariViewController)
    }

    func testABrandWithAnAppSchemeIsTriedAsAnAppBeforeTheBrowser() async throws {
        try requireBundledRegistry()
        let rawUrl = "https://item.taobao.com/item.htm?id=674169489573"
        let run = try await open(rawUrl, systemAccepts: false)
        XCTAssertEqual(run.system.calls.first, .init(url: rawUrl, universalLinksOnly: true))
        XCTAssertEqual(run.outcome, .ran(step: "browser"), "系统都不接的时候，最后落到显式浏览器")
        XCTAssertEqual(run.presenter.presented.count, 1)
    }

    // MARK: - 不是网页的链接：什么都不打开

    func testALinkThatIsNotWebOpensNothing() async throws {
        try requireBundledRegistry()
        for rawUrl in ["javascript:alert(1)", "intent://x#Intent;end", "data:text/html,hi", "file:///etc/passwd"] {
            let run = try await open(rawUrl, systemAccepts: true)
            XCTAssertEqual(run.outcome, .openedNothing, rawUrl)
            XCTAssertEqual(run.system.calls, [], rawUrl)
            XCTAssertTrue(run.presenter.presented.isEmpty, rawUrl)
        }
    }

    // MARK: - 仿冒域名：先问一次

    func testALookalikeAsksBeforeAnythingOpens() async throws {
        try requireBundledRegistry()
        let rawUrl = "https://www.bi1ibili.com/video/BV1YDhJ6ZEL6"

        let cancelled = try await open(rawUrl, systemAccepts: true, proceed: false)
        XCTAssertEqual(cancelled.confirmations, ["bilibili.com"])
        XCTAssertNil(cancelled.outcome)
        XCTAssertEqual(cancelled.system.calls, [], "用户没点「仍然打开」之前什么都不能打开")
        XCTAssertTrue(cancelled.presenter.presented.isEmpty)

        let proceeded = try await open(rawUrl, systemAccepts: false, proceed: true)
        XCTAssertEqual(proceeded.confirmations, ["bilibili.com"])
        XCTAssertEqual(proceeded.outcome, .ran(step: "browser"))
    }

    // MARK: - 没有注册表：照 Signal 原样

    func testWithoutARegistryTheLinkGoesToTheSystemTheWaySignalDoes() async throws {
        let rawUrl = "https://www.wikipedia.org/"
        let run = try await open(rawUrl, classifier: TellomiLinkClassifier(registry: nil), systemAccepts: true)
        XCTAssertEqual(run.outcome, .handedToSystem)
        XCTAssertEqual(run.system.calls, [.init(url: rawUrl, universalLinksOnly: false)])
        XCTAssertTrue(run.presenter.presented.isEmpty)
    }

    // MARK: - tell.cc 自己的对象（in_app 那一步）

    func testATellomiObjectIsHandedToTheSystemOnlyWhereThereIsNoTellomiRouter() async throws {
        try requireBundledRegistry()
        let rawUrl = "https://tell.cc/hk881qb"

        // 消息详情、「所有媒体」、长文本、故事：没有 Tellomi 的路由器，和这个出口出现之前一样交给系统。
        let noRouter = try await open(rawUrl, inApp: .handOffToSystem, systemAccepts: true)
        XCTAssertEqual(noRouter.system.calls, [.init(url: rawUrl, universalLinksOnly: false)])
        XCTAssertEqual(noRouter.outcome, .ran(step: "in_app"))

        // 聊天页：`handleUrl` 已经分流过了，这一步不接，往下落到复制。
        let router = try await open(rawUrl, inApp: .handledByCaller, systemAccepts: true)
        XCTAssertEqual(router.system.calls, [])
        XCTAssertEqual(router.outcome, .ran(step: "copy_link"))
        XCTAssertEqual(router.toasts.count, 1, "聊天页的提示走自己的 toast")
    }

    // MARK: - 界面上的入口

    /// 真正的入口（真的 `UIApplication`）也是一样：支付链接最后停在显式浏览器里。
    func testTheRealEntryPointEndsInTheExplicitBrowserForAPaymentLink() async throws {
        try requireBundledRegistry()
        let presenter = RecordingPresenter()
        TellomiExternalLinkOpener.open(
            try XCTUnwrap(URL(string: "https://render.alipay.com/p/s/i/")),
            from: presenter,
            inApp: .handOffToSystem,
        )
        for _ in 0..<100 where presenter.presented.isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(presenter.presented.count, 1)
        XCTAssertTrue(presenter.presented.first is SFSafariViewController)
    }

    // MARK: - 长文本里哪些数据项走计划

    func testOnlyLinksInALongTextUseTheOpenPlan() throws {
        let types: NSTextCheckingResult.CheckingType = [.link, .phoneNumber]
        let detector = try XCTUnwrap(try? NSDataDetector(types: types.rawValue))

        func items(_ text: String) -> [TextCheckingDataItem] {
            TextCheckingDataItem.detectedItems(in: text, using: detector)
        }

        let payment = try XCTUnwrap(items("请付款 https://render.alipay.com/p/s/i/ 谢谢").first)
        XCTAssertEqual(payment.dataType, .link)
        XCTAssertTrue(TellomiExternalLinkOpener.usesOpenPlan(payment))

        let bare = try XCTUnwrap(items("see www.wikipedia.org").first)
        XCTAssertEqual(bare.dataType, .link)
        XCTAssertTrue(TellomiExternalLinkOpener.usesOpenPlan(bare))

        let email = try XCTUnwrap(items("write to someone@example.com").first)
        XCTAssertEqual(email.dataType, .emailAddress)
        XCTAssertFalse(TellomiExternalLinkOpener.usesOpenPlan(email), "邮箱交给系统的邮件 App，和聊天页一样")

        let mailtoLink = try XCTUnwrap(items("mailto:someone@example.com").first)
        XCTAssertEqual(mailtoLink.dataType, .link)
        XCTAssertFalse(TellomiExternalLinkOpener.usesOpenPlan(mailtoLink), "mailto: 不是网页，不走计划（计划对它是空的，会什么都打不开）")

        let phone = try XCTUnwrap(items("call +1 415 555 0100").first)
        XCTAssertEqual(phone.dataType, .phoneNumber)
        XCTAssertFalse(TellomiExternalLinkOpener.usesOpenPlan(phone))
    }
}
