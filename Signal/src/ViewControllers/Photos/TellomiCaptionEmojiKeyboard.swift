//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

/// tellomi/tellomi#1261 P-9：选图面板说明框的表情键盘（说明框右下角的笑脸键切过来）。
///
/// 机制照 Telegram iOS：说明框（`AttachmentTextInputPanelNode`）里一个 32 pt 的键，笑脸 ↔ 键盘，切到表情时把说明框的
/// `inputView` 换成只有 emoji 的面板（不带贴纸、GIF），点一个插到光标处；面板（`EntityKeyboard`）上面是分类，
/// 底栏左边切回文字键盘、右边退格（按住连删、有按键声）；收起键盘就回到文字键盘。一行没搬（GPLv2）。
/// 面板用 Signal 现成的 `EmojiPickerSectionToolbar`（分类）和 `EmojiPickerCollectionView`（最近用过、分类、长按选肤色、
/// 记「最近」），底栏是这里加的；按键声用系统的输入点击（`UIInputViewAudioFeedback`，跟着用户的键盘声音设置）。
final class TellomiCaptionEmojiKeyboard: CustomKeyboard, UIInputViewAudioFeedback {

    var onSelectEmoji: ((String) -> Void)?
    var onDeleteBackward: (() -> Void)?
    var onSwitchToText: (() -> Void)?

    /// 按住退格：先删一个，停 0.5 秒后每 0.1 秒再删一个（同系统键盘）。
    static let deleteRepeatDelay: TimeInterval = 0.5
    static let deleteRepeatInterval: TimeInterval = 0.1

    private let emojiView = EmojiPickerCollectionView(message: nil)
    private lazy var sectionToolbar = EmojiPickerSectionToolbar(delegate: self)
    private var deleteRepeatTimer: Timer?

