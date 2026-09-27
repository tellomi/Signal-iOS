//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalUI
import XCTest

@testable import Signal
@testable import SignalServiceKit

/// Tellomi（owner 2026-09-27，`docs/product/BRAND.md`「开屏」、`docs/brand/README.md`「插画」）：欢迎页换成 unDraw 插画，
/// 插画下面只放字标 Tellomi（不放任何句子），不再放「协议与隐私政策」链接；「继续」「换了新手机？」照旧。
@MainActor
final class TellomiRegistrationSplashTest: SignalBaseTest {

    private final class PresenterSpy: RegistrationSplashPresenter {
        func continueFromSplash() {}
        func setHasOldDevice(_ hasOldDevice: Bool) {}
        func switchToDeviceLinkingMode() {}
    }

    private let illustrationName = "tellomi_splash_casual_chat"
    private let wordmarkName = "tellomi_wordmark"

    private func allSubviews(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
    }

    private func makeSplash() -> (RegistrationSplashViewController, PresenterSpy) {
        let presenter = PresenterSpy()
        let splash = RegistrationSplashViewController(presenter: presenter)
        splash.loadViewIfNeeded()
        splash.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        splash.view.layoutIfNeeded()
        return (splash, presenter)
    }

    private func localized(_ key: String) -> String {
        OWSLocalizedString(key, comment: "")
    }

    func testSplashShowsOnlyTheWordmarkUnderTheIllustration() throws {
        let (splash, _) = makeSplash()
        let views = allSubviews(of: splash.view)

        let wordmark = try XCTUnwrap(
            views.compactMap { $0 as? UIImageView }.first { $0.accessibilityIdentifier == "tellomi.splash.wordmark" },
            "插画下面是字标",
        )
        XCTAssertNotNil(wordmark.image, "字标资源要在 asset catalog 里")
        XCTAssertTrue(wordmark.isAccessibilityElement)
        XCTAssertEqual(wordmark.accessibilityLabel, "Tellomi")

        let titleText = localized("ONBOARDING_SPLASH_TITLE")
        let sentences = views.compactMap { $0 as? UILabel }.filter { $0.text == titleText }
        XCTAssertTrue(sentences.isEmpty, "不放任何句子（「让隐私与您形影不离……」去掉）")
    }

    func testSplashNoLongerHasTheTermsAndPrivacyLink() {
        let (splash, _) = makeSplash()
        let linkTitle = localized("ONBOARDING_SPLASH_TERM_AND_PRIVACY_POLICY")
        let links = allSubviews(of: splash.view).compactMap { $0 as? UIButton }.filter { $0.configuration?.title == linkTitle }
        XCTAssertTrue(links.isEmpty, "「协议与隐私政策」链接去掉（首次打开的隐私提示和号码页勾选里都有）")
    }

    func testSplashKeepsContinueAndNewPhoneLink() {
        let (splash, _) = makeSplash()
        let titles = allSubviews(of: splash.view).compactMap { ($0 as? UIButton)?.configuration?.title }
        XCTAssertTrue(titles.contains(CommonStrings.continueButton), "「继续」照旧")
        XCTAssertTrue(titles.contains(localized("ONBOARDING_SPLASH_NEW_PHONE_LINK_TITLE")), "「换了新手机？」照旧")
    }

    func testSplashUsesTheUnDrawIllustrationInBothAppearances() throws {
        let (splash, _) = makeSplash()
        let illustration = try XCTUnwrap(
            allSubviews(of: splash.view).compactMap { $0 as? UIImageView }.first { $0.accessibilityIdentifier == "tellomi.splash.illustration" },
        )
        let image = try XCTUnwrap(illustration.image, "插画资源要在 asset catalog 里")
        // unDraw 的 casual-chat 是 939.746×800（横图）；上游 Signal 那张是 840×1080（竖图）。
        XCTAssertEqual(image.size.width / image.size.height, 939.746 / 800, accuracy: 0.01)

        for style in [UIUserInterfaceStyle.light, .dark] {
            XCTAssertNotNil(
                UIImage(named: illustrationName, in: .main, compatibleWith: UITraitCollection(userInterfaceStyle: style)),
                "插画要有浅色 / 深色两个外观（\(style.rawValue)）",
            )
            XCTAssertNotNil(
                UIImage(named: wordmarkName, in: .main, compatibleWith: UITraitCollection(userInterfaceStyle: style)),
                "字标要有浅色 / 深色两个外观（\(style.rawValue)）",
            )
        }
    }
}
