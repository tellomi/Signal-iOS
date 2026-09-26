//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

import SignalServiceKit
@testable import Signal

class UrlOpenerTest: XCTestCase {
    func testCanOpenWhenNotRegistered() {
        // We need to be able to parse URLs before global state has been
        // initialized. There's no perfect way to test for this, but we can
        // enumerate all the different parsers we may execute & ensure that they
        // can all return a result before we've created any global state.
        let urlsToTest: [String] = [
            "https://signal.me/#p/+16505550100",
            "https://signal.art/addstickers/#pack_id=00000000000000000000000000000000&pack_key=0000000000000000000000000000000000000000000000000000000000000000",
            "sgnl://addstickers/?pack_id=00000000000000000000000000000000&pack_key=0000000000000000000000000000000000000000000000000000000000000000",
            "https://signal.group",
            "https://signal.tube/#example.com",
            "sgnl://linkdevice/?uuid=00000000-0000-4000-8000-000000000000&pub_key=BQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        ]
        for urlToTest in urlsToTest {
            XCTAssertNotNil(UrlOpener.parseUrl(URL(string: urlToTest)!), "\(urlToTest)")
        }
    }

    // MARK: - Tellomi 形状（docs/signal/LINKS_AND_SCHEMES.md；与 Android #973 同一张表）

    func testTellomiShapesParse() {
        let urlsToTest: [String] = [
            "https://tell.cc/u#p/+16505550100",
            "tellomi://tell.cc/u#p/+16505550100",
            "https://tell.cc/u#u/ceshi.57",
            "tellomi://tell.cc/u#u/ceshi.57",
            "https://tell.cc/ceshi.57",
            "tellomi://tell.cc/ceshi.57",
            "https://tell.cc/g#CjQKIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEhAAAAAAAAAAAAAAAAAAAAAA",
            "tellomi://tell.cc/g#CjQKIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEhAAAAAAAAAAAAAAAAAAAAAA",
            "https://tell.cc/s#pack_id=00000000000000000000000000000000&pack_key=0000000000000000000000000000000000000000000000000000000000000000",
            "tellomi://addstickers/?pack_id=00000000000000000000000000000000&pack_key=0000000000000000000000000000000000000000000000000000000000000000",
            "tellomi://linkdevice/?uuid=00000000-0000-4000-8000-000000000000&pub_key=BQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        ]
        for urlToTest in urlsToTest {
            XCTAssertNotNil(UrlOpener.parseUrl(URL(string: urlToTest)!), "\(urlToTest)")
        }
    }

    func testTellomiLegacyEquivalent() {
        let cases: [(String, String)] = [
            ("https://tell.cc/u#p/+16505550100", "https://signal.me/#p/+16505550100"),
            ("tellomi://tell.cc/u#eu/abc", "https://signal.me/#eu/abc"),
            ("https://tell.cc/g#xyz", "https://signal.group/#xyz"),
            ("tellomi://tell.cc/s#pack_id=1&pack_key=2", "https://signal.art/addstickers/#pack_id=1&pack_key=2"),
            ("https://tell.cc/call#key=abcd", "https://signal.link/call/#key=abcd"),
            ("tellomi://linkdevice/?uuid=1&pub_key=2", "sgnl://linkdevice/?uuid=1&pub_key=2"),
            ("tellomicaptcha://turnstile.k.registration.t", "signalcaptcha://turnstile.k.registration.t"),
            // 不是 Tellomi 形状的原样返回
            ("https://signal.me/#p/+16505550100", "https://signal.me/#p/+16505550100"),
            ("sgnl://linkdevice/?uuid=1", "sgnl://linkdevice/?uuid=1"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(TellomiLinks.legacyEquivalent(of: URL(string: input)!).absoluteString, expected, input)
        }
        XCTAssertEqual(TellomiLinks.plainUsername(in: URL(string: "https://tell.cc/u#u/ceshi.57")!), "ceshi.57")
        XCTAssertEqual(TellomiLinks.plainUsername(in: URL(string: "tellomi://tell.cc/u/#u/linktest.56")!), "linktest.56")
        // 裸形状（与 Android 对齐）：tell.cc/<username>，保留字路径不算
        XCTAssertEqual(TellomiLinks.plainUsername(in: URL(string: "https://tell.cc/ceshi.57")!), "ceshi.57")
        XCTAssertEqual(TellomiLinks.plainUsername(in: URL(string: "tellomi://tell.cc/linktest.56/")!), "linktest.56")
        XCTAssertNil(TellomiLinks.plainUsername(in: URL(string: "https://tell.cc/u")!))
        XCTAssertNil(TellomiLinks.plainUsername(in: URL(string: "https://tell.cc/call#key=abc")!))
        // tellomi/tellomi#1106（ADR-0066）：不带「.数字」的也认，返回补上 `.01` 的完整用户名
        XCTAssertEqual(TellomiLinks.plainUsername(in: URL(string: "https://tell.cc/kaixin")!), "kaixin.01")
        XCTAssertEqual(TellomiLinks.plainUsername(in: URL(string: "https://tell.cc/kaixin?from=wechat")!), "kaixin.01")
        XCTAssertEqual(TellomiLinks.plainUsername(in: URL(string: "tellomi://tell.cc/kaixin/")!), "kaixin.01")
        XCTAssertEqual(TellomiLinks.plainUsername(in: URL(string: "tellomi://tell.cc/u#u/kaixin")!), "kaixin.01")
        XCTAssertEqual(TellomiLinks.plainUsername(in: URL(string: "https://tell.cc/kaixin.01")!), "kaixin.01")
        // 3 位以上的保留路径显式挡（大小写不敏感）；两位名、数字开头不是用户名
        XCTAssertNil(TellomiLinks.plainUsername(in: URL(string: "https://tell.cc/app")!))
        XCTAssertNil(TellomiLinks.plainUsername(in: URL(string: "https://tell.cc/CALL")!))
        XCTAssertNil(TellomiLinks.plainUsername(in: URL(string: "https://tell.cc/ab")!))
        XCTAssertNil(TellomiLinks.plainUsername(in: URL(string: "https://tell.cc/1abc")!))
        XCTAssertNil(TellomiLinks.plainUsername(in: URL(string: "https://tell.cc/u#p/+16505550100")!))
        XCTAssertNil(TellomiLinks.plainUsername(in: URL(string: "https://tell.cc/g#u/notauser")!))
        // tell.cc/u#p/… 不能被当成群邀请（Android #973 撞过的坑）
        XCTAssertNil(PossibleGroupInviteLinkUrl.parseFrom(TellomiLinks.legacyEquivalent(of: URL(string: "https://tell.cc/u#p/+16505550100")!)))
    }

    /// tellomi/tellomi#1106（ADR-0066）：找人页 / 联系人搜索把输入的名字补成协议层的完整用户名（与 Android `TellomiUsernamesTest` 同一组）。
    func testTellomiProtocolUsername() {
        XCTAssertEqual(TellomiLinks.protocolUsername("kaixin"), "kaixin.01")
        XCTAssertEqual(TellomiLinks.protocolUsername("@kaixin"), "kaixin.01")
        XCTAssertEqual(TellomiLinks.protocolUsername("  kaixin \n"), "kaixin.01")
        // 旧账号带随机后缀：原样保留，按全名去查
        XCTAssertEqual(TellomiLinks.protocolUsername("kaixin.57"), "kaixin.57")
        XCTAssertEqual(TellomiLinks.protocolUsername(" @kaixin.57 "), "kaixin.57")
        XCTAssertEqual(TellomiLinks.protocolUsername("kaixin.01"), "kaixin.01")
    }

    /// tellomi/tellomi#1106 第四刀（ADR-0066 §6.2）：一小时是改名冷却与限流的分界线；天数向上取整、至少 1（与 Android、Desktop 同一组）。
    func testTellomiRenameCooldown() {
        XCTAssertFalse(TellomiLinks.isRenameCooldown(retryAfter: 9))
        XCTAssertFalse(TellomiLinks.isRenameCooldown(retryAfter: 3600))
        XCTAssertTrue(TellomiLinks.isRenameCooldown(retryAfter: 3601))
        XCTAssertTrue(TellomiLinks.isRenameCooldown(retryAfter: 2_591_999))
        XCTAssertEqual(TellomiLinks.renameCooldownDaysLeft(retryAfter: 2_591_999), 30)
        XCTAssertEqual(TellomiLinks.renameCooldownDaysLeft(retryAfter: 86400), 1)
        XCTAssertEqual(TellomiLinks.renameCooldownDaysLeft(retryAfter: 86401), 2)
        XCTAssertEqual(TellomiLinks.renameCooldownDaysLeft(retryAfter: 7200), 1)
    }

    /// tellomi/tellomi#1106 第四刀：两条复数文案必须在 `PluralAware.stringsdict` 的**顶层**。
    /// 嵌进上一条的 dict 里时 `plutil -lint` 照样通过，运行时却查不到键、界面上直接显示键名（taishi 审查 2026-09-24）。
    /// 四种语言各查一遍：测试进程只跑英文，只查当前语言会漏掉中文三份。
    func testTellomiRenameCooldownPluralStringsResolveInEveryLocale() throws {
        let keys = [
            "USERNAME_SELECTION_CHANGE_COOLDOWN_ERROR_MESSAGE_TELLOMI_%d",
            "USERNAME_SELECTION_CHANGE_USERNAME_CONFIRMATION_MESSAGE_TELLOMI_%d",
        ]
        for localization in ["en", "zh_CN", "zh_HK", "zh_TW"] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: localization, ofType: "lproj"), localization)
            let bundle = try XCTUnwrap(Bundle(path: path), localization)
            for key in keys {
                let format = bundle.localizedString(forKey: key, value: nil, table: "PluralAware")
                XCTAssertNotEqual(format, key, "\(localization): \(key)")
                XCTAssertTrue(String.localizedStringWithFormat(format, 30).contains("30"), "\(localization): \(key)")
            }
        }
    }