    private lazy var keyboardButton: UIButton = {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(imageLiteralResourceName: "keyboard")
        configuration.baseForegroundColor = .Signal.label
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            self?.onSwitchToText?()
        })
        button.accessibilityLabel = OWSLocalizedString(
            "INPUT_TOOLBAR_KEYBOARD_BUTTON_ACCESSIBILITY_LABEL",
            comment: "accessibility label for the button which shows the regular keyboard instead of sticker picker",
        )
        return button
    }()

    private lazy var deleteButton: UIButton = {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "delete.left")
        configuration.baseForegroundColor = .Signal.label
        let button = UIButton(configuration: configuration)
        button.addAction(UIAction { [weak self] _ in self?.beginDeleting() }, for: .touchDown)
        for event: UIControl.Event in [.touchUpInside, .touchUpOutside, .touchCancel] {
            button.addAction(UIAction { [weak self] _ in self?.endDeleting() }, for: event)
        }
        button.accessibilityLabel = CommonStrings.deleteButton
        return button
    }()

    override init() {
        super.init()

        sectionToolbar.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(sectionToolbar)

        emojiView.pickerDelegate = self
        emojiView.alwaysBounceVertical = true
        emojiView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(emojiView)

        keyboardButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(keyboardButton)
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(deleteButton)

        NSLayoutConstraint.activate([
            sectionToolbar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            sectionToolbar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            sectionToolbar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            emojiView.topAnchor.constraint(equalTo: sectionToolbar.bottomAnchor, constant: 4),
            emojiView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            emojiView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            emojiView.bottomAnchor.constraint(equalTo: deleteButton.topAnchor),

            keyboardButton.widthAnchor.constraint(equalToConstant: 44),
            keyboardButton.heightAnchor.constraint(equalToConstant: 44),
            keyboardButton.leadingAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            keyboardButton.bottomAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.bottomAnchor),

            deleteButton.widthAnchor.constraint(equalToConstant: 44),
            deleteButton.heightAnchor.constraint(equalToConstant: 44),
            deleteButton.trailingAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            deleteButton.bottomAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func wasDismissed() {
        super.wasDismissed()
        endDeleting()
    }

    // MARK: - UIInputViewAudioFeedback

    var enableInputClicksWhenVisible: Bool { true }

    // MARK: - Delete

    private func beginDeleting() {
        deleteOnce()
        deleteRepeatTimer?.invalidate()
        deleteRepeatTimer = Timer.scheduledTimer(withTimeInterval: Self.deleteRepeatDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.deleteRepeatTimer = Timer.scheduledTimer(withTimeInterval: Self.deleteRepeatInterval, repeats: true) { [weak self] _ in
                self?.deleteOnce()
            }
        }
    }

    private func endDeleting() {
        deleteRepeatTimer?.invalidate()
        deleteRepeatTimer = nil
    }

    private func deleteOnce() {
        UIDevice.current.playInputClick()
        onDeleteBackward?()
    }
}

// MARK: - EmojiPickerCollectionViewDelegate

extension TellomiCaptionEmojiKeyboard: EmojiPickerCollectionViewDelegate {
    func emojiPicker(_ emojiPicker: EmojiPickerCollectionView, didSelectEmoji emoji: EmojiWithSkinTones) {
        UIDevice.current.playInputClick()
        onSelectEmoji?(emoji.rawValue)
    }

    func emojiPicker(_ emojiPicker: EmojiPickerCollectionView, didScrollToSection section: EmojiPickerSection) {
        switch section {
        case .messageEmoji, .recentEmoji:
            sectionToolbar.setSelectedSection(0)
        case .emojiCategory(let categoryIndex):
            sectionToolbar.setSelectedSection(categoryIndex + (emojiPicker.hasRecentEmoji ? 1 : 0))
        }
    }

    func emojiPickerWillBeginDragging(_ emojiPicker: EmojiPickerCollectionView) {}
}

// MARK: - EmojiPickerSectionToolbarDelegate

extension TellomiCaptionEmojiKeyboard: EmojiPickerSectionToolbarDelegate {
    func emojiPickerSectionToolbar(_ sectionToolbar: EmojiPickerSectionToolbar, didSelectSection section: Int) {
        if section == 0, emojiView.hasRecentEmoji {
            emojiView.scrollToSectionHeader(.recentEmoji, animated: false)
        } else {
            emojiView.scrollToSectionHeader(.emojiCategory(categoryIndex: section - (emojiView.hasRecentEmoji ? 1 : 0)), animated: false)
        }
    }

    func emojiPickerSectionToolbarShouldShowRecentsSection(_ sectionToolbar: EmojiPickerSectionToolbar) -> Bool {
        emojiView.hasRecentEmoji
    }
}

#if TESTABLE_BUILD

extension TellomiCaptionEmojiKeyboard {
    /// 点面板里的一个 emoji（走 collection view 的选中回调，和手指点一样会记进「最近」）。
    func tapEmojiForTesting(at indexPath: IndexPath) -> String? {
        guard let emoji = emojiView.emojiForIndexPath(indexPath) else { return nil }
        emojiView.delegate?.collectionView?(emojiView, didSelectItemAt: indexPath)
        return emoji.rawValue
    }

    /// 这几个都走按钮本身的事件，按钮接错了测试才会红。
    func tapDeleteForTesting() {
        deleteButton.sendActions(for: .touchDown)
        deleteButton.sendActions(for: .touchUpInside)
    }

    func holdDeleteForTesting(seconds: TimeInterval) async throws {
        deleteButton.sendActions(for: .touchDown)
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        deleteButton.sendActions(for: .touchUpInside)
    }

    func tapKeyboardForTesting() {
        keyboardButton.sendActions(for: .primaryActionTriggered)
    }

    var sectionToolbarFrameForTesting: CGRect { sectionToolbar.frame }
    var emojiViewFrameForTesting: CGRect { emojiView.frame }
    var keyboardButtonFrameForTesting: CGRect { keyboardButton.frame }
    var deleteButtonFrameForTesting: CGRect { deleteButton.frame }
}

#endif
