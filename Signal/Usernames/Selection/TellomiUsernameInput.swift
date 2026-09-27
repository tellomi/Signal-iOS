//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

/// Tellomi（ADR-0066 §6.1b，owner 2026-09-27「填写用户名的时候就强制要求并且友好提示只允许小写」）：用户名一律小写。
/// 注册资料页的「用户名（选填）」和设置里的选用户名页（设置 / 修改 / 拿回旧名都是这一页）共用，与 Android、Desktop 同一套：
/// 1. 输入框下面常驻一行灰色规则提示（`RuleHintView`）；
/// 2. 打了或粘贴了大写字母：当场转成小写，光标不跳；规则提示那一行换成「已自动转成小写」约 2 秒（不用红色），然后恢复；
/// 3. 别的不合规字符（空格、中文、减号、点……）这里一个不动，照旧由各页的本地规则就地报红字，不自动删。
///
/// 只转 ASCII 的 A–Z（`TellomiLinks.lowercasedUsername`）：用户名只认 `a-z 0-9 _`，`İ`、全角 `Ａ` 转了也不合规，留给红字去说。
enum TellomiUsernameInput {

    static var ruleHint: String {
        return OWSLocalizedString(
            "USERNAME_SELECTION_RULE_HINT_TELLOMI",
            comment: "Tellomi: permanent grey hint below every username text field (registration profile and the username settings screen). Usernames are lowercase only.",
        )
    }

    static var autoLowercasedNotice: String {
        return OWSLocalizedString(
            "USERNAME_SELECTION_AUTO_LOWERCASED_TELLOMI",
            comment: "Tellomi: shown for about 2 seconds in place of the username rule hint, right after uppercase letters the user typed or pasted into the username field were changed to lowercase. Not an error.",
        )
    }

    enum Edit: Equatable {
        /// 这次改动里没有大写字母：交给页面照常处理。
        case passThrough
        /// 有大写，但已经到长度上限、一个字也放不进去（和上游对超长单字符输入的处理一样）。
        case rejected
        /// 有大写：框里的字换成 `text`，光标放在 `cursorOffset`（UTF-16 偏移，和 `UITextField` 的位置一致）。
        case lowercased(text: String, cursorOffset: Int)
    }

    /// `textField(_:shouldChangeCharactersIn:replacementString:)` 的纯函数部分。`maxUnicodeScalarCount` 为 nil 时不限长度；
    /// 有上限时照上游 `TextHelper` 的规矩：打字超长不收，粘贴超长收下放得下的前一段。光标落在插入的字后面。
    static func edit(text: String?, range: NSRange, replacement: String, maxUnicodeScalarCount: Int?) -> Edit {
        guard TellomiLinks.containsUppercaseAsciiLetter(replacement) else {
            return .passThrough
        }
        let existing = (text ?? "") as NSString
        let lowercased = TellomiLinks.lowercasedUsername(replacement)

        if let maxUnicodeScalarCount {
            let (shouldChange, changedString) = TextHelper.shouldChangeCharactersInRange(
                with: existing as String,
                editingRange: range,
                replacementString: lowercased,
                maxUnicodeScalarCount: maxUnicodeScalarCount,
            )
            if !shouldChange {
                guard let changedString else {
                    return .rejected
                }
                // 粘贴被截短：收下的是 `lowercased` 的前一段，光标放在收下的那段后面
                let acceptedLength = (changedString as NSString).length - (existing.length - range.length)
                return .lowercased(text: changedString, cursorOffset: range.location + acceptedLength)
            }
        }

        return .lowercased(
            text: existing.replacingCharacters(in: range, with: lowercased),
            cursorOffset: range.location + (lowercased as NSString).length,
        )
    }

    /// 页面的 `shouldChangeCharactersIn` 最先调它。返回 nil：这次没有大写（或输入法还在拼），页面照常处理；
    /// 否则就是代理方法该返回的值——框里的字已经换好、光标已放好、`.editingChanged` 已发出，规则提示已换成「已自动转成小写」。
    @MainActor
    static func handleChange(
        in textField: UITextField,
        range: NSRange,
        replacement: String,
        maxUnicodeScalarCount: Int?,
        hintView: RuleHintView,
    ) -> Bool? {
        // 中文 / 日文输入法拼写中（marked text）不打断；上屏之后的兜底见 `lowercaseInPlace`
        guard textField.markedTextRange == nil else {
            return nil
        }
        switch edit(text: textField.text, range: range, replacement: replacement, maxUnicodeScalarCount: maxUnicodeScalarCount) {
        case .passThrough:
            return nil
        case .rejected:
            return false
        case let .lowercased(text, cursorOffset):
            textField.text = text
            setSelection(of: textField, from: cursorOffset, to: cursorOffset)
            hintView.showAutoLowercasedNotice()
            textField.sendActions(for: .editingChanged)
            return false
        }
    }

