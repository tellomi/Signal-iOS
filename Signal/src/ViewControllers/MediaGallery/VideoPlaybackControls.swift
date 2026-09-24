//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import AVFoundation
import CoreMedia
import SignalServiceKit
import SignalUI

protocol VideoPlaybackControlViewDelegate: AnyObject {
    // Single Actions
    func videoPlaybackControlViewDidTapPlayPause(_ videoPlaybackControlView: VideoPlaybackControlView)
    func videoPlaybackControlViewDidTapRewind(_ videoPlaybackControlView: VideoPlaybackControlView, duration: TimeInterval)
    func videoPlaybackControlViewDidTapFastForward(_ videoPlaybackControlView: VideoPlaybackControlView, duration: TimeInterval)

    // Continuous Actions
    func videoPlaybackControlViewDidStartRewind(_ videoPlaybackControlView: VideoPlaybackControlView)
    func videoPlaybackControlViewDidStartFastForward(_ videoPlaybackControlView: VideoPlaybackControlView)
    func videoPlaybackControlViewDidStopRewindOrFastForward(_ videoPlaybackControlView: VideoPlaybackControlView)
}

class VideoPlaybackControlView: UIView {

    // MARK: Subviews

    private func titleForRewindAndFFBUttons() -> NSAttributedString {
        let string = NumberFormatter.localizedString(
            from: Int(Self.rewindAndFastForwardSkipDuration) as NSNumber,
            number: .decimal,
        )
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        return NSAttributedString(string: string, attributes: [
            .kern: -1,
            .font: UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold),
            .paragraphStyle: paragraphStyle,
        ])
    }

    // Size must match same constant in `MediaControlPanelView`.
    private static let buttonContentInset: CGFloat = if #available(iOS 26, *) { 10 } else { 8 }

    private lazy var buttonPlay: UIButton = {
        let button = UIButton(configuration: .plain(), primaryAction: UIAction { [weak self] _ in
            self?.didTapPlay()
        })
        button.configuration?.image = .init(imageLiteralResourceName: "play-fill")
        button.configuration?.contentInsets = .init(margin: Self.buttonContentInset)
        button.setContentHuggingHigh()
        button.setCompressionResistanceHigh()
        return button
    }()

    private lazy var buttonPause: UIButton = {
        let button = UIButton(configuration: .plain(), primaryAction: UIAction { [weak self] _ in
            self?.didTapPause()
        })
        button.configuration?.image = .init(imageLiteralResourceName: "pause-fill")
        button.configuration?.contentInsets = .init(margin: Self.buttonContentInset)
        button.setContentHuggingHigh()
        button.setCompressionResistanceHigh()
        return button
    }()

    private lazy var buttonRewind: UIButton = {
        let button = RewindAndFFButton(type: .system)
        button.setImage(.init(imageLiteralResourceName: "skip-backward"), for: .normal)
        button.setAttributedTitle(titleForRewindAndFFBUttons(), for: .normal)
        button.addAction(UIAction { [weak self] _ in self?.didTapRewind() }, for: .touchDown)
        button.addAction(UIAction { [weak self] _ in self?.didReleaseRewind() }, for: .touchUpInside)
        button.addAction(UIAction { [weak self] _ in self?.didCancelRewindOrFF() }, for: [.touchCancel, .touchUpOutside])
        return button
    }()

    private lazy var buttonFastForward: UIButton = {
        let button = RewindAndFFButton(type: .system)
        button.setImage(.init(imageLiteralResourceName: "skip-forward"), for: .normal)
        button.setAttributedTitle(titleForRewindAndFFBUttons(), for: .normal)
        button.addAction(UIAction { [weak self] _ in self?.didTapFastForward() }, for: .touchDown)
        button.addAction(UIAction { [weak self] _ in self?.didReleaseFastForward() }, for: .touchUpInside)
        button.addAction(UIAction { [weak self] _ in self?.didCancelRewindOrFF() }, for: [.touchCancel, .touchUpOutside])
        return button
    }()

    private var glassBackgroundView: UIVisualEffectView?

    @available(iOS 26, *)
    private func glassEffect() -> UIVisualEffect? {
        let glassEffect = UIGlassEffect(style: .regular)
        glassEffect.isInteractive = true
        return glassEffect
    }

    // MARK: UIView

    override init(frame: CGRect) {
        super.init(frame: frame)

        semanticContentAttribute = .playback

        let selfOrVisualEffectContentView: UIView

        // Glass background.
        if #available(iOS 26, *) {
            let glassEffectView = UIVisualEffectView(effect: glassEffect())
            glassEffectView.clipsToBounds = true
            glassEffectView.cornerConfiguration = .capsule()
            glassEffectView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(glassEffectView)
            NSLayoutConstraint.activate([
                glassEffectView.topAnchor.constraint(equalTo: topAnchor),
                glassEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
                glassEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
                glassEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])

            selfOrVisualEffectContentView = glassEffectView.contentView
            glassBackgroundView = glassEffectView
        } else {
            selfOrVisualEffectContentView = self
        }

        let buttons = [buttonRewind, buttonPlay, buttonPause, buttonFastForward]
        buttons.forEach { button in
            button.translatesAutoresizingMaskIntoConstraints = false
            selfOrVisualEffectContentView.addSubview(button)
        }

        // Default state for Play / Pause
        buttonPlay.isHidden = isVideoPlaying
        buttonPause.isHidden = !isVideoPlaying
        buttonRewind.isHidden = true
        buttonFastForward.isHidden = true

        // Permanent layout constraints.
        NSLayoutConstraint.activate([
            buttonPlay.centerYAnchor.constraint(equalTo: centerYAnchor),
            buttonPlay.topAnchor.constraint(equalTo: topAnchor),
            buttonPlay.heightAnchor.constraint(equalTo: buttonPlay.widthAnchor),

            buttonPause.centerXAnchor.constraint(equalTo: buttonPlay.centerXAnchor),
            buttonPause.centerYAnchor.constraint(equalTo: buttonPlay.centerYAnchor),
            buttonPause.heightAnchor.constraint(equalTo: buttonPlay.heightAnchor),
            buttonPause.widthAnchor.constraint(equalTo: buttonPause.heightAnchor),

            buttonRewind.centerYAnchor.constraint(equalTo: buttonPlay.centerYAnchor),
            buttonRewind.heightAnchor.constraint(equalTo: buttonPlay.heightAnchor),
            buttonRewind.widthAnchor.constraint(equalTo: buttonRewind.heightAnchor),

            buttonFastForward.centerYAnchor.constraint(equalTo: buttonPlay.centerYAnchor),
            buttonFastForward.heightAnchor.constraint(equalTo: buttonPlay.heightAnchor),
            buttonFastForward.widthAnchor.constraint(equalTo: buttonFastForward.heightAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateConstraints() {
        super.updateConstraints()
        if let buttonLayoutConstraints {
            NSLayoutConstraint.deactivate(buttonLayoutConstraints)
        }
        let constraints = layoutConstraintsForCurrentConfiguration()
        NSLayoutConstraint.activate(constraints)
        buttonLayoutConstraints = constraints
    }

    // MARK: Public

    weak var delegate: VideoPlaybackControlViewDelegate?

    func updateWithMediaItem(_ mediaItem: MediaGalleryItem) {
        switch mediaItem.referencedAttachment.attachment.contentType {
        case .video:
            if
                let videoDuration = mediaItem.referencedAttachment.asReferencedStream?.attachmentStream.cachedVideoDuration,
                videoDuration > 30
            {
                showRewindAndFastForward = true
            } else {
                showRewindAndFastForward = false
            }
        case .file, .image, .audio:
            break
        }
    }

    private var isVideoPlaying = false
    private var animatePlayPauseTransition = false
    private var playPauseButtonAnimator: UIViewPropertyAnimator?

    func updateStatusWithPlayer(_ videoPlayer: VideoPlayer) {
        let isPlaying = videoPlayer.isPlaying

        guard isVideoPlaying != isPlaying else { return }

        isVideoPlaying = isPlaying

        // Only user-initiated playback state changes cause animated Play/Pause transition.
        guard animatePlayPauseTransition else {
            // Do nothing if there is an active animation in progress.
            // Playback status will be refreshed upon animation completion.
            if playPauseButtonAnimator == nil {
                buttonPlay.isHidden = isPlaying
                buttonPause.isHidden = !isPlaying
            }
            return
        }

        // User might tap Play/Pause again before animation completes.
        // In that case previous animations are stopped and are replaced by new animations.
        if let playPauseButtonAnimator {
            playPauseButtonAnimator.stopAnimation(true)
            self.playPauseButtonAnimator = nil
        }

        let fromButton: UIButton // button that is currently visible, reflecting opposite to `isPlaying`
        let fromButtonTransform: CGAffineTransform
        let toButton: UIButton // button that should reflect `isPlaying` upon animation completion
        let toButtonTransform: CGAffineTransform
        if isPlaying {
            fromButton = buttonPlay
            fromButtonTransform = .scale(0.1).rotated(by: 0.5 * .pi)
            toButton = buttonPause
            toButtonTransform = .scale(0.1).rotated(by: -0.5 * .pi)
        } else {
            fromButton = buttonPause
            fromButtonTransform = .scale(0.1).rotated(by: -0.5 * .pi)
            toButton = buttonPlay
            toButtonTransform = .scale(0.1).rotated(by: 0.5 * .pi)
        }
        // Prepare initial state for appearing button
        toButton.isHidden = false
        toButton.alpha = 0
        toButton.transform = toButtonTransform

        let animator = UIViewPropertyAnimator(duration: 0.3, springDamping: 0.7, springResponse: 0.3)
        animator.addAnimations {
            toButton.alpha = 1
            toButton.transform = .identity
        }
        animator.addAnimations {
            fromButton.alpha = 0
            fromButton.transform = fromButtonTransform
        }
        animator.addCompletion { [weak self] _ in
            fromButton.isHidden = true
            fromButton.alpha = 1
            fromButton.transform = .identity

            self?.playPauseButtonAnimator = nil
            self?.updateStatusWithPlayer(videoPlayer)
        }
        animator.startAnimation()

        playPauseButtonAnimator = animator
        animatePlayPauseTransition = false
    }

    // MARK: Animations

    private var viewsForOpacityAnimation: [UIView] {
        [buttonRewind, buttonPlay, buttonPause, buttonFastForward].filter { $0.isHidden == false }
    }

    func prepareToBeAnimatedIn() {
        if #available(iOS 26, *), let glassBackgroundView {
            glassBackgroundView.effect = nil
        }
        viewsForOpacityAnimation.forEach { $0.alpha = 0 }
        isHidden = false
    }

    func animateIn() {
        if #available(iOS 26, *), let glassBackgroundView {
            glassBackgroundView.effect = glassEffect()
        }
        viewsForOpacityAnimation.forEach { $0.alpha = 1 }
    }

    func animateOut() {
        if #available(iOS 26, *), let glassBackgroundView {
            glassBackgroundView.effect = nil
        }
        viewsForOpacityAnimation.forEach { $0.alpha = 0 }
    }

    // MARK: Helpers

    private var mediaItem: MediaGalleryItem?

    private var showRewindAndFastForward = false {
        didSet {
            guard oldValue != showRewindAndFastForward else { return }
            buttonRewind.isHidden = !showRewindAndFastForward
            buttonFastForward.isHidden = !showRewindAndFastForward
            setNeedsUpdateConstraints()
        }
    }

    private var buttonLayoutConstraints: [NSLayoutConstraint]?

    private static let horizontalMargin: CGFloat = 6
    private static let buttonSpacing: CGFloat = 12

    private func layoutConstraintsForCurrentConfiguration() -> [NSLayoutConstraint] {
        guard showRewindAndFastForward else {
            // |[Play]|
            return [
                buttonPlay.leadingAnchor.constraint(equalTo: leadingAnchor),
                buttonPlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            ]
        }

        // |[Rewind] [Play] [FastF]|
        return [
            buttonRewind.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalMargin),
            buttonPlay.leadingAnchor.constraint(equalTo: buttonRewind.trailingAnchor, constant: Self.buttonSpacing),
            buttonFastForward.leadingAnchor.constraint(equalTo: buttonPlay.trailingAnchor, constant: Self.buttonSpacing),
            buttonFastForward.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalMargin),
        ]
    }

    private var tapAndHoldTimer: Timer?
    private var isRewindInProgress = false
    private var isFastForwardInProgress = false
    private static let rewindAndFastForwardSkipDuration: TimeInterval = 15

    private func startContinuousRewind() {
        guard !isRewindInProgress, !isFastForwardInProgress else { return }

        let animator = UIViewPropertyAnimator(duration: 0.3, springDamping: 0.7, springResponse: 0.3)
        animator.addAnimations {
            self.buttonRewind.transform = .rotate(-0.5 * .pi)
        }
        animator.startAnimation()

        isRewindInProgress = true
        delegate?.videoPlaybackControlViewDidStartRewind(self)
    }

    private func startContinuousFastForward() {
        guard !isRewindInProgress, !isFastForwardInProgress else { return }

        let animator = UIViewPropertyAnimator(duration: 0.3, springDamping: 0.7, springResponse: 0.3)
        animator.addAnimations {
            self.buttonFastForward.transform = .rotate(0.5 * .pi)
        }
        animator.startAnimation()

        isFastForwardInProgress = true
        delegate?.videoPlaybackControlViewDidStartFastForward(self)
    }

    private func stopContinuousRewindOrFastForward() {
        guard isRewindInProgress || isFastForwardInProgress else { return }

        let animator = UIViewPropertyAnimator(duration: 0.3, springDamping: 0.7, springResponse: 0.3)
        if isRewindInProgress {
            animator.addAnimations {
                self.buttonRewind.transform = .identity
            }
            isRewindInProgress = false
        }
        if isFastForwardInProgress {
            animator.addAnimations {
                self.buttonFastForward.transform = .identity
            }
            isFastForwardInProgress = false
        }
        animator.startAnimation()

        delegate?.videoPlaybackControlViewDidStopRewindOrFastForward(self)
    }

    // MARK: Actions

    private func didTapPlay() {
        guard !isRewindInProgress, !isFastForwardInProgress else { return }

        animatePlayPauseTransition = true
        delegate?.videoPlaybackControlViewDidTapPlayPause(self)
    }

    private func didTapPause() {
        guard !isRewindInProgress, !isFastForwardInProgress else { return }

        animatePlayPauseTransition = true
        delegate?.videoPlaybackControlViewDidTapPlayPause(self)
    }

    private func didTapRewind() {
        guard !isRewindInProgress, !isFastForwardInProgress, tapAndHoldTimer == nil else { return }

        tapAndHoldTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false, block: { [weak self] timer in
            guard let self else { return }
            self.startContinuousRewind()
            self.tapAndHoldTimer = nil
        })
    }

    private func didReleaseRewind() {
        // Timer not yet fired - single tap.
        if let tapAndHoldTimer {
            tapAndHoldTimer.invalidate()
            self.tapAndHoldTimer = nil
            delegate?.videoPlaybackControlViewDidTapRewind(self, duration: Self.rewindAndFastForwardSkipDuration)
            return
        }
        stopContinuousRewindOrFastForward()
    }

    private func didTapFastForward() {
        guard !isRewindInProgress, !isFastForwardInProgress, tapAndHoldTimer == nil else { return }

        tapAndHoldTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false, block: { [weak self] timer in
            guard let self else { return }
            self.startContinuousFastForward()
            self.tapAndHoldTimer = nil
        })
    }

    private func didReleaseFastForward() {
        // Timer not yet fired - single tap.
        if let tapAndHoldTimer {
            tapAndHoldTimer.invalidate()
            self.tapAndHoldTimer = nil
            delegate?.videoPlaybackControlViewDidTapFastForward(self, duration: Self.rewindAndFastForwardSkipDuration)
            return
        }
        stopContinuousRewindOrFastForward()
    }

    private func didCancelRewindOrFF() {
        if let tapAndHoldTimer {
            tapAndHoldTimer.invalidate()
            self.tapAndHoldTimer = nil
        }
        stopContinuousRewindOrFastForward()
    }

    private class RewindAndFFButton: UIButton {

        override func layoutSubviews() {
            super.layoutSubviews()
            if let titleLabel, let imageView {
                imageView.center = bounds.center
                titleLabel.bounds = imageView.bounds
                titleLabel.center = imageView.center.offsetBy(dx: -1)
            }
        }
    }
}

