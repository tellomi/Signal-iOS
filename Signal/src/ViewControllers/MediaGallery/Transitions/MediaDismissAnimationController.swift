//
// Copyright 2019 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

class MediaDismissAnimationController: NSObject {
    private let item: Media
    let interactionController: MediaInteractiveDismiss

    var transitionView: UIView?
    var fromMediaFrame: CGRect?
    var pendingCompletion: (() -> Void)?

    init(galleryItem: MediaGalleryItem, interactionController: MediaInteractiveDismiss) {
        self.item = .gallery(galleryItem)
        self.interactionController = interactionController
    }

    init(image: UIImage, interactionController: MediaInteractiveDismiss) {
        self.item = .image(image)
        self.interactionController = interactionController
    }
}

extension MediaDismissAnimationController: UIViewControllerAnimatedTransitioning {

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        return MediaPresentationContext.animationDuration
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {

        let containerView = transitionContext.containerView

        // Bunch of checks to ensure everything is set up for the animated transition.
        // If there's anything wrong the transition would complete without animation.

        guard let fromVC = transitionContext.viewController(forKey: .from) else {
            owsFailDebug("fromVC was unexpectedly nil")
            transitionContext.completeTransition(false)
            return
        }

        let fromContextProvider: MediaPresentationContextProvider
        switch fromVC {
        case let contextProvider as MediaPresentationContextProvider:
            fromContextProvider = contextProvider
        case let navController as UINavigationController:
            guard let contextProvider = navController.topViewController as? MediaPresentationContextProvider else {
                owsFailDebug("unexpected context: \(String(describing: navController.topViewController))")
                transitionContext.completeTransition(false)
                return
            }
            fromContextProvider = contextProvider
        default:
            owsFailDebug("unexpected fromVC: \(fromVC)")
            transitionContext.completeTransition(false)
            return
        }

        guard let fromMediaContext = fromContextProvider.mediaPresentationContext(item: item, in: containerView) else {
            owsFailDebug("fromPresentationContext was unexpectedly nil")
            transitionContext.completeTransition(false)
            return
        }
        self.fromMediaFrame = fromMediaContext.presentationFrame

        guard let toVC = transitionContext.viewController(forKey: .to) else {
            owsFailDebug("toVC was unexpectedly nil")
            transitionContext.completeTransition(false)
            return
        }

        // toView will be nil if doing a modal dismiss, in which case we don't want to add the view -
        // it's already in the view hierarchy, behind the VC we're dismissing.
        if let toView = transitionContext.view(forKey: .to) {
            containerView.addSubview(toView)
        }

        guard let fromView = transitionContext.view(forKey: .from) else {
            owsFailDebug("fromView was unexpectedly nil")
            transitionContext.completeTransition(false)
            return
        }

        let toContextProvider: MediaPresentationContextProvider
        switch toVC {
        case let contextProvider as MediaPresentationContextProvider:
            toContextProvider = contextProvider
        case let navController as UINavigationController:
            guard let contextProvider = navController.topViewController as? MediaPresentationContextProvider else {
                owsFailDebug("unexpected context: \(String(describing: navController.topViewController))")
                transitionContext.completeTransition(false)
                return
            }
            toContextProvider = contextProvider
        case let splitViewController as ConversationSplitViewController:
            guard let contextProvider = splitViewController.topViewController as? MediaPresentationContextProvider else {
                owsFailDebug("unexpected context: \(String(describing: splitViewController.topViewController))")
                transitionContext.completeTransition(false)
                return
            }
            toContextProvider = contextProvider
        default:
            owsFailDebug("unexpected toVC: \(toVC)")
            transitionContext.completeTransition(false)
            return
        }

        let toMediaContext = toContextProvider.mediaPresentationContext(item: item, in: containerView)

        // All is good, set up the view hierarchy and view animations.

        let isTransitionInteractive = transitionContext.isInteractive

        let backgroundView = UIView(frame: containerView.bounds)
        backgroundView.backgroundColor = fromMediaContext.backgroundColor
        backgroundView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        containerView.addSubview(backgroundView)

        // Sometimes the initial (from) or the final (to) media view is partially obscured
        // (by navigation bar at the top and by the bottom bar at the bottom).
        // To animate from one "viewport" to another we set up a clipping
        // view that will contain the transitional media view.
        let clippingView = UIView(frame: containerView.bounds)
        clippingView.clipsToBounds = true
        if let clippingAreaInsets = fromMediaContext.clippingAreaInsets {
            clippingView.frame = containerView.bounds.inset(by: clippingAreaInsets)
        }
        containerView.addSubview(clippingView)

        // Can't do rounded corners and drop shadow at the same time,
        // so put image into a container view.
        let transitionViewFrame = clippingView.convert(fromMediaContext.presentationFrame, from: containerView)
        let transitionView = UIView(frame: transitionViewFrame)
        transitionView.layer.shadowColor = UIColor.ows_blackAlpha20.cgColor
        transitionView.layer.shadowOffset = CGSize(width: 0, height: 32)
        transitionView.layer.shadowRadius = 48
        transitionView.layer.shadowOpacity = 0
        // Tellomi（交互审计 A-20）：拖动阶段尺寸不变，给阴影一个路径，免得跟手时每帧离屏渲染半径 48 的阴影。
        transitionView.layer.shadowPath = Self.dragShadowPath(for: fromMediaContext.mediaViewShape, in: transitionView.bounds)
        clippingView.addSubview(transitionView)
        self.transitionView = transitionView

        let transitionImageView: MediaTransitionImageView?
        if let presentationImage = item.image {
            let imageView = MediaTransitionImageView(image: presentationImage)
            imageView.contentMode = .scaleAspectFill
            imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            imageView.layer.masksToBounds = true
            imageView.shape = fromMediaContext.mediaViewShape
            imageView.frame = transitionView.bounds
            transitionView.addSubview(imageView)
            transitionImageView = imageView
        } else {
            transitionImageView = nil
        }

        // Because toggling `isHidden` causes UIStack view layouts to change, we instead toggle `alpha`
        fromMediaContext.mediaView.alpha = 0
        toMediaContext?.mediaView.alpha = 0

        let completion = {
            let destinationFrame: CGRect
            let destinationMediaViewShape: MediaViewShape
            if transitionContext.transitionWasCancelled {
                destinationFrame = fromMediaContext.presentationFrame
                destinationMediaViewShape = fromMediaContext.mediaViewShape
            } else if let toMediaContext {
                destinationFrame = toMediaContext.presentationFrame
                destinationMediaViewShape = toMediaContext.mediaViewShape
            } else {
                // `toMediaContext` can be nil if the target item is scrolled off of the
                // contextProvider's screen, so we synthesize a context to dismiss the item
                // off screen
                let offscreenFrame = fromMediaContext.presentationFrame.offsetBy(dx: 0, dy: fromMediaContext.presentationFrame.height)
                destinationFrame = offscreenFrame
                destinationMediaViewShape = fromMediaContext.mediaViewShape
            }

            // Tellomi（交互审计 A-20）：收尾用交互标准的 large 弹簧，并从松手速度出发；
            // 原来是固定的 spring(1, 0.25)，松手那一下速度断档。
            transitionView.layer.shadowPath = nil
            let reduceMotion = TellomiMotion.isReduceMotionEnabled
            let isFinishing = !transitionContext.transitionWasCancelled
            let targetClippingFrame = Self.targetClippingFrame(
                containerBounds: containerView.bounds,
                currentClippingFrame: clippingView.frame,
                isFinishing: isFinishing,
                toClippingAreaInsets: toMediaContext?.clippingAreaInsets,
            )
            let destinationInClipping = Self.landingFrame(destinationFrame: destinationFrame, targetClippingFrame: targetClippingFrame)
            // 剩余距离按屏幕上（容器坐标）量：裁剪区域自己也在动，图在屏幕上走的是两者之和。
            let currentCenter = clippingView.convert(transitionView.center, to: containerView)
            let remaining = CGVector(
                dx: destinationFrame.midX - currentCenter.x,
                dy: destinationFrame.midY - currentCenter.y,
            )
            let animator: UIViewPropertyAnimator
            if reduceMotion, isFinishing {
                // 减弱动态效果：交叉淡入淡出，时长照标准第六节（0.15–0.2 s），不用弹簧。
                animator = UIViewPropertyAnimator(duration: TellomiMotion.reducedMotionCrossfadeDuration, curve: .easeOut)
            } else {
                animator = TellomiMotion.animator(
                    TellomiMotion.large,
                    initialVelocity: isTransitionInteractive
                        ? TellomiMotion.relativeVelocity(self.interactionController.releaseVelocity, remaining: remaining)
                        : .zero,
                    reduceMotion: reduceMotion,
                )
            }
            animator.addAnimations {
                if isFinishing {
                    fromView.alpha = 0
                    backgroundView.backgroundColor = toMediaContext?.backgroundColor
                }

                if reduceMotion, isFinishing {
                    // 减弱动态效果：不「飞」回缩略图，原地淡出，缩略图同时淡入（HIG：位移改淡入淡出）。
                    // 裁剪区域也不动，不然淡出的图会跟着它往下滑。
                    transitionView.alpha = 0
                    toMediaContext?.mediaView.alpha = 1
                } else {
                    clippingView.frame = targetClippingFrame
                    transitionImageView?.shape = destinationMediaViewShape
                    transitionView.transform = .identity
                    transitionView.frame = destinationInClipping
                }
                transitionView.layer.shadowOpacity = 0
            }
            animator.addCompletion { _ in
                clippingView.removeFromSuperview()
                backgroundView.removeFromSuperview()

                fromMediaContext.mediaView.alpha = 1
                toMediaContext?.mediaView.alpha = 1
                if transitionContext.transitionWasCancelled {
                    // the "to" view will be nil if we're doing a modal dismiss, in which case
                    // we wouldn't want to remove the toView.
                    transitionContext.view(forKey: .to)?.removeFromSuperview()
                } else {
                    assert(transitionContext.view(forKey: .from) != nil)
                    transitionContext.view(forKey: .from)?.removeFromSuperview()
                }

                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)

                DispatchQueue.main.async {
                    fromContextProvider.mediaDidDismiss(fromContext: fromMediaContext)
                    if let toMediaContext {
                        toContextProvider.mediaDidDismiss(toContext: toMediaContext)
                    }
                }
            }
            animator.startAnimation()
        }