    /// Tellomi（ADR-0066 §6.2）：删除框和「删后再设」确认框的两条复数文案，四种语言都要在顶层查得到，参数位置也要对：
    /// 第 1 个参数是改名冷却天数（决定单复数），用户名、保留天数按位置取。冷却天数故意给 7、保留天数给 30，位置错了就看得出来。
    /// 删除框最后那句通用提示（owner 2026-09-24 晚第 9 条）用的也是冷却天数，三端逐字一致。
    func testTellomiUsernameHoldStringsResolveInEveryLocale() throws {
        let deleteKey = "PROFILE_SETTINGS_USERNAME_DELETION_CONFIRMATION_ALERT_MESSAGE_TELLOMI_%d_%@_%d"
        let setAfterDeleteKey = "USERNAME_SELECTION_SET_AFTER_DELETE_CONFIRMATION_MESSAGE_TELLOMI_%d_%d"
        let expected: [String: (delete: String, setAfterDelete: String)] = [
            "en": (
                "This will remove your username and disable your QR code and link. “kaixin” stays reserved for you for 30 days; if you set a username during that time, you won’t be able to change it again for 7 days. If you changed your username in the last 7 days, you can only change back to your original username after deleting it. Are you sure?",
                "You deleted your username less than 30 days ago, so setting one now counts as a change: you won’t be able to change it again for 7 days. Are you sure?",
            ),
            "zh_CN": (
                "这样做将会删除你的用户名，并使你的二维码和链接失效。“kaixin”会为你保留 30 天；这期间再设置用户名，之后 7 天内不能再改。如果你 7 天内改过用户名，删除后只能改回原来的名字。确定要删除吗？",
                "你在 30 天内删除过用户名，现在设置也算一次更改：之后 7 天内不能再改。确定要继续吗？",
            ),
            "zh_HK": (
                "這將刪除你的用戶名稱及停用你的二維碼和連結。「kaixin」會為你保留 30 天；這期間再設定用戶名稱，之後 7 天內不能再更改。如果你 7 天內改過用戶名稱，刪除後只能改回原來的名稱。你確定嗎？",
                "你在 30 天內刪除過用戶名稱，現在設定也算一次更改：之後 7 天內不能再更改。你確定嗎？",
            ),
            "zh_TW": (
                "這將刪除你的用戶名稱及停用你的二維碼和連結。「kaixin」會為你保留 30 天；這期間再設定用戶名稱，之後 7 天內不能再更改。如果你 7 天內改過用戶名稱，刪除後只能改回原來的名稱。你確定嗎？",
                "你在 30 天內刪除過用戶名稱，現在設定也算一次更改：之後 7 天內不能再更改。你確定嗎？",
            ),
        ]
        for (localization, texts) in expected {
            let path = try XCTUnwrap(Bundle.main.path(forResource: localization, ofType: "lproj"), localization)
            let bundle = try XCTUnwrap(Bundle(path: path), localization)
            let deleteFormat = bundle.localizedString(forKey: deleteKey, value: nil, table: "PluralAware")
            XCTAssertEqual(String.localizedStringWithFormat(deleteFormat, 7, "kaixin", 30), texts.delete, localization)
            let setAfterDeleteFormat = bundle.localizedString(forKey: setAfterDeleteKey, value: nil, table: "PluralAware")
            XCTAssertEqual(String.localizedStringWithFormat(setAfterDeleteFormat, 7, 30), texts.setAfterDelete, localization)
        }

        // 英文单数：冷却 1 天时是「1 day」
        let enPath = try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj"))
        let en = try XCTUnwrap(Bundle(path: enPath))
        XCTAssertTrue(
            String.localizedStringWithFormat(en.localizedString(forKey: setAfterDeleteKey, value: nil, table: "PluralAware"), 1, 30)
                .hasSuffix("you won’t be able to change it again for 1 day. Are you sure?"),
        )
    }

