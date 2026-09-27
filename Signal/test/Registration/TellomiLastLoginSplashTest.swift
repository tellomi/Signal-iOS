//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalUI
import XCTest

@testable import Signal
@testable import SignalServiceKit

/// ADR-0072 §4.1 第 4 步：退出登录后回到欢迎页（开屏轮播照旧），上方多一块「上次登录」（头像 + 打码的手机号），
/// 点一下直接给那个号码发验证码；「换了新手机？」不再出现（那条路会覆盖这台手机上还留着的账号）。
@MainActor
final class TellomiLastLoginSplashTest: SignalBaseTest {

    private final class PresenterSpy: RegistrationSplashPresenter {
        var continueWithLastLoginCount = 0
        var continueFromSplashCount = 0

        func continueFromSplash() { continueFromSplashCount += 1 }
        func setHasOldDevice(_ hasOldDevice: Bool) {}
        func switchToDeviceLinkingMode() {}
        func tellomiContinueWithLastLogin() { continueWithLastLoginCount += 1 }
    }

    override func setUp() {
        super.setUp()
        forgetConsent()
    }

    override func tearDown() {
        forgetConsent()
        super.tearDown()
    }

    /// 同 TellomiCrossBorderNoticeTest：协议同意记在 `UserDefaults.standard`，跨境同意记在 `appUserDefaults()`。
    private func forgetConsent() {
        let defaults = CurrentAppContext().appUserDefaults()
        for key in ["TellomiCrossBorderConsent.version", "TellomiCrossBorderConsent.date", "TellomiCrossBorderConsent.linkedDeviceAcknowledgementOnly"] {
            defaults.removeObject(forKey: key)
        }
        for key in ["TellomiLegalConsent.termsAndPrivacy.version", "TellomiLegalConsent.termsAndPrivacy.date"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func allSubviews(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
    }

    private func makeSplash(lastLogin: TellomiLastLogin?) -> (RegistrationSplashViewController, PresenterSpy) {
        let presenter = PresenterSpy()
        let splash = RegistrationSplashViewController(presenter: presenter, tellomiLastLogin: lastLogin)
        splash.loadViewIfNeeded()
        splash.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        splash.view.layoutIfNeeded()
        return (splash, presenter)
    }

    private let lastLogin = TellomiLastLogin(maskedPhoneNumber: "+86 138****5678", localAddress: nil)

    private func buttonTitles(in splash: UIViewController) -> [String] {
        allSubviews(of: splash.view).compactMap { ($0 as? UIButton)?.configuration?.title }
    }

    func testLoggedOutWelcomeShowsTheLastLoginAboveTheCarousel() throws {
        let (splash, presenter) = makeSplash(lastLogin: lastLogin)
        let views = allSubviews(of: splash.view)

        let lastLoginView = try XCTUnwrap(views.compactMap { $0 as? TellomiLastLoginView }.first)
        XCTAssertEqual(lastLoginView.accessibilityIdentifier, TellomiLastLoginView.accessibilityIdentifierValue)
        XCTAssertTrue(lastLoginView.accessibilityTraits.contains(.button))
        XCTAssertEqual(
            lastLoginView.accessibilityLabel,
            "\(OWSLocalizedString("TELLOMI_LOGOUT_LAST_LOGIN_TITLE", comment: "")), +86 138****5678",
        )
        let labels = allSubviews(of: lastLoginView).compactMap { ($0 as? UILabel)?.text }
        XCTAssertTrue(labels.contains("+86 138****5678"), "只显示打码的号码：\(labels)")

        // 轮播还在，而且在「上次登录」下面。
        let carousel = try XCTUnwrap(views.compactMap { $0 as? TellomiSplashCarouselView }.first)
        let lastLoginFrame = lastLoginView.convert(lastLoginView.bounds, to: splash.view)
        let carouselFrame = carousel.convert(carousel.bounds, to: splash.view)
        XCTAssertLessThanOrEqual(lastLoginFrame.maxY, carouselFrame.minY)
        XCTAssertGreaterThan(carouselFrame.size.height, 0)

        // 点它 = 直接重新登录这个号码（注册时已经同意过协议和跨境传输）。
        TellomiLegalConsent.setAgreedToTerms(true)
        TellomiCrossBorderConsent.recordAgreement()
        lastLoginView.sendActions(for: .touchUpInside)
        XCTAssertEqual(presenter.continueWithLastLoginCount, 1)
        XCTAssertEqual(presenter.continueFromSplashCount, 0, "不经过号码页")

        // 「继续」还在（输别的号码），「换了新手机？」不在。
        let titles = buttonTitles(in: splash)
        XCTAssertTrue(titles.contains(CommonStrings.continueButton), "\(titles)")
        XCTAssertFalse(
            titles.contains(OWSLocalizedString("ONBOARDING_SPLASH_NEW_PHONE_LINK_TITLE", comment: "")),
            "\(titles)",
        )
    }

    func testFreshInstallWelcomeIsUnchanged() {
        let (splash, _) = makeSplash(lastLogin: nil)
        let views = allSubviews(of: splash.view)

        XCTAssertTrue(views.compactMap { $0 as? TellomiLastLoginView }.isEmpty)
        XCTAssertFalse(views.compactMap { $0 as? TellomiSplashCarouselView }.isEmpty)
        XCTAssertTrue(buttonTitles(in: splash).contains(OWSLocalizedString("ONBOARDING_SPLASH_NEW_PHONE_LINK_TITLE", comment: "")))
    }
}
