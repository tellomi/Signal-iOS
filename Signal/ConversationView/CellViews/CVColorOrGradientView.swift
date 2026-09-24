//
// Copyright 2021 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
public import SignalUI

// Compare with ColorOrGradientSwatchView:
//
// * CVColorOrGradientView is intended to be used in CVC cells.
//   It does not assume the gradient bounds corresponds to the
//   view bounds.
// * ColorOrGradientSwatchView is for use elsewhere.
//   It can pin gradient bounds to the edges of a circle for previews.
//   It can be used to render wallpapers.
//
// Although we could combine these two views, these two scenarios are
// just different enough that its convenient to have two separate views.
public class CVColorOrGradientView: ManualLayoutViewWithLayer, CVDimmableView {

    private weak var referenceView: UIView?
    private var value: ColorOrGradientValue?

    private var bubbleConfig: BubbleConfiguration?

    private var backgroundBlurView: UIVisualEffectView?
    private let gradientLayer = CAGradientLayer()
    private let strokeLayer = CAShapeLayer()
    private let maskLayer = CAShapeLayer()
    private var dimmerLayer: CALayer?

    public var ensureSubviewsFillBounds = false
    public var animationsEnabled = false

    /// Tellomi（tellomi/tellomi#1257）：横滑相册在气泡里的那一段（本视图坐标）。有值时气泡画成上下两块，
    /// 中间留给整屏宽的相册（CVAlbumCarouselView）；每次重新布局时取一次。
    var bubbleGap: (() -> CVBubbleGap?)?

    public init() {
        super.init(name: "CVColorOrGradientView")

        strokeLayer.fillColor = nil

        gradientLayer.disableAnimationsWithDelegate()
        strokeLayer.disableAnimationsWithDelegate()
        maskLayer.disableAnimationsWithDelegate()
    }

    private func addDefaultLayoutBlock() {
        addLayoutBlock { view in
            guard let view = view as? CVColorOrGradientView else { return }
            view.updateAppearance()
        }
    }

    private func ensureSubviewLayout() {
        guard ensureSubviewsFillBounds else { return }
        for subview in subviews {
            ManualLayoutView.setSubviewFrame(subview: subview, frame: bounds)
        }
    }

    public func configure(
        value: ColorOrGradientValue,
        referenceView: UIView,
        bubbleConfig: BubbleConfiguration? = nil,
    ) {
        self.value = value
        self.referenceView = referenceView
        self.bubbleConfig = bubbleConfig

        addDefaultLayoutBlock()

        updateAppearance()
    }

