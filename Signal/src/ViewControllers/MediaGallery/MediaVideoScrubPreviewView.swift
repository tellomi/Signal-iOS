//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import AVFoundation
import SignalServiceKit
import SignalUI

/// Tellomi（tellomi/tellomi#1257，owner 2026-09-25「拖动到什么位置的时候显示这一帧的视频的缩略图」，照 Telegram）：
/// 拖进度条时，在拇指正上方显示拖到的那一帧。
///
/// - 取帧：给这个附件单独开一份边解密边读的 AVAsset（`AttachmentStream.decryptedAVAsset()`：不落明文，也不和正在播的那份抢着读），
///   用 `AVAssetImageGenerator` 取离得最近的关键帧（快；同 Telegram，同 Android 的 CLOSEST_SYNC）。
///   同一时间只解一帧；解的过程中手指又挪了，只记最新的位置，这一帧解完接着解它（中间的丢掉，不会一直取消到一帧都出不来）。
/// - 摆放（Telegram `ChatItemGalleryFooterContentNode.updateLayout`）：横的放进 160×90、竖的放进 90×160，按比例；
///   底边在进度胶囊上方 6，水平中心对着拇指，离屏幕两边至少 10；圆角 6。第一帧出来才显示，松手淡出。
final class MediaVideoScrubPreviewView: UIImageView {

    private enum Metrics {
        static let landscapeFitSize = CGSize(width: 160, height: 90)
        static let portraitFitSize = CGSize(width: 90, height: 160)
        static let gapAbovePill: CGFloat = 6
        static let edgeMargin: CGFloat = 10
        static let cornerRadius: CGFloat = 6
        /// 取帧的最大像素边：长边 160 × 屏幕 2～3 倍，够清楚。
        static let maximumImageSize = CGSize(width: 480, height: 480)
    }

    private var attachmentStream: AttachmentStream?
    private var generator: AVAssetImageGenerator?

    /// 换视频、松手都会加一，旧的取帧结果回来时一看不对就丢掉。
    private var session = 0
    private var isActive = false
    private var isGenerating = false
    private var pendingTime: CMTime?
    private var anchor: (thumbCenterX: CGFloat, pillTop: CGFloat)?

    init() {
        super.init(frame: .zero)
        contentMode = .scaleAspectFill
        clipsToBounds = true
        layer.cornerRadius = Metrics.cornerRadius
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 换成另一个视频（nil = 当前不是可播的视频）。
    func configure(attachmentStream: AttachmentStream?) {
        guard attachmentStream?.attachment.id != self.attachmentStream?.attachment.id else { return }
        self.attachmentStream = attachmentStream
        generator?.cancelAllCGImageGeneration()
        generator = nil
        hide(animated: false)
    }

    /// 拖动中：拇指中心 x、进度胶囊顶边 y 都是父视图坐标。
    func show(at time: CMTime, thumbCenterX: CGFloat, pillTop: CGFloat) {
        isActive = true
        anchor = (thumbCenterX, pillTop)
        layoutForAnchor()
        pendingTime = time
        generateNextFrameIfIdle()
    }

    func hide(animated: Bool = true) {
        session += 1
        isActive = false
        pendingTime = nil
        anchor = nil
        guard !isHidden else {
            image = nil
            return
        }
        guard animated else {
            isHidden = true
            image = nil
            return
        }
        let hidingSession = session
        UIView.animate(withDuration: 0.1, animations: {
            self.alpha = 0
        }, completion: { _ in
            guard hidingSession == self.session, !self.isActive else { return }
            self.isHidden = true
            self.alpha = 1
            self.image = nil
        })
    }

    // MARK: -

    private func generatorIfPossible() -> AVAssetImageGenerator? {
        if let generator {
            return generator
        }
        guard let attachmentStream, let asset = try? attachmentStream.decryptedAVAsset() else {
            return nil
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = Metrics.maximumImageSize
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        self.generator = generator
        return generator
    }

    private func generateNextFrameIfIdle() {
        guard !isGenerating, let time = pendingTime, let generator = generatorIfPossible() else { return }
        pendingTime = nil
        isGenerating = true
        let requestSession = session
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { [weak self] _, cgImage, _, result, _ in
            let image: UIImage? = if result == .succeeded, let cgImage { UIImage(cgImage: cgImage) } else { nil }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isGenerating = false
                if requestSession == self.session, self.isActive, let image {
                    self.display(image)
                }
                self.generateNextFrameIfIdle()
            }
        }
    }

    private func display(_ image: UIImage) {
        self.image = image
        layoutForAnchor()
        if isHidden {
            alpha = 0
            isHidden = false
            UIView.animate(withDuration: 0.1) {
                self.alpha = 1
            }
        } else {
            // 刚松手又按下：打断还没做完的淡出。
            layer.removeAllAnimations()
            alpha = 1
        }
    }

    private func layoutForAnchor() {
        guard let superview, let anchor, let image, image.size.width > 0, image.size.height > 0 else { return }
        let fitSize = image.size.width < image.size.height ? Metrics.portraitFitSize : Metrics.landscapeFitSize
        let scale = min(fitSize.width / image.size.width, fitSize.height / image.size.height)
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let minX = superview.safeAreaInsets.left + Metrics.edgeMargin
        let maxX = superview.bounds.width - superview.safeAreaInsets.right - Metrics.edgeMargin - size.width
        let x = max(min(anchor.thumbCenterX - size.width / 2, maxX), minX)
        frame = CGRect(x: x.rounded(), y: anchor.pillTop - Metrics.gapAbovePill - size.height, width: size.width, height: size.height)
    }
}

#if TESTABLE_BUILD

extension MediaVideoScrubPreviewView {
    /// 预览帧正在显示（且已有图）。
    var isShowingFrameForTesting: Bool { !isHidden && image != nil && alpha > 0 }
}

#endif