    /// owner 2026-09-25 在 TestFlight 上撞到：冷却期里换名被拒时，只说「N 天后可以再改」不够，还要说清这段时间只能改回原来的名字
    /// （服务端 ADR-0066 §6.2 冷却期只放行本账号保留期内的旧名）。四种语言逐字钉住，与 Android a21 同句。
    func testTellomiRenameCooldownErrorSaysOnlyTheOriginalNameCanComeBack() throws {
        let key = "USERNAME_SELECTION_CHANGE_COOLDOWN_ERROR_MESSAGE_TELLOMI_%d"
        let expected: [(String, Int, String)] = [
            ("en", 29, "You changed your username recently. You can change it again in 29 days. Until then, you can only change back to your original username."),
            ("en", 1, "You changed your username recently. You can change it again in 1 day. Until then, you can only change back to your original username."),
            ("zh_CN", 29, "你最近改过用户名，29 天后可以再改。在那之前，只能改回原来的名字。"),
            ("zh_HK", 29, "你最近更改過用戶名稱，29 天後可以再更改。在那之前，只能改回原來的名稱。"),
            ("zh_TW", 29, "你最近更改過用戶名稱，29 天後可以再更改。在那之前，只能改回原來的名稱。"),
        ]
        for (localization, days, text) in expected {
            let path = try XCTUnwrap(Bundle.main.path(forResource: localization, ofType: "lproj"), localization)
            let bundle = try XCTUnwrap(Bundle(path: path), localization)
            let format = bundle.localizedString(forKey: key, value: nil, table: "PluralAware")
            XCTAssertEqual(String.localizedStringWithFormat(format, days), text, localization)
        }
    }