    public func updateAppearance() {

        guard let value, let referenceView else {
            backgroundColor = nil
            backgroundBlurView?.removeFromSuperview()
            gradientLayer.removeFromSuperlayer()
            dimmerLayer?.removeFromSuperlayer()
            return
        }

        switch value {
        case .transparent:
            backgroundColor = nil
            backgroundBlurView?.removeFromSuperview()
            gradientLayer.removeFromSuperlayer()
            dimmerLayer?.removeFromSuperlayer()

        case .blur(let blurEffect):
            backgroundColor = nil
            if let backgroundBlurView {
                backgroundBlurView.effect = blurEffect
                // `backgroundBlurView` will be removed as a subview if `reset()` was called.
                // But not every call of `updateAppearance()` is preceded by `reset()`.
                if backgroundBlurView.superview != self {
                    addSubviewToFillSuperviewEdges(backgroundBlurView)
                }
            } else {
                let backgroundBlurView = UIVisualEffectView(effect: blurEffect)
                addSubviewToFillSuperviewEdges(backgroundBlurView)
                self.backgroundBlurView = backgroundBlurView
            }
            gradientLayer.removeFromSuperlayer()

        case .solidColor(let color):
            backgroundColor = color
            backgroundBlurView?.removeFromSuperview()
            gradientLayer.removeFromSuperlayer()

        case .gradient(let color1, let color2, let angleRadians):
            backgroundBlurView?.removeFromSuperview()

            if gradientLayer.superlayer != self.layer {
                gradientLayer.removeFromSuperlayer()
                layer.insertSublayer(gradientLayer, at: 0)
            }

            gradientLayer.frame = self.bounds

            gradientLayer.colors = [
                color1.cgColor,
                color2.cgColor,
            ]

            /* The start and end points of the gradient when drawn into the layer's
             * coordinate space. The start point corresponds to the first gradient
             * stop, the end point to the last gradient stop. Both points are
             * defined in a unit coordinate space that is then mapped to the
             * layer's bounds rectangle when drawn. (I.e. [0,0] is the bottom-left
             * corner of the layer, [1,1] is the top-right corner.) The default values
             * are [.5,0] and [.5,1] respectively. Both are animatable. */
            let unitCenter = CGPoint(x: 0.5, y: 0.5)
            // Note the signs.
            let startVector = CGPoint(x: +sin(angleRadians), y: -cos(angleRadians))
            let startScale: CGFloat
            // In rectangle mode, we want the startPoint and endPoint to reside
            // on the edge of the unit square, and thus edge of the rectangle.
            // We therefore scale such that longer axis is a half unit.
            let startSquareScale: CGFloat = max(abs(startVector.x), abs(startVector.y))
            startScale = 0.5 / startSquareScale

            // Control points within the bounding box of the entire gradient.
            // Expressed as unit values with upper-left origin.
            //
            // 0,0
            // ********************** C1 **
            // *                          *
            // *                          *
            // *                          *
            // *                          *
            // *                          *
            // *                          *
            // ** C2 ********************** 1,1
            //
            let startPointGradientUnitsUL = unitCenter + startVector * +startScale
            // The endpoint should be "opposite" the start point,
            // on the opposite edge of the gradient.
            let endPointGradientUnitsUL = unitCenter + startVector * -startScale

            // Each message bubble renders a subsection of the gradient.
            // We need to convert the control points from the bounding box
            // of the gradient to the local unit coordinate space of this view.
            // The reference frame (bounding box of the entire gradient)
            // in local points.
            let referenceFrameLocalPoints = self.convert(referenceView.bounds, from: referenceView)
            // The reference frame (bounding box of the entire gradient)
            // in local unit coordinates.
            let referenceFrameLocalUnits = CGRect(
                x: referenceFrameLocalPoints.x.inverseLerp(bounds.minX, bounds.maxX),
                y: referenceFrameLocalPoints.y.inverseLerp(bounds.minY, bounds.maxY),
                width: referenceFrameLocalPoints.width / bounds.width,
                height: referenceFrameLocalPoints.height / bounds.height,
            )
            func convertFromGradientToLocal(_ point: CGPoint) -> CGPoint {
                CGPoint(
                    x: point.x.lerp(referenceFrameLocalUnits.minX, referenceFrameLocalUnits.maxX),
                    y: point.y.lerp(referenceFrameLocalUnits.minY, referenceFrameLocalUnits.maxY),
                )
            }
            // Control points within the local UIView viewport.
            // Expressed as unit values with upper-left origin.
            //
            // ********************** C1 **
            // *                          *
            // *            0,0           *
            // *            ********      *
            // *            *      *      *
            // *            ******** 1,1  *
            // *                          *
            // ** C2 **********************
            //
            let startPointViewportUnitsUL = convertFromGradientToLocal(startPointGradientUnitsUL)
            let endPointViewportUnitsUL = convertFromGradientToLocal(endPointGradientUnitsUL)

            // UIKit/UIView uses an upper-left origin.
            // Core Graphics/CALayer uses a lower-left origin.
            func convertToLayerUnit(_ point: CGPoint) -> CGPoint {
                // TODO: The documentation clearly indicates that
                // CAGradientLayer.startPoint and endPoint use the layer's
                // coordinate space with lower-left origin.  But the
                // observed behavior is that they use an upper-left origin.
                // I can't figure out why.
                // return CGPoint(x: point.x, y: (1 - point.y))
                return point
            }
            // Control points within the local CALayer viewport.
            // Expressed as unit values with lower-left origin.
            //
            // ********************** C1 **
            // *                          *
            // *                          *
            // *            ******** 1,1  *
            // *            *      *      *
            // *        0,0 ********      *
            // *                          *
            // ** C2 **********************
            //
            let startPointLayerUnitsLL = convertToLayerUnit(startPointViewportUnitsUL)
            let endPointLayerUnitsLL = convertToLayerUnit(endPointViewportUnitsUL)

            gradientLayer.startPoint = startPointLayerUnitsLL
            gradientLayer.endPoint = endPointLayerUnitsLL
        }

        // Bubble shape.
        if let bubbleConfig {
            let gap = bubbleGap?()

            // Corners.
            maskLayer.path = bubbleConfig.bubblePath(for: bounds, gap: gap).cgPath
            layer.mask = maskLayer

            // Stroke.
            if
                let stroke = bubbleConfig.stroke,
                let strokePath = bubbleConfig.strokePath(for: bounds, gap: gap)
            {
                strokeLayer.lineWidth = stroke.width
                strokeLayer.strokeColor = stroke.color.cgColor
                strokeLayer.path = strokePath.cgPath
                layer.addSublayer(strokeLayer)
            } else {
                strokeLayer.removeFromSuperlayer()
            }
        } else {
            layer.mask = nil

            strokeLayer.removeFromSuperlayer()
        }

        ensureSubviewLayout()
    }

