//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// 回应飞入（tellomi/tellomi 交互审计 A-07）在会话页这一侧：什么时候起飞、落到哪。飞行本身见 [ReactionFlyIn]。
///
/// 这条回应一画在消息下方就起飞，菜单还在收也飞（Telegram 两端都是一选中就飞、和菜单收起同时）：选了回应以后聊天列表在
/// 菜单收起期间照常落 load（`CVLoadCoordinator`），真消息藏到菜单收完（[tellomiKeepMessageHiddenWhileMenuCloses]），
/// 预览快照飞回它此刻的位置。一找到落点就起飞，不等它停稳：[ReactionFlyIn] 每一帧重新量落点（模型层坐标），接连几次
/// 重新布局把格子挪来挪去也跟得上（Telegram 安卓 `ReactionsEffectOverlay` 也是每帧重新取落点）。
extension ConversationViewController {

    func beginReactionFlyIn(messageUniqueId: String, emoji: String, source: ReactionFlyIn.Source) {
        viewState.pendingReactionFlyIn?.cancel()
        viewState.pendingReactionFlyIn = nil
        guard let window = view.window else {
            return
        }
        viewState.pendingReactionFlyIn = ReactionFlyIn(
            messageUniqueId: messageUniqueId,
            emoji: emoji,
            source: source,
            window: window,
        )
    }

    /// 菜单收完、每次 load 落地时各调一次。回应还没画出来就什么都不做，等下一次或者超时。
    func landPendingReactionFlyInIfPossible() {
        // Tellomi（owner 2026-10-18）：双击回应没有起飞，回应画出来时在胶囊上爆开一下。
        tellomiPlayPendingQuickReactionBurstIfPossible()

        tellomiKeepMessageHiddenWhileMenuCloses()

        guard
            let flyIn = viewState.pendingReactionFlyIn,
            collectionViewActiveContextMenuInteraction.map({ !$0.contextMenuVisible || $0.tellomiReactionChosen }) ?? true,
            let target = reactionFlyInTarget(messageUniqueId: flyIn.messageUniqueId, emoji: flyIn.emoji)
        else {
            return
        }
        viewState.pendingReactionFlyIn = nil
        flyIn.claim(target)
        flyIn.land(on: target, targetFontSize: target.font.pointSize)
    }

    /// Tellomi（交互审计 A-07 起飞时机）：选了回应、菜单还在收，load 却已经落了：这条消息可能换了格子（`reloadItems` 会给它新的
    /// cell，新 cell 的气泡和回应区是露着的），也可能被新胶囊挤了位置。新格子的气泡和回应区也藏起来（菜单收完在 didEnd 里放出来），
    /// 预览和回应区快照改飞向它们此刻的位置。没换格子时藏着的就是菜单藏的那两个，不再记。
    func tellomiKeepMessageHiddenWhileMenuCloses() {
        guard
            let interaction = collectionViewActiveContextMenuInteraction,
            interaction.contextMenuVisible,
            interaction.tellomiReactionChosen,
            let indexPath = indexPath(forInteractionUniqueId: interaction.itemViewModel.interaction.uniqueId),
            let cell = collectionView.cellForItem(at: indexPath) as? CVCell,
            let messageView = cell.componentView as? CVComponentMessage.CVComponentViewMessage
        else {
            return
        }
        let (contentView, auxiliaryView) = messageView.tellomiContextMenuCoveredViews
        for view in [contentView, auxiliaryView] where !view.isHidden {
            view.isHidden = true
            viewState.tellomiViewsHiddenWhileMenuCloses.append(view)
        }
        interaction.tellomiRetargetDismissal(previewTo: contentView, auxiliaryTo: auxiliaryView)
    }

    func reactionFlyInTarget(messageUniqueId: String, emoji: String) -> UILabel? {
        guard
            let indexPath = indexPath(forInteractionUniqueId: messageUniqueId),
            let cell = collectionView.cellForItem(at: indexPath) as? CVCell,
            let messageView = cell.componentView as? CVComponentMessage.CVComponentViewMessage
        else {
            return nil
        }
        return messageView.reactionEmojiLabel(for: emoji)
    }
}