    /// tellomi/tellomi#1106 第二刀：选用户名页「没改 / 只改大小写」的捷径只认原判别位是 01 的；`.57` 这类旧号同名也要重新预约 `.01`。
    func testTellomiUsernameShortcutsOnlyForFixedDiscriminator() {
        let fixed = Usernames.ParsedUsername(rawUsername: "kaixin.01")
        XCTAssertNotNil(fixed)
        XCTAssertEqual(UsernameSelectionViewController.existingUsernameForShortcuts(fixed), fixed)
        XCTAssertNil(UsernameSelectionViewController.existingUsernameForShortcuts(Usernames.ParsedUsername(rawUsername: "kaixin.57")))
        XCTAssertNil(UsernameSelectionViewController.existingUsernameForShortcuts(nil))
    }

    /// tellomi/tellomi#1181（ADR-0066 §六）：选名页输入框的上限取「新名字上限」与「现有昵称长度」中较大的，
    /// 上限改成 20 之前建的 21–32 位用户名才能改大小写、逐个删字。
    func testTellomiNicknameInputKeepsLongExistingNamesEditable() throws {
        typealias VC = UsernameSelectionViewController
        let long = "abcdefghijklmnopqrstuvwxy" // 25 位
        XCTAssertEqual(VC.tellomiMaxNicknameInputLength(existingUsername: nil, configuredMax: 20), 20)
        XCTAssertEqual(VC.tellomiMaxNicknameInputLength(existingUsername: Usernames.ParsedUsername(rawUsername: "kaixin.01"), configuredMax: 20), 20)
        XCTAssertEqual(VC.tellomiMaxNicknameInputLength(existingUsername: Usernames.ParsedUsername(rawUsername: "\(long).01"), configuredMax: 20), 25)
        XCTAssertEqual(VC.tellomiMaxNicknameInputLength(existingUsername: Usernames.ParsedUsername(rawUsername: "\(long).57"), configuredMax: 20), 25)

        // 按这个上限，25 位的名字能把首字母改成大写、能删掉一个字；按旧的 20 位上限两样都被拒
        let limit = VC.tellomiMaxNicknameInputLength(existingUsername: Usernames.ParsedUsername(rawUsername: "\(long).01"), configuredMax: 20)
        let capitalize = TextHelper.shouldChangeCharactersInRange(with: long, editingRange: NSRange(location: 0, length: 1), replacementString: "A", maxUnicodeScalarCount: limit)
        XCTAssertTrue(capitalize.shouldChange)
        let deleteOne = TextHelper.shouldChangeCharactersInRange(with: long, editingRange: NSRange(location: 24, length: 1), replacementString: "", maxUnicodeScalarCount: limit)
        XCTAssertTrue(deleteOne.shouldChange)
        XCTAssertFalse(TextHelper.shouldChangeCharactersInRange(with: long, editingRange: NSRange(location: 0, length: 1), replacementString: "A", maxUnicodeScalarCount: 20).shouldChange)
        XCTAssertFalse(TextHelper.shouldChangeCharactersInRange(with: long, editingRange: NSRange(location: 24, length: 1), replacementString: "", maxUnicodeScalarCount: 20).shouldChange)
        // 比现有昵称更长的照旧拦
        XCTAssertFalse(TextHelper.shouldChangeCharactersInRange(with: long, editingRange: NSRange(location: 25, length: 0), replacementString: "z", maxUnicodeScalarCount: limit).shouldChange)
    }

