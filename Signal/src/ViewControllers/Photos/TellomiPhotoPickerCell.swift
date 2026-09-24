//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

/// Tellomi（tellomi/tellomi#1261 P-8，照 Telegram `MediaPickerGridItem` 的格子）：正方形缩略图；右上角编号勾
/// （29 的触摸区，离上、右各 3；白色 1.5 描边 + 阴影，选中填强调色并显示第几张）；视频右下角时长；实况照片左上角小图标。
/// 点勾选上 / 取消；点照片本身由网格决定（进单张预览 / 编辑，P-10）。
final class TellomiPhotoPickerCell: UICollectionViewCell {

    static let reuseIdentifier = "TellomiPhotoPickerCell"

    private enum Metrics {
        static let checkTouchSize: CGFloat = 29
        static let checkInset: CGFloat = 3
        static let checkVisualSize: CGFloat = 24
        static let checkBorder: CGFloat = 1.5
    }

    private let imageView = UIImageView()
    private let durationLabel = UILabel()
    private let livePhotoBadge = UIImageView(image: UIImage(systemName: "livephoto"))
    private let checkButton = UIButton(type: .custom)
    private let checkCircle = UIView()
    private let numberLabel = UILabel()

    /// 点了右上角的勾。
    var onCheckTapped: (() -> Void)?

    private(set) var itemId: String?
    private var thumbnailRequest: TellomiPhotoPickerRequest?
    private(set) var selectionNumber: Int?

    override init(frame: CGRect) {
        super.init(frame: frame)

        contentView.backgroundColor = .Signal.secondaryBackground
        contentView.clipsToBounds = true

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        contentView.addSubview(imageView)

        durationLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        durationLabel.textColor = .white
        durationLabel.layer.shadowColor = UIColor.black.cgColor
        durationLabel.layer.shadowOpacity = 0.5
        durationLabel.layer.shadowRadius = 2
        durationLabel.layer.shadowOffset = .zero
        contentView.addSubview(durationLabel)

        livePhotoBadge.tintColor = .white
        livePhotoBadge.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        livePhotoBadge.layer.shadowColor = UIColor.black.cgColor
        livePhotoBadge.layer.shadowOpacity = 0.5
        livePhotoBadge.layer.shadowRadius = 2
        livePhotoBadge.layer.shadowOffset = .zero
        livePhotoBadge.isHidden = true
        contentView.addSubview(livePhotoBadge)

        checkCircle.isUserInteractionEnabled = false
        checkCircle.layer.cornerRadius = Metrics.checkVisualSize / 2
        checkCircle.layer.borderWidth = Metrics.checkBorder
        checkCircle.layer.borderColor = UIColor.white.cgColor
        checkCircle.layer.shadowColor = UIColor.black.cgColor
        checkCircle.layer.shadowOpacity = 0.3
        checkCircle.layer.shadowRadius = 2
        checkCircle.layer.shadowOffset = .zero
        checkButton.addSubview(checkCircle)

        numberLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        numberLabel.textColor = .white
        numberLabel.textAlignment = .center
        checkCircle.addSubview(numberLabel)

        checkButton.accessibilityLabel = OWSLocalizedString("IMAGE_PICKER_TELLOMI_SELECT", comment: "Accessibility label for the numbered check on a photo in the photo picker.")
        checkButton.addAction(UIAction { [weak self] _ in self?.onCheckTapped?() }, for: .touchUpInside)
        contentView.addSubview(checkButton)

        setSelectionNumber(nil, accentColor: .Signal.accent, animated: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = contentView.bounds
        let size = contentView.bounds.size
        checkButton.frame = CGRect(
            x: size.width - Metrics.checkTouchSize - Metrics.checkInset,
            y: Metrics.checkInset,
            width: Metrics.checkTouchSize,
            height: Metrics.checkTouchSize,
        )
        let inset = (Metrics.checkTouchSize - Metrics.checkVisualSize) / 2
        checkCircle.frame = CGRect(x: inset, y: inset, width: Metrics.checkVisualSize, height: Metrics.checkVisualSize)
        numberLabel.frame = checkCircle.bounds
        livePhotoBadge.sizeToFit()
        livePhotoBadge.frame.origin = CGPoint(x: 6, y: 6)
        durationLabel.sizeToFit()
        durationLabel.frame.origin = CGPoint(x: size.width - durationLabel.frame.width - 6, y: size.height - durationLabel.frame.height - 4)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnailRequest?.cancel()
        thumbnailRequest = nil
        imageView.image = nil
        itemId = nil
    }

    func configure(
        item: TellomiPhotoPickerItem,
        selectionNumber: Int?,
        accentColor: UIColor,
        library: TellomiPhotoPickerLibrary,
        thumbnailSize: CGSize,
    ) {
        itemId = item.id
        durationLabel.isHidden = !item.isVideo
        livePhotoBadge.isHidden = !item.isLivePhoto
        durationLabel.text = item.isVideo ? Self.formatDuration(item.duration) : nil
        setSelectionNumber(selectionNumber, accentColor: accentColor, animated: false)

        isAccessibilityElement = false
        imageView.isAccessibilityElement = true
        imageView.accessibilityTraits = .button
        imageView.accessibilityLabel = item.isVideo
            ? String.nonPluralLocalizedStringWithFormat(
                OWSLocalizedString("IMAGE_PICKER_TELLOMI_VIDEO_FORMAT", comment: "Accessibility label for a video in the photo picker. Embeds {{ duration }}."),
                Self.formatDuration(item.duration),
            )
            : OWSLocalizedString("IMAGE_PICKER_TELLOMI_PHOTO", comment: "Accessibility label for a photo in the photo picker.")

        thumbnailRequest?.cancel()
        thumbnailRequest = library.requestThumbnail(for: item, targetSize: thumbnailSize) { [weak self] image in
            guard let self, self.itemId == item.id else { return }
            if let image {
                self.imageView.image = image
            }
        }
        setNeedsLayout()
    }

    func setSelectionNumber(_ number: Int?, accentColor: UIColor, animated: Bool) {
        let wasSelected = selectionNumber != nil
        selectionNumber = number
        numberLabel.text = number.map { "\($0)" }
        checkCircle.backgroundColor = number != nil ? accentColor : UIColor.black.withAlphaComponent(0.12)
        checkButton.accessibilityTraits = number != nil ? [.button, .selected] : .button
        checkButton.accessibilityValue = number.map {
            String.nonPluralLocalizedStringWithFormat(
                OWSLocalizedString("IMAGE_PICKER_TELLOMI_SELECTED_NUMBER_FORMAT", comment: "Accessibility value of a selected photo's check in the photo picker. Embeds {{ its place in the selection }}."),
                OWSFormat.formatInt($0),
            )
        }
        if animated, number != nil, !wasSelected {
            checkCircle.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.55, initialSpringVelocity: 0) {
                self.checkCircle.transform = .identity
            }
        }
    }

    /// m:ss；一小时以上 h:mm:ss。
    static func formatDuration(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%d:%02d", minutes, seconds)
    }
}

#if TESTABLE_BUILD

extension TellomiPhotoPickerCell {
    var checkFrameForTesting: CGRect { checkButton.frame }
    var numberTextForTesting: String? { numberLabel.text }
    var durationTextForTesting: String? { durationLabel.isHidden ? nil : durationLabel.text }
    var isShowingLivePhotoBadgeForTesting: Bool { !livePhotoBadge.isHidden }
    var livePhotoBadgeFrameForTesting: CGRect { livePhotoBadge.frame }

    func tapCheckForTesting() {
        onCheckTapped?()
    }
}

#endif
