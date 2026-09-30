//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest
@testable import Signal
@testable import SignalServiceKit

/// ADR-0063 §4.9（tellomi/tellomi#1423）：`open_plan` 的每一步在 iOS 上的落点，在模拟器里实测系统的行为，不凭文档：
/// - `installed_app_only` 用 `.universalLinksOnly`：没有 App 认这个通用链接时返回 false，**不会**跳去 Safari；
/// - `scheme`：没装的 App 的 scheme 返回 false；
/// - `copy_link`：真的写进剪贴板；
/// - `browser`：没有展示者时什么都不做。
@MainActor
final class TellomiLinkOpenLauncherTest: XCTestCase {

    func testAUniversalLinkNobodyHandlesIsNotHandedToSafari() async throws {
        let launcher = TellomiUIKitLauncher(presenter: nil)
        let took = await launcher.installedAppOnly(try XCTUnwrap(URL(string: "https://tellomi-open-plan-test.invalid/some/path")))
        XCTAssertFalse(took, "只交给已装的 App：没有 App 认就是 false，不是打开 Safari")
    }

    func testASchemeOfAnAppThatIsNotInstalledIsNotTaken() async throws {
        let launcher = TellomiUIKitLauncher(presenter: nil)
        let took = await launcher.scheme(try XCTUnwrap(URL(string: "tellomi-open-plan-test-not-installed://item?id=1")))
        XCTAssertFalse(took)
    }

    func testCopyingPutsTheLinkOnThePasteboard() async throws {
        let launcher = TellomiUIKitLauncher(presenter: nil)
        let url = try XCTUnwrap(URL(string: "https://www.wikipedia.org/wiki/Tellomi?copied=1"))
        let took = await launcher.copyLink(url)
        XCTAssertTrue(took)
        XCTAssertEqual(UIPasteboard.general.string, url.absoluteString)
    }

    func testTheBrowserStepDoesNothingWithoutAPresenter() async throws {
        let launcher = TellomiUIKitLauncher(presenter: nil)
        let took = await launcher.browser(try XCTUnwrap(URL(string: "https://www.wikipedia.org/")))
        XCTAssertFalse(took)
    }

    func testTheTellomiRouterIsNotThisLaunchersJob() async throws {
        let launcher = TellomiUIKitLauncher(presenter: nil)
        let took = await launcher.inApp(try XCTUnwrap(URL(string: "https://tell.cc/hk881qb")))
        XCTAssertFalse(took, "tell.cc 的对象在 handleUrl 里已经走 Tellomi 自己的路由了")
    }

    /// 整条计划走一遍：没有 App 认、没有 scheme 可用 → 浏览器步骤（没有展示者，失败）→ 复制接住。
    func testAPlanFallsAllTheWayDownToCopying() async throws {
        let launcher = TellomiUIKitLauncher(presenter: nil)
        let url = "https://tellomi-open-plan-test.invalid/full-plan"
        let steps = [
            TellomiOpenPlan.Step(type: "installed_app_only", url: url),
            TellomiOpenPlan.Step(type: "browser", url: url),
            TellomiOpenPlan.Step(type: "copy_link", url: url),
        ]
        UIPasteboard.general.string = ""
        let took = await TellomiLinkOpener.run(steps: steps, launcher: launcher)
        XCTAssertEqual(took, "copy_link")
        XCTAssertEqual(UIPasteboard.general.string, url)
    }
}