protocol PlayerProgressViewDelegate: AnyObject {
    func playerProgressViewDidStartScrubbing(_ playerProgressBar: PlayerProgressView)
    func playerProgressView(_ playerProgressView: PlayerProgressView, scrubbedToTime time: CMTime)
    func playerProgressView(_ playerProgressView: PlayerProgressView, didFinishScrubbingAtTime time: CMTime, shouldResumePlayback: Bool)
}

/// Tellomi（tellomi/tellomi#1257，owner 2026-09-25「多个视频点开时完全参考 Telegram 的设计」）：左边已播、右边总时长
/// （Telegram 右边其实是剩余时间，owner 要的是总时长）；按在条上任意位置就能拖，拖动时不暂停、只动左边时间和拇指，
/// 并通过 `delegate` 报给面板画那一帧的预览，松手才跳过去（同 Telegram）。平时没有拇指，按住才出现 14 的圆点。
class PlayerProgressView: UIView {

    weak var delegate: PlayerProgressViewDelegate?

    var videoPlayer: VideoPlayer? {
        willSet {
            if let avPlayer = videoPlayer?.avPlayer, let progressObserver {
                avPlayer.removeTimeObserver(progressObserver)
                self.progressObserver = nil
            }
        }
        didSet {
            guard let avPlayer = videoPlayer?.avPlayer else { return }

            guard let item = avPlayer.currentItem else {
                owsFailDebug("No player item")
                return
            }

            slider.minimumValue = 0
            slider.maximumValue = max(0.01, Float(CMTimeGetSeconds(item.asset.duration)))

            progressObserver = avPlayer.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 1 / 60, preferredTimescale: Self.preferredTimeScale),
                queue: nil,
                using: { [weak self] _ in
                    self?.updateState()
                },
            ) as AnyObject

