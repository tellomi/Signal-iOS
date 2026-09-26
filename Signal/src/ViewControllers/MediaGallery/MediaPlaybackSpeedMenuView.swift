//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

/// Tellomi（tellomi/tellomi#1257，owner 2026-09-25，照 Telegram 视频齿轮里的倍速）：
///
/// - 上面「速度」滑杆 0.2x–2.5x，步长 0.1，拖动即生效（Telegram `SliderContextItem(minValue: 0.2, maxValue: 2.5)`）；
/// - 下面 0.5x / 正常 / 1.5x / 2x（Telegram `speedList`），当前那档打勾，点一档就收起；点面板外面也收起。
///
/// 面板从齿轮按钮正上方弹出。倍速只在这次查看器里生效、不写设置（值由 MediaPageViewController 保存）。
/// 与 Android 的 PlaybackSpeedPopup 同一套档位和范围。
final class MediaPlaybackSpeedMenuView: UIView, UIGestureRecognizerDelegate {

    static let minimumSpeed: Float = 0.2
    static let maximumSpeed: Float = 2.5
    static let presets: [Float] = [0.5, 1, 1.5, 2]

    private enum Metrics {
        static let panelWidth: CGFloat = 250
        static let rowHeight: CGFloat = 44
        static let horizontalPadding: CGFloat = 16
        static let gapAboveSource: CGFloat = 8
        static let screenMargin: CGFloat = 12
        static let cornerRadius: CGFloat = 16
    }

    /// 1.5x、2x、0.7x（同 Android 的 formatPlaybackSpeed）。
    static func formatSpeed(_ speed: Float) -> String {
        let rounded = (speed * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return "\(Int(rounded))x"
        }
        return String(format: "%.1fx", rounded)
    }

    private static func snapped(_ speed: Float) -> Float {
        min(max((speed * 10).rounded() / 10, minimumSpeed), maximumSpeed)
    }

    private let panel = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
    private let titleLabel = UILabel()
    private let valueLabel = UILabel()
    private let slider = UISlider()
    private var optionRows = [OptionRow]()

    private var speed: Float
    private let onChange: (Float) -> Void
    private weak var sourceView: UIView?

