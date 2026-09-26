//
// Copyright 2021 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

public import SignalServiceKit
import SignalUI
import UIKit

public class ContextMenuReactionBarAccessory: ContextMenuTargetedPreviewAccessory, MessageReactionPickerDelegate {
    public let thread: TSThread
    public let itemViewModel: CVItemViewModelImpl?
    /// (message, reaction, isRemoving, flyInSource)。Tellomi（交互审计 A-07）加了第四个参数：回应飞入的起点，不飞时是 nil。
    var didSelectReactionHandler: ((TSMessage, String, Bool, ReactionFlyIn.Source?) -> Void)?

    private var reactionPicker: MessageReactionPicker
    private var highlightHoverGestureRecognizer: UIGestureRecognizer?
    private var highlightClickGestureRecognizer: UIGestureRecognizer?

    public init(
        thread: TSThread,
        itemViewModel: CVItemViewModelImpl?,
    ) {
        self.thread = thread
        self.itemViewModel = itemViewModel

        reactionPicker = MessageReactionPicker(
            selectedEmoji: itemViewModel?.reactionState?.localUserEmoji,
            delegate: nil,
            style: .contextMenu(allowGlass: true),
        )
        let isRTL = CurrentAppContext().isRTL
        let isIncomingMessage = itemViewModel?.interaction.interactionType == .incomingMessage
        let alignmentOffset = isIncomingMessage && thread.isGroupThread ? 22 : 0
        let horizontalEdgeAlignment: ContextMenuTargetedPreviewAccessory.AccessoryAlignment.Edge = isIncomingMessage ? (isRTL ? .trailing : .leading) : (isRTL ? .leading : .trailing)
        let alignment = ContextMenuTargetedPreviewAccessory.AccessoryAlignment(alignments: [(.top, .exterior), (horizontalEdgeAlignment, .interior)], alignmentOffset: CGPoint(x: alignmentOffset, y: 12))
        super.init(accessoryView: reactionPicker, accessoryAlignment: alignment)
        reactionPicker.delegate = self
        reactionPicker.isHidden = true

        let highlightHoverGestureRecognizer = UIHoverGestureRecognizer(target: self, action: #selector(hoverGestureRecognized(sender:)))
        reactionPicker.addGestureRecognizer(highlightHoverGestureRecognizer)
        self.highlightHoverGestureRecognizer = highlightHoverGestureRecognizer

        let highlightClickGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(hoverClickGestureRecognized(sender:)))
        highlightClickGestureRecognizer.buttonMaskRequired = [.primary]
        reactionPicker.addGestureRecognizer(highlightClickGestureRecognizer)
        self.highlightClickGestureRecognizer = highlightClickGestureRecognizer
    }

    override func animateIn(
        duration: TimeInterval,
        previewWillShift: Bool,
        completion: @escaping () -> Void,
    ) {
        let animateIn = {
            self.reactionPicker.isHidden = false
            self.reactionPicker.playPresentationAnimation(duration: 0.2)
            completion()

        }
        if previewWillShift {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { animateIn() }
        } else {
            animateIn()
        }

    }

    override func animateOut(
        duration: TimeInterval,
        previewWillShift: Bool,
        completion: @escaping () -> Void,
    ) {
        reactionPicker.playDismissalAnimation(duration: duration, completion: completion)
    }

    @objc
    private func hoverGestureRecognized(sender: UIGestureRecognizer) {
        reactionPicker.updateFocusPosition(sender.location(in: reactionPicker), animated: true)
    }

    @objc
    private func hoverClickGestureRecognized(sender: UIGestureRecognizer) {
        touchLocationInViewDidEnd(locationInView: sender.location(in: reactionPicker))
    }

    override func touchLocationInViewDidChange(locationInView: CGPoint) {
        reactionPicker.updateFocusPosition(locationInView, animated: true)
    }

    @discardableResult
    override func touchLocationInViewDidEnd(locationInView: CGPoint) -> Bool {
        // Send focused emoji if needed
        if let focusedEmoji = reactionPicker.focusedEmoji {
            switch focusedEmoji {
            case .more:
                didSelectShowFullEmojiPicker()
            case .emoji(let emoji):
                let isRemoving = emoji == self.itemViewModel?.reactionState?.localUserEmoji
                if let index = reactionPicker.currentEmojiSet().firstIndex(of: emoji) {
                    // Tellomi（交互审计 A-07）：按住滑到表情上松手，和点按一样给一下触感。
                    ImpactHapticFeedback.impactOccurred(style: .light)
                    didSelectReaction(reaction: emoji, isRemoving: isRemoving, inPosition: index)
                }
            }
            return true
        }

        return false
    }

    // MARK: MessageReactionPickerDelegate

    func didSelectReaction(
        reaction: String,
        isRemoving: Bool,
        inPosition position: Int,
    ) {
        guard let message = itemViewModel?.interaction as? TSMessage else {
            owsFailDebug("Not sending reaction for unexpected interaction type")
            return
        }

        // Tellomi（交互审计 A-07）：选中的表情从条上飞到消息的回应胶囊上；撤回回应、减弱动态效果时不飞。
        let reduceMotion = MainActor.assumeIsolated { TellomiMotion.isReduceMotionEnabled }
        let flyInSource = isRemoving || reduceMotion ? nil : reactionPicker.takeEmojiForFlyIn(at: position)

        // Tellomi（交互审计 A-07）：先写回应、再收起，不等回应条的 0.2 s 淡出播完。
        didSelectReactionHandler?(message, reaction, isRemoving, flyInSource)
        reactionPicker.playDismissalAnimation(duration: 0.2) {
            self.delegate?.contextMenuTargetedPreviewAccessoryRequestsDismissal(self, completion: { })
        }
    }

    func didSelectShowFullEmojiPicker() {
        guard let message = itemViewModel?.interaction as? TSMessage else {
            owsFailDebug("Not sending reaction for unexpected interaction type")
            return
        }

        reactionPicker.playDismissalAnimation(duration: 0.2) { }

        self.delegate?.contextMenuTargetedPreviewAccessoryRequestsEmojiPicker(for: message, accessory: self) { emojiString in
            let isRemoving = emojiString == self.itemViewModel?.reactionState?.localUserEmoji
            self.didSelectReactionHandler?(message, emojiString, isRemoving, nil)
            self.delegate?.contextMenuTargetedPreviewAccessoryRequestsDismissal(self, completion: { })
        }
    }
}