            updateState()
        }
    }

    private var _hasGlassBackground: Bool = true

    @available(iOS 26, *)
    var hasGlassBackground: Bool {
        get { _hasGlassBackground }
        set {
            _hasGlassBackground = newValue
            updateBackground()
        }
    }

    private func createLabel() -> UILabel {
        let label = UILabel()
        label.font = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        label.textColor = .Signal.label
        label.setContentHuggingHorizontalHigh()
        label.setCompressionResistanceHorizontalHigh()
        return label
    }

    private lazy var positionLabel = createLabel()
    private lazy var durationLabel = createLabel()

    private lazy var slider: VideoPlaybackSlider = {
        let slider = VideoPlaybackSlider()
        slider.semanticContentAttribute = .playback
        slider.setThumbImage(UIImage(), for: .normal)
        slider.setThumbImage(UIImage(), for: .highlighted)
        slider.minimumTrackTintColor = .Signal.label
        slider.maximumTrackTintColor = .Signal.quaternaryLabel
        slider.onScrubBegan = { [weak self] in self?.handleScrubBegan() }
        slider.onScrubMoved = { [weak self] in self?.handleScrubMoved() }
        slider.onScrubEnded = { [weak self] in self?.handleScrubEnded() }
        // 只剩读屏的上下滑调整会发 valueChanged（手指拖动走上面三个回调）。
        slider.addAction(UIAction { [weak self] _ in self?.handleSliderValueChanged() }, for: .valueChanged)
        return slider
    }()

    // Glass on iOS 26, `nil` otherwise.
    private var glassBackgroundView: UIVisualEffectView?

    @available(iOS 26, *)
    private func interactiveGlassEffect() -> UIVisualEffect? {
        let glassEffect = UIGlassEffect(style: .regular)
        glassEffect.isInteractive = true
        return glassEffect
    }

    private weak var progressObserver: AnyObject?

    private static let preferredTimeScale: CMTimeScale = 100

    // MARK: UIView

    init() {
        super.init(frame: .zero)

        semanticContentAttribute = .playback

        let selfOrVisualEffectContentView: UIView
        if #available(iOS 26, *) {
            let glassEffectView = UIVisualEffectView(effect: interactiveGlassEffect())
            glassEffectView.translatesAutoresizingMaskIntoConstraints = false
            glassEffectView.clipsToBounds = true
            glassEffectView.contentView.semanticContentAttribute = .playback
            glassEffectView.cornerConfiguration = .capsule()
            addSubview(glassEffectView)
            NSLayoutConstraint.activate([
                glassEffectView.topAnchor.constraint(equalTo: topAnchor),
                glassEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
                glassEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
                glassEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])

            selfOrVisualEffectContentView = glassEffectView.contentView
            glassBackgroundView = glassEffectView
        } else {
            selfOrVisualEffectContentView = self
        }

        slider.translatesAutoresizingMaskIntoConstraints = false
        positionLabel.translatesAutoresizingMaskIntoConstraints = false
        durationLabel.translatesAutoresizingMaskIntoConstraints = false

        selfOrVisualEffectContentView.addSubview(slider)
        selfOrVisualEffectContentView.addSubview(positionLabel)
        selfOrVisualEffectContentView.addSubview(durationLabel)

        // |[X:XX] ========================= [X:XX]|

        // Extra margin on iOS 26 because of the glass background.
        let hMargin: CGFloat = if #available(iOS 26, *) { 16 } else { 0 }
        let height: CGFloat = if #available(iOS 26, *) { 44 } else { 36 }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: height),

            positionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: hMargin),
            positionLabel.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            positionLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            slider.topAnchor.constraint(equalTo: topAnchor),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            slider.leadingAnchor.constraint(equalTo: positionLabel.trailingAnchor, constant: 12),
            slider.trailingAnchor.constraint(equalTo: durationLabel.leadingAnchor, constant: -12),

            durationLabel.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            durationLabel.centerYAnchor.constraint(equalTo: positionLabel.centerYAnchor),
            durationLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -hMargin),
        ])

        // Panning is a no-op. We just absorb pan gesture's originating in the video controls
        // from propagating so we don't inadvertently change pages while trying to scrub in
        // the MediaPageView.
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: nil))
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @available(iOS 26, *)
    private func updateBackground() {
        if hasGlassBackground {
            if let glassBackgroundView, glassBackgroundView.effect == nil {
                glassBackgroundView.effect = interactiveGlassEffect()
            }
        } else {
            if let glassBackgroundView {
                glassBackgroundView.effect = nil
            }
        }
    }

    // MARK: Animations

    private var viewsForOpacityAnimation: [UIView] {
        [positionLabel, slider, durationLabel]
    }

    func prepareToBeAnimatedIn() {
        if #available(iOS 26, *), let glassBackgroundView, hasGlassBackground {
            glassBackgroundView.effect = nil
        }
        viewsForOpacityAnimation.forEach { $0.alpha = 0 }
        isHidden = false
    }

    func animateIn() {
        if #available(iOS 26, *), let glassBackgroundView, hasGlassBackground {
            glassBackgroundView.effect = interactiveGlassEffect()
        }
        viewsForOpacityAnimation.forEach { $0.alpha = 1 }
    }

    func animateOut() {
        if #available(iOS 26, *), let glassBackgroundView, hasGlassBackground {
            glassBackgroundView.effect = nil
        }
        viewsForOpacityAnimation.forEach { $0.alpha = 0 }
    }

    // MARK: Slider Handling

    /// 手指正按在条上（拖动中）。
    private(set) var isScrubbing = false

    private func time(slider: UISlider) -> CMTime {
        return CMTime(seconds: Double(slider.value), preferredTimescale: Self.preferredTimeScale)
    }

    /// 拇指中心（按当前滑块值）在 `view` 坐标系里的 x。
    func thumbCenterX(in view: UIView) -> CGFloat {
        let trackRect = slider.trackRect(forBounds: slider.bounds)
        let fraction: CGFloat = if slider.maximumValue > slider.minimumValue {
            CGFloat((slider.value - slider.minimumValue) / (slider.maximumValue - slider.minimumValue))
        } else {
            0
        }
        let x = trackRect.minX + fraction * trackRect.width
        return slider.convert(CGPoint(x: x, y: trackRect.midY), to: view).x
    }

    private func handleScrubBegan() {
        guard videoPlayer != nil else {
            owsFailBeta("player is nil")
            return
        }
        isScrubbing = true
        slider.setThumbImage(Self.scrubbingThumbImage, for: .normal)
        slider.setThumbImage(Self.scrubbingThumbImage, for: .highlighted)
        positionLabel.text = Self.formatPlaybackTime(Double(slider.value))
        delegate?.playerProgressViewDidStartScrubbing(self)
        delegate?.playerProgressView(self, scrubbedToTime: time(slider: slider))
    }

    private func handleScrubMoved() {
        guard isScrubbing else { return }
        positionLabel.text = Self.formatPlaybackTime(Double(slider.value))
        delegate?.playerProgressView(self, scrubbedToTime: time(slider: slider))
    }

    private func handleScrubEnded() {
        guard isScrubbing else { return }
        isScrubbing = false
        slider.setThumbImage(UIImage(), for: .normal)
        slider.setThumbImage(UIImage(), for: .highlighted)
        let sliderTime = time(slider: slider)
        videoPlayer?.seek(to: sliderTime)
        delegate?.playerProgressView(self, didFinishScrubbingAtTime: sliderTime, shouldResumePlayback: false)
    }

    private func handleSliderValueChanged() {
        guard let videoPlayer else {
            owsFailBeta("player is nil")
            return
        }
        guard !isScrubbing else { return }
        let sliderTime = time(slider: slider)
        videoPlayer.seek(to: sliderTime)
        positionLabel.text = Self.formatPlaybackTime(sliderTime.seconds)
    }

    /// 拖动时才出现的拇指：白色圆点带一点阴影（同系统滑块，深浅背景上都看得见）。
    private static let scrubbingThumbImage: UIImage = {
        let diameter: CGFloat = 14
        let shadowInset: CGFloat = 3
        let size = CGSize(width: diameter + 2 * shadowInset, height: diameter + 2 * shadowInset)
        return UIGraphicsImageRenderer(size: size).image { context in
            context.cgContext.setShadow(offset: CGSize(width: 0, height: 0.5), blur: 2, color: UIColor.black.withAlphaComponent(0.35).cgColor)
            UIColor.white.setFill()
            UIBezierPath(ovalIn: CGRect(x: shadowInset, y: shadowInset, width: diameter, height: diameter)).fill()
        }
    }()

    // MARK: Render cycle

    /// m:ss；一小时以上 h:mm:ss（同 Android 的 `formatPlaybackTime`）。
    static func formatPlaybackTime(_ seconds: Double) -> String {
        let totalSeconds = seconds.isFinite ? max(0, Int(seconds)) : 0
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let remainder = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }

    private func updateState() {
        guard let avPlayer = videoPlayer?.avPlayer else {
            owsFailDebug("player isn't set.")
            return
        }

        guard let item = avPlayer.currentItem else {
            owsFailDebug("player has no item.")
            return
        }

        let duration = item.asset.duration.seconds
        durationLabel.text = duration.isFinite && duration > 0 ? Self.formatPlaybackTime(duration) : "-:--"

        // 拖动中：左边时间和拇指跟着手指，不跟播放进度。
        guard !isScrubbing else { return }

        let position = avPlayer.currentTime()
        positionLabel.text = Self.formatPlaybackTime(position.seconds)
        slider.setValue(Float(position.seconds), animated: false)
    }

    // Overriden to allow to set custom track height.
    // Tellomi（#1257）：条细一些（6，同 Android）；按在条上任意位置就开始拖，拇指跟着手指的位置走（不是只能从拇指上拖）。
    private class VideoPlaybackSlider: UISlider {
        private static let trackHeight: CGFloat = 6

        var onScrubBegan: (() -> Void)?
        var onScrubMoved: (() -> Void)?
        var onScrubEnded: (() -> Void)?

        private func setValue(for touch: UITouch) {
            let trackRect = self.trackRect(forBounds: bounds)
            guard trackRect.width > 0 else { return }
            let fraction = min(max((touch.location(in: self).x - trackRect.minX) / trackRect.width, 0), 1)
            setValue(minimumValue + Float(fraction) * (maximumValue - minimumValue), animated: false)
        }

        override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            setValue(for: touch)
            onScrubBegan?()
            return true
        }

        override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            setValue(for: touch)
            onScrubMoved?()
            return true
        }

        override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
            if let touch {
                setValue(for: touch)
            }
            onScrubEnded?()
        }

        override func cancelTracking(with event: UIEvent?) {
            onScrubEnded?()
        }

        // 在条上横拖是拖进度：不让外层翻页、下拉关闭的拖动手势抢走。
        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer is UIPanGestureRecognizer, gestureRecognizer.view !== self {
                return false
            }
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }

        override var intrinsicContentSize: CGSize {
            CGSize(width: UIView.noIntrinsicMetric, height: Self.trackHeight)
        }

        override func trackRect(forBounds bounds: CGRect) -> CGRect {
            var rect = super.trackRect(forBounds: bounds)
            rect.size.height = Self.trackHeight
            rect.origin.y = (bounds.height - Self.trackHeight) / 2
            return rect
        }

        // 拇指中心按比例落在条上（不按系统的「两端各缩进半个拇指」），这样和手指、预览帧对得上。
        override func thumbRect(forBounds bounds: CGRect, trackRect rect: CGRect, value: Float) -> CGRect {
            let thumbRect = super.thumbRect(forBounds: bounds, trackRect: rect, value: value)
            let fraction: CGFloat = if maximumValue > minimumValue {
                CGFloat((value - minimumValue) / (maximumValue - minimumValue))
            } else {
                0
            }
            let centerX = rect.minX + min(max(fraction, 0), 1) * rect.width
            return CGRect(x: centerX - thumbRect.width / 2, y: thumbRect.minY, width: thumbRect.width, height: thumbRect.height)
        }
    }
}

#if TESTABLE_BUILD

// Tellomi（#1257）：给查看器判据用的入口（SignalTests/AlbumCarouselScreenshotTests）。
extension PlayerProgressView {
    var positionTextForTesting: String? { positionLabel.text }
    var durationTextForTesting: String? { durationLabel.text }

    /// 手指按在条上 `fraction` 处（0…1）；`isMove` 为 true 时当作按住后挪到这里。
    func scrubForTesting(toFraction fraction: Float, isMove: Bool) {
        slider.value = slider.minimumValue + fraction * (slider.maximumValue - slider.minimumValue)
        if isMove {
            handleScrubMoved()
        } else {
            handleScrubBegan()
        }
    }

    func endScrubForTesting() {
        handleScrubEnded()
    }
}

#endif