    /// 兜底：没经过 `shouldChangeCharactersIn` 就进了框的大写（钥匙串自动填充、输入法上屏……）。在 `.editingChanged` 处理的最前面调。
    /// ASCII 转小写不改变长度，选区原样放回。转了返回 true。
    @MainActor
    @discardableResult
    static func lowercaseInPlace(_ textField: UITextField, hintView: RuleHintView) -> Bool {
        guard
            textField.markedTextRange == nil,
            let text = textField.text,
            TellomiLinks.containsUppercaseAsciiLetter(text)
        else {
            return false
        }
        let selection = textField.selectedTextRange.map {
            (
                start: textField.offset(from: textField.beginningOfDocument, to: $0.start),
                end: textField.offset(from: textField.beginningOfDocument, to: $0.end),
            )
        }
        textField.text = TellomiLinks.lowercasedUsername(text)
        if let selection {
            setSelection(of: textField, from: selection.start, to: selection.end)
        }
        hintView.showAutoLowercasedNotice()
        return true
    }

    @MainActor
    private static func setSelection(of textField: UITextField, from startOffset: Int, to endOffset: Int) {
        guard
            let start = textField.position(from: textField.beginningOfDocument, offset: startOffset),
            let end = textField.position(from: textField.beginningOfDocument, offset: endOffset)
        else {
            return
        }
        textField.selectedTextRange = textField.textRange(from: start, to: end)
    }

    /// 输入框下面那行灰色规则提示。「已自动转成小写」叠在规则上面、规则只是隐去，所以两句长短不同（英文规则两行）界面也不跳。
    final class RuleHintView: UIView {

        private let ruleLabel = UILabel()
        private let noticeLabel = UILabel()
        private let noticeDuration: TimeInterval
        private var restoreWorkItem: DispatchWorkItem?

        private(set) var isShowingAutoLowercasedNotice = false

        /// 现在看得见的那句（单测、读屏用）。
        var displayedText: String? {
            return isShowingAutoLowercasedNotice ? noticeLabel.text : ruleLabel.text
        }

        /// 动态字体变了时页面重新设（和上游页面上别的说明文字一样）。
        var font: UIFont {
            get { ruleLabel.font }
            set {
                ruleLabel.font = newValue
                noticeLabel.font = newValue
            }
        }

        /// 两句的颜色一样（灰）：「已自动转成小写」不是报错。
        var textColor: UIColor {
            return isShowingAutoLowercasedNotice ? noticeLabel.textColor : ruleLabel.textColor
        }

        init(font: UIFont, noticeDuration: TimeInterval = 2) {
            self.noticeDuration = noticeDuration
            super.init(frame: .zero)

            for label in [ruleLabel, noticeLabel] {
                label.font = font
                label.adjustsFontForContentSizeCategory = true
                label.textColor = .Signal.secondaryLabel
                label.numberOfLines = 0
                label.translatesAutoresizingMaskIntoConstraints = false
                addSubview(label)
            }
            ruleLabel.text = TellomiUsernameInput.ruleHint
            noticeLabel.text = TellomiUsernameInput.autoLowercasedNotice
            noticeLabel.alpha = 0

            NSLayoutConstraint.activate([
                ruleLabel.topAnchor.constraint(equalTo: topAnchor),
                ruleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
                ruleLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
                ruleLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
                noticeLabel.topAnchor.constraint(equalTo: topAnchor),
                noticeLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
                noticeLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
                noticeLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            ])

            isAccessibilityElement = true
            accessibilityTraits = .staticText
            accessibilityLabel = ruleLabel.text
        }

        @available(*, unavailable, message: "Use other constructor")
        required init?(coder: NSCoder) {
            fatalError("Use other constructor!")
        }

        /// 连着转几次，从最后一次起再算 2 秒。
        func showAutoLowercasedNotice() {
            restoreWorkItem?.cancel()
            setShowingNotice(true)
            UIAccessibility.post(notification: .announcement, argument: noticeLabel.text)

            let workItem = DispatchWorkItem { [weak self] in
                self?.setShowingNotice(false)
            }
            restoreWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + noticeDuration, execute: workItem)
        }

        private func setShowingNotice(_ isShowing: Bool) {
            isShowingAutoLowercasedNotice = isShowing
            accessibilityLabel = displayedText
            UIView.animate(withDuration: 0.15) {
                self.ruleLabel.alpha = isShowing ? 0 : 1
                self.noticeLabel.alpha = isShowing ? 1 : 0
            }
        }
    }
}
