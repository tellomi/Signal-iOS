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
    /// 现在按交互与动效标准第四节「位置 + 速度投射」判断：
    /// - 沿拖动方向往外甩得够快（≥ 800 pt/s）→ 关；往回甩（≤ −300 pt/s）→ 弹回；
    /// - 否则看投射落点（UIScrollView 快速减速率下约滑行 0.1 s）离起点是否超过走满进度的一半。
    static func shouldFinishDismissal(offset: CGPoint, velocity: CGPoint) -> Bool {
        let distance = offset.length
        guard distance > 0 else {
            return false
        }
        let speedAway = (velocity.x * offset.x + velocity.y * offset.y) / distance
        if speedAway >= 800 {
            return true
        }
        if speedAway <= -300 {
            return false
        }
        let glide: CGFloat = 0.099
        let projected = CGPoint(x: offset.x + velocity.x * glide, y: offset.y + velocity.y * glide)
        return projected.length >= distanceToCompletion / 2
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
            targetViewController?.performInteractiveDismissal(animated: true)

        case .changed:
            let offset = gestureRecognizer.translation(in: coordinateSpace)
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
