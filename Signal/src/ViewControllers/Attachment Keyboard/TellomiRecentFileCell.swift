//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// Tellomi（tellomi/tellomi#1121 F-6、F-7、F-8）：「最近发送的文件」里的一行。
/// 左边 40 pt 文件图标；粗体文件名（太长中间省略）；灰色「大小 · 日期 时间」；本机文件已被清理的整行置灰、写「已不在本机」；
/// 多选时左边多一个带序号的勾。
final class TellomiRecentFileCell: UITableViewCell {

    static let reuseIdentifier = "TellomiRecentFileCell"
    static let rowHeight: CGFloat = 60

    private let icon = TellomiFileTypeIcon()
    private let nameLabel = UILabel()
    private let detailLabel = UILabel()
    private let check = TellomiRecentFileCheck()
    private var checkLeading: NSLayoutConstraint?
    private var iconLeadingToMargin: NSLayoutConstraint?
    private var iconLeadingToCheck: NSLayoutConstraint?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        nameLabel.font = UIFont.dynamicTypeBodyClamped.semibold()
        nameLabel.textColor = .Signal.label
        nameLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.font = .dynamicTypeFootnoteClamped
        detailLabel.textColor = .Signal.secondaryLabel
        detailLabel.lineBreakMode = .byTruncatingTail

        let text = UIStackView(arrangedSubviews: [nameLabel, detailLabel])
        text.axis = .vertical
        text.spacing = 2

        for subview in [check, icon, text] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(subview)
        }
        let iconLeadingToMargin = icon.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor)
        let iconLeadingToCheck = icon.leadingAnchor.constraint(equalTo: check.trailingAnchor, constant: 12)
        self.iconLeadingToMargin = iconLeadingToMargin
        self.iconLeadingToCheck = iconLeadingToCheck
        NSLayoutConstraint.activate([
            check.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            check.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            check.widthAnchor.constraint(equalToConstant: TellomiRecentFileCheck.side),
            check.heightAnchor.constraint(equalToConstant: TellomiRecentFileCheck.side),

            iconLeadingToMargin,
            icon.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: TellomiFileTypeIcon.side),
            icon.heightAnchor.constraint(equalToConstant: TellomiFileTypeIcon.side),

            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            text.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            text.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
        check.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// - Parameter selectionNumber: 多选时第几个（从 1 起）；0 = 多选中但没勾；nil = 不在多选。
    func configure(file: TellomiRecentFile, showsDate: Bool, selectionNumber: Int?) {
        icon.configure(fileName: file.fileName)
        nameLabel.text = file.fileName
        if file.isOnDevice {
            let size = ByteCountFormatter.string(fromByteCount: Int64(clamping: file.byteCount), countStyle: .file)
            detailLabel.text = showsDate ? "\(size) · \(Self.dateFormatter.string(from: file.sentAt))" : size
        } else {
            detailLabel.text = OWSLocalizedString("ATTACHMENT_FILES_TELLOMI_NOT_ON_DEVICE", comment: "Subtitle of a recently sent file whose local copy was deleted, so it can't be sent again.")
        }
        contentView.alpha = file.isOnDevice ? 1 : 0.4

        let inSelection = selectionNumber != nil
        check.isHidden = !inSelection
        check.number = selectionNumber ?? 0
        iconLeadingToMargin?.isActive = !inSelection
        iconLeadingToCheck?.isActive = inSelection

        accessibilityLabel = [file.fileName, detailLabel.text].compactMap { $0 }.joined(separator: ", ")
        accessibilityTraits = (selectionNumber ?? 0) > 0 ? [.button, .selected] : .button
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var nameTextForTesting: String? { nameLabel.text }
    var detailTextForTesting: String? { detailLabel.text }
    var iconForTesting: TellomiFileTypeIcon { icon }
    var selectionNumberForTesting: Int? { check.isHidden ? nil : check.number }
    var isDimmedForTesting: Bool { contentView.alpha < 1 }
}

/// 多选时每行左边的勾：没勾是空心圈，勾了是强调色实心圈 + 序号。
final class TellomiRecentFileCheck: UIView {

    static let side: CGFloat = 24

    private let label = UILabel()

    var number: Int = 0 {
        didSet { update() }
    }

    init() {
        super.init(frame: .zero)
        layer.cornerRadius = Self.side / 2
        layer.borderWidth = 1.5
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.textAlignment = .center
        addSubview(label)
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds
    }

    private func update() {
        let isChecked = number > 0
        backgroundColor = isChecked ? .Signal.accent : .clear
        layer.borderColor = (isChecked ? UIColor.Signal.accent : UIColor.Signal.tertiaryLabel).cgColor
        label.text = isChecked ? "\(number)" : nil
    }
}
