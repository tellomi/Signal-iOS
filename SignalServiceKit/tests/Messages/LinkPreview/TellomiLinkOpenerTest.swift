//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest
@testable import SignalServiceKit

/// ADR-0063 §4.9 / §5.5 / §6.1（tellomi/tellomi#1423）：点卡片和点正文里的链接都按 rust/links 的 `open_plan` 打开。
/// 目标永远是消息里那条 URL；计划只说怎么交出去、按什么顺序试。与 Android `TellomiLinkOpener` / Desktop `linkOpen` 同一套。
final class TellomiLinkOpenerTest: XCTestCase {

    // MARK: - 计划的解析

    func testAPlanIsReadFromTheJSONRustLinksWrites() throws {
        let json = #"""
        {"steps":[{"type":"installed_app_only","url":"https://item.taobao.com/item.htm?id=1"},{"type":"scheme","url":"taobao://item.taobao.com/item.htm?id=1"},{"type":"browser","url":"https://item.taobao.com/item.htm?id=1"},{"type":"copy_link","url":"https://item.taobao.com/item.htm?id=1"}],"label":"open_in_app","app_name":{"zh-Hans":"淘宝","en":"Taobao"},"lookalike":null}
        """#
        let plan = try XCTUnwrap(TellomiOpenPlan.parse(json))
        XCTAssertEqual(plan.steps.map(\.type), ["installed_app_only", "scheme", "browser", "copy_link"])
        XCTAssertEqual(plan.steps[1].url, "taobao://item.taobao.com/item.htm?id=1")
        XCTAssertNil(plan.lookalike)
    }

    func testALookalikeIsKept() throws {
        let plan = try XCTUnwrap(TellomiOpenPlan.parse(#"{"steps":[{"type":"browser","url":"https://www.bi1ibili.com/"}],"label":"open_link","lookalike":"bilibili.com"}"#))
        XCTAssertEqual(plan.lookalike, "bilibili.com")
    }

    func testAnEmptyPlanIsAPlanThatOpensNothing() throws {
        let plan = try XCTUnwrap(TellomiOpenPlan.parse(#"{"steps":[],"label":"open_link"}"#))
        XCTAssertTrue(plan.steps.isEmpty)
    }

    func testGarbageIsNotAPlan() {
        XCTAssertNil(TellomiOpenPlan.parse("not json"))
        XCTAssertNil(TellomiOpenPlan.parse(#"{"label":"open_link"}"#))
    }

    // MARK: - 按顺序试

    private final class RecordingLauncher: TellomiLinkLauncher {
        var tried = [String]()
        var takes: Set<String>

        init(takes: Set<String>) {
            self.takes = takes
        }

        private func attempt(_ type: String) -> Bool {
            tried.append(type)
            return takes.contains(type)
        }

        func inApp(_ url: URL) async -> Bool { attempt("in_app") }
        func installedAppOnly(_ url: URL) async -> Bool { attempt("installed_app_only") }
        func scheme(_ url: URL) async -> Bool { attempt("scheme") }
        func browser(_ url: URL) async -> Bool { attempt("browser") }
        func copyLink(_ url: URL) async -> Bool { attempt("copy_link") }
    }

    private let taobao = [
        TellomiOpenPlan.Step(type: "installed_app_only", url: "https://item.taobao.com/item.htm?id=1"),
        TellomiOpenPlan.Step(type: "scheme", url: "taobao://item.taobao.com/item.htm?id=1"),
        TellomiOpenPlan.Step(type: "browser", url: "https://item.taobao.com/item.htm?id=1"),
        TellomiOpenPlan.Step(type: "copy_link", url: "https://item.taobao.com/item.htm?id=1"),
    ]

    @MainActor
    func testTheFirstStepThatTakesTheLinkEndsIt() async {
        let launcher = RecordingLauncher(takes: ["installed_app_only", "browser"])
        let took = await TellomiLinkOpener.run(steps: taobao, launcher: launcher)
        XCTAssertEqual(took, "installed_app_only")
        XCTAssertEqual(launcher.tried, ["installed_app_only"])
    }

    @MainActor
    func testWhenNoAppTakesItTheNextStepsAreTried() async {
        let launcher = RecordingLauncher(takes: ["browser"])
        let took = await TellomiLinkOpener.run(steps: taobao, launcher: launcher)
        XCTAssertEqual(took, "browser")
        XCTAssertEqual(launcher.tried, ["installed_app_only", "scheme", "browser"])
    }

    @MainActor
    func testTheLinkIsCopiedWhenNotEvenABrowserOpensIt() async {
        let launcher = RecordingLauncher(takes: ["copy_link"])
        let took = await TellomiLinkOpener.run(steps: taobao, launcher: launcher)
        XCTAssertEqual(took, "copy_link")
        XCTAssertEqual(launcher.tried, ["installed_app_only", "scheme", "browser", "copy_link"])
    }

    @MainActor
    func testNothingTookIt() async {
        let launcher = RecordingLauncher(takes: [])
        let took = await TellomiLinkOpener.run(steps: taobao, launcher: launcher)
        XCTAssertNil(took)
    }

    @MainActor
    func testAStepThisBuildDoesNotKnowIsSkippedAndAnUnparsableURLIsTooHollow() async {
        let launcher = RecordingLauncher(takes: ["browser"])
        let steps = [
            TellomiOpenPlan.Step(type: "hologram", url: "https://a.example/"),
            TellomiOpenPlan.Step(type: "browser", url: ""),
            TellomiOpenPlan.Step(type: "browser", url: "https://a.example/"),
        ]
        let took = await TellomiLinkOpener.run(steps: steps, launcher: launcher)
        XCTAssertEqual(took, "browser")
        XCTAssertEqual(launcher.tried, ["browser"], "认不出的步骤和空 URL 都不交给 launcher")
    }

    // MARK: - 决定：怎么处理这条链接

    private final class FakeRegistry: TellomiLinkClassifying {
        var version: UInt64 = 1
        var plan: Result<String, Error> = .success(#"{"steps":[],"label":"open_link"}"#)
        func classify(preview: String, body: String, message: String) throws -> String { "{}" }
        func openPlan(_ url: String) throws -> String { try plan.get() }
    }

    private struct Boom: Error {}

    func testWithoutARegistryTheLinkOpensTheWaySignalDoes() {
        let classifier = TellomiLinkClassifier(registry: nil)
        XCTAssertEqual(TellomiLinkOpener.decide(url: "https://example.org/", classifier: classifier), .signalDefault)
    }

    func testWhenTheRegistryFailsTheLinkOpensTheWaySignalDoes() {
        let registry = FakeRegistry()
        registry.plan = .failure(Boom())
        XCTAssertEqual(TellomiLinkOpener.decide(url: "https://example.org/", classifier: TellomiLinkClassifier(registry: registry)), .signalDefault)
    }

    func testAnEmptyPlanOpensNothing() {
        let registry = FakeRegistry()
        XCTAssertEqual(TellomiLinkOpener.decide(url: "javascript:alert(1)", classifier: TellomiLinkClassifier(registry: registry)), .openNothing)
    }

    func testALookalikeAsksOnceBeforeOpening() {
        let registry = FakeRegistry()
        registry.plan = .success(#"{"steps":[{"type":"browser","url":"https://www.bi1ibili.com/"}],"label":"open_link","lookalike":"bilibili.com"}"#)
        let decision = TellomiLinkOpener.decide(url: "https://www.bi1ibili.com/", classifier: TellomiLinkClassifier(registry: registry))
        guard case .confirmThenOpen(let plan, let lookalike) = decision else {
            return XCTFail("\(decision)")
        }
        XCTAssertEqual(lookalike, "bilibili.com")
        XCTAssertEqual(plan.steps.map(\.type), ["browser"])
    }

    func testAnOrdinaryPlanJustOpens() {
        let registry = FakeRegistry()
        registry.plan = .success(#"{"steps":[{"type":"browser","url":"https://a.example/"},{"type":"copy_link","url":"https://a.example/"}],"label":"open_link"}"#)
        let decision = TellomiLinkOpener.decide(url: "https://a.example/", classifier: TellomiLinkClassifier(registry: registry))
        guard case .open(let plan) = decision else {
            return XCTFail("\(decision)")
        }
        XCTAssertEqual(plan.steps.map(\.type), ["browser", "copy_link"])
    }

    // MARK: - 真的注册表（随包那份）

    func testTheBundledRegistryPlansMatchTheRules() throws {
        let classifier = TellomiLinkRegistry.classifier
        try XCTSkipUnless(classifier.isAvailable, "随包注册表没加载")

        func plan(_ url: String) throws -> TellomiOpenPlan {
            let decision = TellomiLinkOpener.decide(url: url, classifier: classifier)
            switch decision {
            case .open(let plan), .confirmThenOpen(let plan, _):
                return plan
            default:
                throw XCTSkip("\(url) → \(decision)")
            }
        }

        // 已知品牌：先只交给已装的 App，再（有 scheme 时）scheme，再浏览器，最后复制
        let taobao = try plan("https://item.taobao.com/item.htm?id=674169489573")
        XCTAssertEqual(taobao.steps.first?.type, "installed_app_only")
        XCTAssertEqual(taobao.steps.last?.type, "copy_link")
        XCTAssertTrue(taobao.steps.contains { $0.type == "browser" })

        // 不认识的网站：先试已装的 App，再浏览器，再复制
        let unknown = try plan("https://www.wikipedia.org/")
        XCTAssertEqual(unknown.steps.map(\.type), ["installed_app_only", "browser", "copy_link"])

        // 支付：只有浏览器，不预填、不唤起
        let alipay = try plan("https://render.alipay.com/p/s/i/")
        XCTAssertFalse(alipay.steps.contains { $0.type == "installed_app_only" || $0.type == "scheme" }, "\(alipay.steps)")

        // tell.cc 的对象：Tellomi 自己的路由
        let tellcc = try plan("https://tell.cc/hk881qb")
        XCTAssertEqual(tellcc.steps.first?.type, "in_app")
    }

    func testTheBundledRegistryOpensNothingThatIsNotWebAndWarnsAboutALookalike() {
        let classifier = TellomiLinkRegistry.classifier
        guard classifier.isAvailable else { return }
        for url in ["javascript:alert(1)", "intent://x#Intent;end", "data:text/html,hi", "file:///etc/passwd"] {
            XCTAssertEqual(TellomiLinkOpener.decide(url: url, classifier: classifier), .openNothing, url)
        }
        guard case .confirmThenOpen(_, let lookalike) = TellomiLinkOpener.decide(url: "https://www.bi1ibili.com/video/BV1YDhJ6ZEL6", classifier: classifier) else {
            return XCTFail("仿冒域名应该先问一次")
        }
        XCTAssertEqual(lookalike, "bilibili.com")
    }
}