    /// tellomi/tellomi#1181：上限放宽之后，删掉一个字得到的 24 位新名字在 libsignal 本地就判「太长」——`.tooLong` 走得到了，
    /// 所以那一支必须给文案，不能再是上游的 owsFail（正式包也闪退）。
    func testTellomiLongNewNameGetsATooLongMessageInsteadOfACrash() throws {
        let long = "abcdefghijklmnopqrstuvwxy" // 25 位
        XCTAssertThrowsError(try Usernames.HashedUsername.generateCandidates(
            forNickname: String(long.dropLast()),
            minNicknameLength: 3,
            maxNicknameLength: 20,
            desiredDiscriminator: nil,
            enforcingLetterFirst: true,
        )) { error in
            XCTAssertEqual(error as? Usernames.HashedUsername.CandidateGenerationError, .nicknameTooLong)
        }

        let key = "USERNAME_SELECTION_TOO_LONG_ERROR_MESSAGE_TELLOMI_%d"
        for localization in ["en", "zh_CN", "zh_HK", "zh_TW"] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: localization, ofType: "lproj"), localization)
            let bundle = try XCTUnwrap(Bundle(path: path), localization)
            let format = bundle.localizedString(forKey: key, value: nil, table: "PluralAware")
            XCTAssertNotEqual(format, key, localization)
            XCTAssertTrue(String.localizedStringWithFormat(format, 20).contains("20"), localization)
        }
        // 选名页实际用的那句（测试按 -testLanguage en 跑）；键名写错时 OWSLocalizedString 会原样返回键名，格式化后也「含 20」，所以要逐字比
        XCTAssertEqual(UsernameSelectionViewController.tellomiTooLongErrorText(maxNicknameLength: 20), "Usernames must have at most 20 characters.")
        XCTAssertEqual(UsernameSelectionViewController.tellomiTooLongErrorText(maxNicknameLength: 1), "Usernames must have at most 1 character.")
    }

    /// tellomi/tellomi#1106（ADR-0066 §六「显示」）：只有 `.01` 结尾的去掉后缀，别的后缀完整显示（与 Android `TellomiUsernamesTest` 同一组）。
    func testTellomiDisplayUsername() {
        XCTAssertEqual(TellomiLinks.displayUsername("kaixin.01"), "kaixin")
        XCTAssertEqual(TellomiLinks.displayUsername("KaiXin.01"), "KaiXin")
        // 反向：别的后缀原样——`kaixin.57` 不能显示成 `kaixin`
        XCTAssertEqual(TellomiLinks.displayUsername("kaixin.57"), "kaixin.57")
        XCTAssertEqual(TellomiLinks.displayUsername("kaixin.101"), "kaixin.101")
        XCTAssertEqual(TellomiLinks.displayUsername("kaixin.001"), "kaixin.001")
    }
}
