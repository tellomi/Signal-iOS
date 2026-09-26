//
// Copyright 2018 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

public import UIKit

// Tellomi（tellomi/tellomi 交互审计 A-02）：
// - 在主线程调用时同步触发。原来一律 `DispatchQueue.main.async`，触感总比画面晚一帧（跟手手势里尤其明显）。
// - Impact 的生成器按 style 复用，触发后立即 prepare 给下一次。原来每次新建、prepare 完马上触发，prepare 形同虚设。
// - 新代码优先用带 view 的 `impactOccurred(style:in:at:)`：iOS 27 起不带 view 的 `UIImpactFeedbackGenerator(style:)` 已弃用。
private func performOnMain(_ block: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated(block)
    } else {
        DispatchQueue.main.async(execute: block)
    }
}

public class SelectionHapticFeedback {
    private let feedbackGenerator = UISelectionFeedbackGenerator()

    public init() {
        AssertIsOnMainThread()
        feedbackGenerator.prepare()
    }

    public func selectionChanged() {
        performOnMain {
            self.feedbackGenerator.selectionChanged()
            self.feedbackGenerator.prepare()
        }
    }
}

public class NotificationHapticFeedback {
    private let feedbackGenerator = UINotificationFeedbackGenerator()

    public init() {
        AssertIsOnMainThread()
        feedbackGenerator.prepare()
    }

    public func notificationOccurred(_ notificationType: UINotificationFeedbackGenerator.FeedbackType) {
        performOnMain {
            self.feedbackGenerator.notificationOccurred(notificationType)
            self.feedbackGenerator.prepare()
        }
    }
}

public class ImpactHapticFeedback {

    @MainActor
    private static var generators: [UIImpactFeedbackGenerator.FeedbackStyle: UIImpactFeedbackGenerator] = [:]

    @MainActor
    private static func cachedGenerator(for style: UIImpactFeedbackGenerator.FeedbackStyle) -> UIImpactFeedbackGenerator {
        if let generator = generators[style] {
            return generator
        }
        let generator = UIImpactFeedbackGenerator(style: style)
        generators[style] = generator
        return generator
    }

    public class func impactOccurred(style: UIImpactFeedbackGenerator.FeedbackStyle) {
        performOnMain {
            let generator = cachedGenerator(for: style)
            generator.impactOccurred()
            generator.prepare()
        }
    }

    public class func impactOccurred(style: UIImpactFeedbackGenerator.FeedbackStyle, intensity: CGFloat) {
        performOnMain {
            let generator = cachedGenerator(for: style)
            generator.impactOccurred(intensity: intensity)
            generator.prepare()
        }
    }

    /// 带 view 的触发（iOS 17.5+ 用 `init(style:view:)` 与 `impactOccurred(intensity:at:)`，系统据此选择触感的位置与强度）；
    /// 更早的系统回落到上面的写法。
    @MainActor
    public class func impactOccurred(style: UIImpactFeedbackGenerator.FeedbackStyle, in view: UIView, at location: CGPoint? = nil, intensity: CGFloat = 1) {
        if #available(iOS 17.5, *) {
            let generator = UIImpactFeedbackGenerator(style: style, view: view)
            if let location {
                generator.impactOccurred(intensity: intensity, at: location)
            } else {
                generator.impactOccurred(intensity: intensity)
            }
        } else {
            impactOccurred(style: style, intensity: intensity)
        }
    }
}
