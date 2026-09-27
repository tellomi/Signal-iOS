//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit

/// Tellomi（tellomi/tellomi#1338）：跨境告知定稿（需求 `privacy-compliance-hk-cross-border.md` 第六节）。
/// - ① 告知版本改成独立的 `cb-1`：同意过草稿版 `0.1.0-draft` 的设备要再同意一次；协议与隐私政策版本常量改成 `2.0.0`。
/// - 法务项 c：已注册设备升级后的盖页，在导语上方加「隐私政策已更新至 2.0.0」和链接；新用户注册那一页不加。
/// - ④ 关联设备只出只读版：同一份 9 项、一个「知道了」，点了和同意一样在本机记下 `cb-1`、放开网络；
///   但它不是这台设备的单独同意，这台设备要是改走主设备注册，发号码之前仍要完整同意。
@MainActor
final class TellomiCrossBorderNoticeTest: SignalBaseTest {

    /// `TellomiCrossBorderConsent` 记在 `appUserDefaults()` 里的键（`AppExpiry.swift` 末尾）。
    private let versionKey = "TellomiCrossBorderConsent.version"
    private let dateKey = "TellomiCrossBorderConsent.date"
    private let linkedOnlyKey = "TellomiCrossBorderConsent.linkedDeviceAcknowledgementOnly"
    /// `TellomiLegalConsent` 记在 `UserDefaults.standard` 里的键（`RegistrationPhoneNumberViewController.swift`）。
    private let termsKey = "TellomiLegalConsent.termsAndPrivacy.version"
    private let termsDateKey = "TellomiLegalConsent.termsAndPrivacy.date"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        forgetConsent()
    }

    override func tearDown() {
        forgetConsent()
        super.tearDown()
    }

    // MARK: - Helpers

    private func forgetConsent() {
        let defaults = CurrentAppContext().appUserDefaults()
        defaults.removeObject(forKey: versionKey)
        defaults.removeObject(forKey: dateKey)
        defaults.removeObject(forKey: linkedOnlyKey)
        UserDefaults.standard.removeObject(forKey: termsKey)
        UserDefaults.standard.removeObject(forKey: termsDateKey)
    }

    private func localized(_ key: String) -> String {
        OWSLocalizedString(key, comment: "")
    }

    private func allSubviews(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
    }

    private func label(_ text: String, in view: UIView) -> UILabel? {
        allSubviews(of: view).lazy.compactMap { $0 as? UILabel }.first { $0.text == text }
    }

    private func button(identifier: String, in view: UIView) -> UIButton? {
        allSubviews(of: view).lazy.compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == identifier }
    }

    /// 按 iPhone 17 Pro 的尺寸排一次版，取某个子视图在整页里的纵坐标。
    private func layOut(_ notice: UIViewController) {
        notice.loadViewIfNeeded()
        notice.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        notice.view.setNeedsLayout()
        notice.view.layoutIfNeeded()
    }

    private func minY(of subview: UIView, in notice: UIViewController) -> CGFloat {
        subview.convert(subview.bounds, to: notice.view).minY
    }

    // MARK: - ① 版本

    func testNoticeVersionIsCb1SoDevicesThatAgreedToTheDraftAreAskedAgain() {
        XCTAssertEqual(TellomiCrossBorderConsent.noticeVersion, "cb-1", "告知版本按第六节 ① 改成独立的 cb-1")

        // 升级前同意过草稿版的设备。
        CurrentAppContext().appUserDefaults().set("0.1.0-draft", forKey: versionKey)
        XCTAssertFalse(TellomiCrossBorderConsent.hasAgreed, "同意过 0.1.0-draft 的设备要重新出这一页")

        TellomiCrossBorderConsent.recordAgreement()
        XCTAssertEqual(CurrentAppContext().appUserDefaults().string(forKey: versionKey), "cb-1")
        XCTAssertTrue(TellomiCrossBorderConsent.hasAgreed)
    }

    func testLegalDocumentsVersionIs2_0_0SoTermsAgreedAt1_0_0AreAskedAgain() {
        XCTAssertEqual(TellomiLegalConsent.documentsVersion, "2.0.0", "协议与隐私政策的版本常量按第六节 ① 改成 2.0.0")

        UserDefaults.standard.set("1.0.0", forKey: termsKey)
        XCTAssertFalse(TellomiLegalConsent.hasAgreedToTerms, "勾过 1.0.0 的，号码页的勾选框要重新变成未勾")
    }

    // MARK: - ④ 关联设备只读版

    func testLinkedDeviceAcknowledgementRecordsCb1AndLiftsTheGates() async {
        let changed = expectation(forNotification: TellomiCrossBorderConsent.didChangeNotification, object: nil)

        TellomiCrossBorderConsent.recordLinkedDeviceAcknowledgement()

        XCTAssertEqual(
            CurrentAppContext().appUserDefaults().string(forKey: versionKey),
            "cb-1",
            "「知道了」和同意一样在本机记下 cb-1",
        )
        XCTAssertNotNil(CurrentAppContext().appUserDefaults().object(forKey: dateKey), "也记下时间")
        XCTAssertTrue(TellomiCrossBorderConsent.hasAgreed, "记下之后网络闸放开")
        await fulfillment(of: [changed], timeout: 5)

        XCTAssertFalse(
            TellomiCrossBorderConsent.hasGivenSeparateConsent,
            "只读版写的是「同意在手机上取得」：这台设备改走主设备注册时，发号码之前仍要完整同意",
        )
        TellomiCrossBorderConsent.recordAgreement()
        XCTAssertTrue(TellomiCrossBorderConsent.hasGivenSeparateConsent, "之后在这台设备上点了「同意并继续」，就是单独同意")
    }

    func testAgreeingIsSeparateConsent() {
        TellomiCrossBorderConsent.recordAgreement()
        XCTAssertTrue(TellomiCrossBorderConsent.hasGivenSeparateConsent)
    }

    func testLinkedDeviceNoticeIsReadOnlyWithSingleAcknowledgeButton() throws {
        var acknowledged = 0
        let notice = TellomiCrossBorderNoticeViewController(mode: .linkedDevice, onAgree: { acknowledged += 1 })
        layOut(notice)
        let view: UIView = notice.view

        XCTAssertNotNil(label(localized("TELLOMI_CROSS_BORDER_LINKED_TITLE"), in: view), "只读版标题")
        XCTAssertNotNil(label(localized("TELLOMI_CROSS_BORDER_LINKED_INTRO"), in: view), "只读版导语")
        XCTAssertNil(label(localized("TELLOMI_CROSS_BORDER_TITLE"), in: view), "不用完整同意的标题")
        XCTAssertNil(label(localized("TELLOMI_CROSS_BORDER_INTRO"), in: view), "不用完整同意的导语")
        XCTAssertNotNil(label(localized("TELLOMI_CROSS_BORDER_ITEM_PROCEDURE_BODY"), in: view), "9 项还是同一份")
        XCTAssertNotNil(label(localized("TELLOMI_CROSS_BORDER_LINKED_ITEM_CONSENT_BODY"), in: view), "第 9 项正文换成只读版")
        XCTAssertNil(label(localized("TELLOMI_CROSS_BORDER_ITEM_CONSENT_BODY"), in: view), "不出「点同意并继续即表示…」")
        XCTAssertNil(label(localized("TELLOMI_CROSS_BORDER_POLICY_UPDATED"), in: view))
        XCTAssertNotNil(button(identifier: "tellomi.crossBorder.privacyLink", in: view))
        XCTAssertNotNil(button(identifier: "tellomi.crossBorder.thirdPartyLink", in: view))
        XCTAssertNil(button(identifier: "tellomi.crossBorder.agree", in: view), "只读版没有「同意并继续」")
        XCTAssertNil(button(identifier: "tellomi.crossBorder.disagree", in: view), "只读版没有「不同意」")

        let ack = try XCTUnwrap(button(identifier: "tellomi.crossBorder.linkedAck", in: view), "只读版唯一的按钮「知道了」")
        XCTAssertEqual(ack.configuration?.title, localized("TELLOMI_CROSS_BORDER_LINKED_ACK"))
        ack.sendActions(for: .primaryActionTriggered)

        XCTAssertEqual(acknowledged, 1)
        XCTAssertEqual(CurrentAppContext().appUserDefaults().string(forKey: versionKey), "cb-1")
        XCTAssertTrue(TellomiCrossBorderConsent.hasAgreed)
        XCTAssertFalse(TellomiCrossBorderConsent.hasGivenSeparateConsent)
    }

    // MARK: - 新用户注册：完整同意

    func testNewUserNoticeHasFullConsentAndNoPolicyUpdatedLine() throws {
        let notice = TellomiCrossBorderNoticeViewController(onAgree: {})
        layOut(notice)
        let view: UIView = notice.view

        XCTAssertNotNil(label(localized("TELLOMI_CROSS_BORDER_TITLE"), in: view))
        XCTAssertNotNil(label(localized("TELLOMI_CROSS_BORDER_INTRO"), in: view))
        XCTAssertNotNil(label(localized("TELLOMI_CROSS_BORDER_ITEM_CONSENT_BODY"), in: view))
        XCTAssertNil(label(localized("TELLOMI_CROSS_BORDER_POLICY_UPDATED"), in: view), "新用户走首次启动提示和号码页勾选，不出「已更新」")
        XCTAssertNil(button(identifier: "tellomi.crossBorder.policyUpdatedLink", in: view))
        XCTAssertNotNil(button(identifier: "tellomi.crossBorder.privacyLink", in: view))
        XCTAssertNotNil(button(identifier: "tellomi.crossBorder.thirdPartyLink", in: view), "第六节 6.3 新增的第三方清单链接")
        XCTAssertNotNil(button(identifier: "tellomi.crossBorder.disagree", in: view))
        XCTAssertNil(button(identifier: "tellomi.crossBorder.linkedAck", in: view))

        let agree = try XCTUnwrap(button(identifier: "tellomi.crossBorder.agree", in: view))
        agree.sendActions(for: .primaryActionTriggered)
        XCTAssertTrue(TellomiCrossBorderConsent.hasGivenSeparateConsent)
    }

    // MARK: - 已注册设备升级后的盖页（法务项 c）

    func testUpgradeBlockingPageShowsPolicyUpdatedAboveTheIntro() throws {
        // 走的是 WindowManager 里真的接线：盖页窗口的根就是这个工厂造的。
        let notice = WindowManager.makeCrossBorderConsentBlockingViewController()
        layOut(notice)
        let view: UIView = notice.view

        let policyUpdated = try XCTUnwrap(
            label(localized("TELLOMI_CROSS_BORDER_POLICY_UPDATED"), in: view),
            "升级盖页要有「隐私政策已更新至 2.0.0」",
        )
        let policyUpdatedLink = try XCTUnwrap(button(identifier: "tellomi.crossBorder.policyUpdatedLink", in: view))
        XCTAssertEqual(policyUpdatedLink.configuration?.title, localized("TELLOMI_CROSS_BORDER_POLICY_UPDATED_LINK"))
        let title = try XCTUnwrap(label(localized("TELLOMI_CROSS_BORDER_TITLE"), in: view))
        let intro = try XCTUnwrap(label(localized("TELLOMI_CROSS_BORDER_INTRO"), in: view))
        XCTAssertLessThan(minY(of: title, in: notice), minY(of: policyUpdated, in: notice))
        XCTAssertLessThan(minY(of: policyUpdated, in: notice), minY(of: policyUpdatedLink, in: notice))
        XCTAssertLessThan(minY(of: policyUpdatedLink, in: notice), minY(of: intro, in: notice), "放在导语上方")

        // 仍是完整同意。
        XCTAssertNotNil(button(identifier: "tellomi.crossBorder.disagree", in: view))
        XCTAssertNotNil(button(identifier: "tellomi.crossBorder.agree", in: view))
        XCTAssertNil(button(identifier: "tellomi.crossBorder.linkedAck", in: view))
    }
}
