//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import AVFoundation
import SignalServiceKit
import SignalUI

/// Tellomi（tellomi/tellomi#1257，owner 2026-09-25「多个视频点开时完全参考 Telegram 的设计」）：屏幕正中的播放 / 暂停，
/// 30 秒以上的视频两侧再有 后退 15 秒 / 前进 15 秒。尺寸照 Telegram `VideoPlaybackControlsComponent`（中间 92、两侧 64、间距 30）。
///
/// 跟着四角按钮一起出现、一起收起（由 MediaPageViewController 控制显隐）；图标跟着播放器的 `timeControlStatus` 走。
/// 替换上游每页一个的 92 播放键（MediaItemViewController）和底部胶囊里的播放 / 快进快退（VideoPlaybackControlView）。
final class MediaVideoCenterControlsView: UIView {

    private enum Metrics {
        static let centerButtonSize: CGFloat = 92
        static let sideButtonSize: CGFloat = 64
        static let spacing: CGFloat = 30
        static let skipInterval: TimeInterval = 15
        static let centerSymbolPointSize: CGFloat = 38
        static let sideSymbolPointSize: CGFloat = 26
    }

    private weak var videoPlayer: VideoPlayer?
    private var timeControlStatusObservation: NSKeyValueObservation?
    private(set) var isShowingPauseButton = false

    private lazy var playPauseButton = Self.makeButton(size: Metrics.centerButtonSize) { [weak self] in
        self?.didTapPlayPause()
    }

    private lazy var rewindButton: UIButton = {
        let button = Self.makeButton(size: Metrics.sideButtonSize) { [weak self] in
            self?.videoPlayer?.rewind(Metrics.skipInterval)
        }
        Self.setSymbol("gobackward.15", pointSize: Metrics.sideSymbolPointSize, on: button, size: Metrics.sideButtonSize)
        button.accessibilityLabel = OWSLocalizedString(
            "MEDIA_VIEWER_TELLOMI_SKIP_BACK",
            comment: "Accessibility label for the button in the center of the video viewer that jumps back 15 seconds.",
        )
        return button
    }()

    private lazy var fastForwardButton: UIButton = {
        let button = Self.makeButton(size: Metrics.sideButtonSize) { [weak self] in
            self?.videoPlayer?.fastForward(Metrics.skipInterval)
        }
        Self.setSymbol("goforward.15", pointSize: Metrics.sideSymbolPointSize, on: button, size: Metrics.sideButtonSize)
        button.accessibilityLabel = OWSLocalizedString(
            "MEDIA_VIEWER_TELLOMI_SKIP_FORWARD",
            comment: "Accessibility label for the button in the center of the video viewer that jumps forward 15 seconds.",
        )
        return button
    }()

    init() {
        super.init(frame: .zero)

        semanticContentAttribute = .playback

        let stackView = UIStackView(arrangedSubviews: [rewindButton, playPauseButton, fastForwardButton])
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = Metrics.spacing
        stackView.semanticContentAttribute = .playback
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        rewindButton.isHidden = true
        fastForwardButton.isHidden = true
        updatePlayPauseButton()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 换成当前页的视频（nil = 当前页不是可播的视频）。
    func bind(_ videoPlayer: VideoPlayer?, showsSkipButtons: Bool) {
        rewindButton.isHidden = !showsSkipButtons
        fastForwardButton.isHidden = !showsSkipButtons

        guard videoPlayer !== self.videoPlayer else {
            updatePlayPauseButton()
            return
        }
        self.videoPlayer = videoPlayer
        timeControlStatusObservation = videoPlayer?.avPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.updatePlayPauseButton()
            }
        }
        updatePlayPauseButton()
    }

    /// 播放结束、被别处暂停时由查看器叫一下（KVO 之外的兜底）。
    func updatePlayPauseButton() {
        let isPlaying = videoPlayer?.isPlaying ?? false
        isShowingPauseButton = isPlaying
        Self.setSymbol(
            isPlaying ? "pause.fill" : "play.fill",
            pointSize: Metrics.centerSymbolPointSize,
            on: playPauseButton,
            size: Metrics.centerButtonSize,
            // 三角形的视觉重心偏左，往右挪一点才显得居中（Telegram 同样做了偏移）。
            horizontalOffset: isPlaying ? 0 : 3,
        )
        playPauseButton.accessibilityLabel = isPlaying
            ? OWSLocalizedString("MEDIA_VIEWER_TELLOMI_PAUSE", comment: "Accessibility label for the pause button in the center of the video viewer.")
            : OWSLocalizedString("MEDIA_VIEWER_TELLOMI_PLAY", comment: "Accessibility label for the play button in the center of the video viewer.")
    }

    private func didTapPlayPause() {
        guard let videoPlayer else { return }
        if videoPlayer.isPlaying {
            videoPlayer.pause()
        } else {
            videoPlayer.play()
        }
        updatePlayPauseButton()
    }

    // MARK: -

    private static func makeButton(size: CGFloat, action: @escaping () -> Void) -> UIButton {
        let placeholder = UIImage()
        let button = UIButton(
            configuration: .roundMedia(image: placeholder, size: size),
            primaryAction: UIAction { _ in action() },
        )
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: size),
            button.heightAnchor.constraint(equalToConstant: size),
        ])
        return button
    }

    private static func setSymbol(
        _ name: String,
        pointSize: CGFloat,
        on button: UIButton,
        size: CGFloat,
        horizontalOffset: CGFloat = 0,
    ) {
        guard let image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)) else {
            owsFailDebug("Missing symbol \(name)")
            return
        }
        let horizontalMargin = 0.5 * (size - image.size.width)
        let verticalMargin = 0.5 * (size - image.size.height)
        button.configuration?.image = image
        button.configuration?.contentInsets = NSDirectionalEdgeInsets(
            top: verticalMargin,
            leading: horizontalMargin + horizontalOffset,
            bottom: verticalMargin,
            trailing: horizontalMargin - horizontalOffset,
        )
    }
}

#if TESTABLE_BUILD

extension MediaVideoCenterControlsView {
    var showsSkipButtonsForTesting: Bool { !rewindButton.isHidden && !fastForwardButton.isHidden }

    func tapPlayPauseForTesting() {
        didTapPlayPause()
    }
}

#endif