    override public func reset() {
        super.reset()

        referenceView = nil
        value = nil
        backgroundColor = nil
        bubbleConfig = nil
        bubbleGap = nil
        strokeLayer.removeFromSuperlayer()
        gradientLayer.removeFromSuperlayer()
        dimmerLayer?.removeFromSuperlayer()
    }

    // MARK: - CALayerDelegate

    override public func action(for layer: CALayer, forKey event: String) -> CAAction? {
        // Disable all implicit CALayer animations if needed
        if animationsEnabled {
            return super.action(for: layer, forKey: event)
        } else {
            return NSNull()
        }

    }

    // MARK: - CVDimmableView

    var dimmerColor: UIColor = .clear

    var dimsContent = false

    var backgroundLayer: CALayer? { gradientLayer }
}

// MARK: -

extension CVColorOrGradientView: OWSBubbleViewHost {

    public var maskPath: UIBezierPath {
        guard let bubbleConfig else {
            return UIBezierPath(rect: bounds)
        }
        return bubbleConfig.bubblePath(for: bounds)
    }

    public var bubbleReferenceView: UIView { self }
}

// MARK: - Tellomi（tellomi/tellomi#1257）

/// 气泡里给横滑相册挖空的那一段：气泡自己坐标里的上下边界。
struct CVBubbleGap: Equatable {
    let top: CGFloat
    let bottom: CGFloat

    func offsetBy(dy: CGFloat) -> CVBubbleGap {
        CVBubbleGap(top: top + dy, bottom: bottom + dy)
    }
}

extension BubbleConfiguration {
    /// 挖掉 `gap` 后剩下的上下两块，各自按本配置的圆角画；两块都没有（只有相册）时是空路径。
    func bubblePath(for rect: CGRect, gap: CVBubbleGap?) -> UIBezierPath {
        guard let gap else {
            return bubblePath(for: rect)
        }
        let path = UIBezierPath()
        let top = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: gap.top - rect.minY)
        if top.height >= 1 {
            path.append(bubblePath(for: top))
        }
        let bottom = CGRect(x: rect.minX, y: gap.bottom, width: rect.width, height: rect.maxY - gap.bottom)
        if bottom.height >= 1 {
            path.append(bubblePath(for: bottom))
        }
        return path
    }

    func strokePath(for rect: CGRect, gap: CVBubbleGap?) -> UIBezierPath? {
        guard stroke != nil else {
            return nil
        }
        return bubblePath(for: rect, gap: gap)
    }
}
