//
// Copyright 2019 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

protocol InteractivelyDismissableViewController: UIViewController {
    func performInteractiveDismissal(animated: Bool)
}

protocol InteractiveDismissDelegate: AnyObject {
    func interactiveDismissDidBegin(_ interactiveDismiss: UIPercentDrivenInteractiveTransition)
    func interactiveDismiss(
        _ interactiveDismiss: UIPercentDrivenInteractiveTransition,
        didChangeProgress: CGFloat,
        touchOffset: CGPoint,
    )
    func interactiveDismissDidFinish(_ interactiveDismiss: UIPercentDrivenInteractiveTransition)
    func interactiveDismissDidCancel(_ interactiveDismiss: UIPercentDrivenInteractiveTransition)
}

class MediaInteractiveDismiss: UIPercentDrivenInteractiveTransition {
    var interactionInProgress = false

    /// 松手时手指的速度（点 / 秒）。收尾弹簧从这个速度出发，而不是从零开始（tellomi/tellomi 交互审计 A-20）。
    private(set) var releaseVelocity: CGPoint = .zero

    /// 这次拖动里离起点最远的位移，用来判断「往外」是哪一边。
    private var peakOffset: CGPoint = .zero

    weak var interactiveDismissDelegate: InteractiveDismissDelegate?
    private weak var targetViewController: InteractivelyDismissableViewController?

    init(targetViewController: InteractivelyDismissableViewController) {
        super.init()
        self.targetViewController = targetViewController
    }

    func addGestureRecognizer(to view: UIView) {
        let gesture = DirectionalPanGestureRecognizer(
            direction: .vertical,
            target: self,
            action: #selector(handleGesture(_:)),
        )
        // Allow panning with trackpad
        gesture.allowedScrollTypesMask = .continuous
        view.addGestureRecognizer(gesture)
    }

    // MARK: - Private

    private static let distanceToCompletion: CGFloat = 88

    /// 松手判据（tellomi/tellomi 交互审计 A-20）。原来是 `percentComplete > 0`：只要拖过就关，拖回原处也照样关。
    /// 现在按交互与动效标准第四节「位置 + 速度投射」判断，「往外」取这次拖动离起点最远的那一侧：
    /// - 沿这一侧往外甩得够快（≥ 800 pt/s）→ 关；往回甩（≤ −300 pt/s）→ 弹回；
    /// - 否则看投射落点（UIScrollView 快速减速率下约滑行 0.1 s）在这一侧上是否超过走满进度的一半。
    /// 走查模拟器实测过：往下拖出去再拖回、越过起点一点点时手指还带着向上的速度——
    /// 如果按当前位移的方向算「往外」，这股回拉会被当成「往上甩」而关掉。
    static func shouldFinishDismissal(offset: CGPoint, velocity: CGPoint, peakOffset: CGPoint? = nil) -> Bool {
        let reference = if let peakOffset, peakOffset.length > offset.length { peakOffset } else { offset }
        let referenceLength = reference.length
        guard referenceLength > 0 else {
            return false
        }
        let axis = CGPoint(x: reference.x / referenceLength, y: reference.y / referenceLength)
        let speedAway = velocity.x * axis.x + velocity.y * axis.y
        if speedAway >= 800 {
            return true
        }
        if speedAway <= -300 {
            return false
        }
        let glide: CGFloat = 0.099
        let projectedAway = (offset.x + velocity.x * glide) * axis.x + (offset.y + velocity.y * glide) * axis.y
        return projectedAway >= distanceToCompletion / 2
    }

    @objc
    private func handleGesture(_ gestureRecognizer: UIScreenEdgePanGestureRecognizer) {
        guard let coordinateSpace = gestureRecognizer.view?.superview else {
            owsFailDebug("coordinateSpace was unexpectedly nil")
            return
        }

        if case .began = gestureRecognizer.state {
            gestureRecognizer.setTranslation(.zero, in: coordinateSpace)
        }

        switch gestureRecognizer.state {
        case .began:
            interactionInProgress = true
            peakOffset = .zero
            // 松手速度只在 .ended 里写；系统取消的拖动走不到那里，不清零会带着上一次拖动的速度收尾。
            releaseVelocity = .zero
            targetViewController?.performInteractiveDismissal(animated: true)

        case .changed:
            let offset = gestureRecognizer.translation(in: coordinateSpace)
            if offset.length > peakOffset.length {
                peakOffset = offset
            }
            let progress = CGFloat.clamp01(offset.length / Self.distanceToCompletion)
            update(progress)

            interactiveDismissDelegate?.interactiveDismiss(self, didChangeProgress: progress, touchOffset: offset)

        case .cancelled:
            cancel()
            interactiveDismissDelegate?.interactiveDismissDidCancel(self)

            interactionInProgress = false

            targetViewController?.setNeedsStatusBarAppearanceUpdate()

        case .ended:
            releaseVelocity = gestureRecognizer.velocity(in: coordinateSpace)
            let finishTransition = Self.shouldFinishDismissal(
                offset: gestureRecognizer.translation(in: coordinateSpace),
                velocity: releaseVelocity,
                peakOffset: peakOffset,
            )
            if finishTransition {
                finish()
            } else {
                cancel()
            }

            interactiveDismissDelegate?.interactiveDismissDidFinish(self)

            // This logic is necessary to ensure correct status bar state
            // both when transition is finished or canceled.
            if finishTransition {
                targetViewController?.setNeedsStatusBarAppearanceUpdate()
            }

            interactionInProgress = false

            if !finishTransition {
                targetViewController?.setNeedsStatusBarAppearanceUpdate()
            }

        default:
            break
        }
    }
}