        fromContextProvider.mediaWillDismiss(fromContext: fromMediaContext)
        if let toMediaContext {
            toContextProvider.mediaWillDismiss(toContext: toMediaContext)
        }

        if isTransitionInteractive {
            self.pendingCompletion = completion

            // "animation end" state is the UI state when user drags the image around
            // and has exceeded distance threshold specified in MediaInteractiveDismiss.
            // UIKit will reverse the animation if user drags the image back to the starting point.
            UIView.animate(
                withDuration: 0.2,
                delay: 0,
                animations: {
                    fromView.alpha = 0
                    backgroundView.backgroundColor = toMediaContext?.backgroundColor

                    transitionView.transform = .scale(0.8)
                    transitionView.layer.shadowOpacity = 1
                },
                completion: { _ in
                    guard let pendingCompletion = self.pendingCompletion else {
                        return
                    }

                    self.pendingCompletion = nil
                    pendingCompletion()
                },
            )
        } else {
            completion()
        }
    }
}

extension MediaDismissAnimationController: InteractiveDismissDelegate {
    func interactiveDismissDidBegin(_ interactiveDismiss: UIPercentDrivenInteractiveTransition) { }

    func interactiveDismiss(
        _ interactiveDismiss: UIPercentDrivenInteractiveTransition,
        didChangeProgress progress: CGFloat,
        touchOffset offset: CGPoint,
    ) {
        guard let transitionView else {
            // transition hasn't started yet.
            return
        }

        guard let fromMediaFrame else {
            owsFailDebug("fromMediaFrame was unexpectedly nil")
            return
        }

        transitionView.center = fromMediaFrame.offsetBy(dx: offset.x, dy: offset.y).center
    }