    init(speed: Float, sourceView: UIView, onChange: @escaping (Float) -> Void) {
        self.speed = Self.snapped(speed)
        self.sourceView = sourceView
        self.onChange = onChange
        super.init(frame: .zero)

        let tapOutside = UITapGestureRecognizer(target: self, action: #selector(didTapOutside))
        tapOutside.delegate = self
        addGestureRecognizer(tapOutside)

        // 开着时读屏只读这块面板（查看器其余部分先不读），两指 Z 手势收起。
        accessibilityViewIsModal = true

        panel.clipsToBounds = true
        panel.layer.cornerRadius = Metrics.cornerRadius
        addSubview(panel)

        titleLabel.text = OWSLocalizedString("MEDIA_VIEWER_TELLOMI_SPEED", comment: "Title of the playback speed slider in the video viewer.")
        titleLabel.font = .dynamicTypeBody
        titleLabel.textColor = .Signal.label
        titleLabel.isAccessibilityElement = false

        valueLabel.font = .monospacedDigitSystemFont(ofSize: UIFont.dynamicTypeBody.pointSize, weight: .regular)
        valueLabel.textColor = .Signal.secondaryLabel
        valueLabel.textAlignment = .right
        valueLabel.isAccessibilityElement = false

        let headerRow = UIStackView(arrangedSubviews: [titleLabel, valueLabel])
        headerRow.axis = .horizontal
        headerRow.alignment = .center
        headerRow.isLayoutMarginsRelativeArrangement = true
        headerRow.directionalLayoutMargins = .init(top: 12, leading: Metrics.horizontalPadding, bottom: 0, trailing: Metrics.horizontalPadding)

        slider.minimumValue = Self.minimumSpeed
        slider.maximumValue = Self.maximumSpeed
        slider.minimumTrackTintColor = .Signal.label
        slider.maximumTrackTintColor = .Signal.quaternaryLabel
        slider.accessibilityLabel = titleLabel.text
        slider.addAction(UIAction { [weak self] _ in self?.sliderValueChanged() }, for: .valueChanged)
        let sliderRow = UIStackView(arrangedSubviews: [slider])
        sliderRow.isLayoutMarginsRelativeArrangement = true
        sliderRow.directionalLayoutMargins = .init(top: 4, leading: Metrics.horizontalPadding, bottom: 8, trailing: Metrics.horizontalPadding)

        let separator = UIView()
        separator.backgroundColor = .Signal.opaqueSeparator
        separator.heightAnchor.constraint(equalToConstant: 0.5).isActive = true

        optionRows = Self.presets.map { preset in
            let title = abs(preset - 1) < 0.01
                ? OWSLocalizedString("MEDIA_VIEWER_TELLOMI_SPEED_NORMAL", comment: "Playback speed option in the video viewer: normal speed (1x).")
                : Self.formatSpeed(preset)
            let row = OptionRow(title: title, height: Metrics.rowHeight, horizontalPadding: Metrics.horizontalPadding)
            row.addAction(UIAction { [weak self] _ in self?.didSelectPreset(preset) }, for: .touchUpInside)
            return row
        }

        let stackView = UIStackView(arrangedSubviews: [headerRow, sliderRow, separator] + optionRows)
        stackView.axis = .vertical
        stackView.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: panel.contentView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: panel.contentView.bottomAnchor, constant: -4),
            stackView.widthAnchor.constraint(equalToConstant: Metrics.panelWidth),
        ])

        updateContents()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(in container: UIView) {
        frame = container.bounds
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(self)
        layoutPanel()

        panel.alpha = 0
        panel.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        UIView.animate(withDuration: 0.2, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
            self.panel.alpha = 1
            self.panel.transform = .identity
        }
        UIAccessibility.post(notification: .screenChanged, argument: slider)
    }

    func dismiss(animated: Bool = true) {
        guard superview != nil else { return }
        guard animated else {
            removeFromSuperview()
            return
        }
        isUserInteractionEnabled = false
        UIView.animate(withDuration: 0.15, animations: {
            self.panel.alpha = 0
            self.panel.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        }, completion: { _ in
            self.removeFromSuperview()
        })
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutPanel()
    }

    override func accessibilityPerformEscape() -> Bool {
        dismiss()
        return true
    }

    // MARK: -

    private func layoutPanel() {
        guard let sourceView, sourceView.window != nil else { return }
        let panelSize = panel.systemLayoutSizeFitting(
            CGSize(width: Metrics.panelWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel,
        )
        let sourceFrame = sourceView.convert(sourceView.bounds, to: self)
        let minX = safeAreaInsets.left + Metrics.screenMargin
        let maxX = bounds.width - safeAreaInsets.right - Metrics.screenMargin - panelSize.width
        let x = max(min(sourceFrame.midX - panelSize.width / 2, maxX), minX)
        let y = max(sourceFrame.minY - Metrics.gapAboveSource - panelSize.height, safeAreaInsets.top + Metrics.screenMargin)
        // 变形动画进行中不能直接改 frame，改 bounds + center。
        panel.bounds = CGRect(origin: .zero, size: panelSize)
        panel.center = CGPoint(x: (x + panelSize.width / 2).rounded(), y: (y + panelSize.height / 2).rounded())
    }

    private func updateContents() {
        valueLabel.text = Self.formatSpeed(speed)
        slider.value = speed
        slider.accessibilityValue = Self.formatSpeed(speed)
        for (row, preset) in zip(optionRows, Self.presets) {
            row.isChecked = abs(preset - speed) < 0.05
        }
    }

    private func sliderValueChanged() {
        let newSpeed = Self.snapped(slider.value)
        slider.value = newSpeed
        guard newSpeed != speed else { return }
        speed = newSpeed
        updateContents()
        onChange(newSpeed)
    }

    private func didSelectPreset(_ preset: Float) {
        speed = preset
        updateContents()
        onChange(preset)
        dismiss()
    }

    @objc
    private func didTapOutside() {
        dismiss()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let touchedView = touch.view else { return true }
        return !touchedView.isDescendant(of: panel)
    }

    // MARK: - Row

    private final class OptionRow: UIControl {
        private let titleLabel = UILabel()
        private let checkmarkView = UIImageView(image: Theme.iconImage(.checkmark))
        private let title: String

        var isChecked = false {
            didSet {
                checkmarkView.isHidden = !isChecked
                accessibilityTraits = isChecked ? [.button, .selected] : .button
            }
        }

        init(title: String, height: CGFloat, horizontalPadding: CGFloat) {
            self.title = title
            super.init(frame: .zero)

            titleLabel.text = title
            titleLabel.font = .dynamicTypeBody
            titleLabel.textColor = .Signal.label
            checkmarkView.tintColor = .Signal.label
            checkmarkView.isHidden = true

            for subview in [titleLabel, checkmarkView] {
                subview.translatesAutoresizingMaskIntoConstraints = false
                subview.isUserInteractionEnabled = false
                addSubview(subview)
            }
            NSLayoutConstraint.activate([
                heightAnchor.constraint(greaterThanOrEqualToConstant: height),
                titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalPadding),
                titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
                titleLabel.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 8),
                checkmarkView.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
                checkmarkView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalPadding),
                checkmarkView.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])

            isAccessibilityElement = true
            accessibilityLabel = title
            accessibilityTraits = .button
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var isHighlighted: Bool {
            didSet {
                backgroundColor = isHighlighted ? .Signal.secondaryFill : .clear
            }
        }

        var titleForTesting: String { title }
    }
}

#if TESTABLE_BUILD

extension MediaPlaybackSpeedMenuView {
    var panelFrameForTesting: CGRect { panel.frame }
    var optionTitlesForTesting: [String] { optionRows.map(\.titleForTesting) }
    var checkedOptionTitleForTesting: String? { optionRows.first(where: \.isChecked)?.titleForTesting }
    var valueTextForTesting: String? { valueLabel.text }
    var titleTextForTesting: String? { titleLabel.text }

    func selectOptionForTesting(at index: Int) {
        didSelectPreset(Self.presets[index])
    }

    func setSliderValueForTesting(_ value: Float) {
        slider.value = value
        sliderValueChanged()
    }
}

#endif