    func interactiveDismissDidFinish(_ interactiveDismiss: UIPercentDrivenInteractiveTransition) {
        if let pendingCompletion {
            self.pendingCompletion = nil
            pendingCompletion()
        }
    }

    func interactiveDismissDidCancel(_ interactiveDismiss: UIPercentDrivenInteractiveTransition) { }
}

// MARK: - Tellomi（交互审计 A-20）

extension MediaDismissAnimationController {

    /// 拖动时阴影的路径，照媒体的形状画：头像大图（AvatarViewController）是圆的，画成矩形会在圆外面拖出一圈方的阴影。
    /// 各个角不一样圆的不给路径，照旧按内容算阴影。
    static func dragShadowPath(for shape: MediaViewShape, in bounds: CGRect) -> CGPath? {
        switch shape {
        case .circle:
            // 同 MediaTransitionImageView：圆角半径是短边的一半
            return UIBezierPath(roundedRect: bounds, cornerRadius: 0.5 * min(bounds.width, bounds.height)).cgPath
        case .rectangle(let cornerRadius):
            return UIBezierPath(roundedRect: bounds, cornerRadius: cornerRadius).cgPath
        case .variableRoundedCorners:
            return nil
        }
    }

    /// 收尾时裁剪区域的去处：关掉时换成目标页的（没有就是整个容器），弹回时不动。
    static func targetClippingFrame(
        containerBounds: CGRect,
        currentClippingFrame: CGRect,
        isFinishing: Bool,
        toClippingAreaInsets: UIEdgeInsets?,
    ) -> CGRect {
        guard isFinishing else {
            return currentClippingFrame
        }
        if let toClippingAreaInsets {
            return containerBounds.inset(by: toClippingAreaInsets)
        }
        return containerBounds
    }

    /// 落点在裁剪区域里的位置，按收尾之后的裁剪区域换算。上游是在动画块里先改裁剪区域再换算；
    /// 提前按旧的裁剪区域换算，落点会差出两页裁剪区域之差（从查看器回会话页，约是状态栏 + 导航栏的高度）。
    static func landingFrame(destinationFrame: CGRect, targetClippingFrame: CGRect) -> CGRect {
        destinationFrame.offsetBy(dx: -targetClippingFrame.minX, dy: -targetClippingFrame.minY)
    }
}
