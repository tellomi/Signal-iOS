//
// Copyright 2026 Tellomi
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

/// 转发网格的一格（tellomi/tellomi#1259 F-4 / F-6）：60 pt 头像 + 最多两行名字。
/// 选中：头像缩到 0.867、外圈 2 pt 强调色环、右下角勾、名字变强调色（同 Telegram 的选中态，独立实现）。
final class TellomiForwardGridCell: UICollectionViewCell {

    static let reuseIdentifier = "TellomiForwardGridCell"

    enum Metrics {
        static let avatarSize: CGFloat = 60
        static let avatarTop: CGFloat = 4
        static let nameTopSpacing: CGFloat = 4
        static let selectedAvatarScale: CGFloat = 52 / 60
        static let ringSize: CGFloat = 64
        static let ringWidth: CGFloat = 2
        static let checkSize: CGFloat = 22
        static let nameFont = UIFont.systemFont(ofSize: 11)
    }

    private let avatarContainer = UIView()
    private let avatarView = ConversationAvatarView(
        sizeClass: .customDiameter(UInt(Metrics.avatarSize)),
        localUserDisplayMode: .noteToSelf,
        badged: false,
    )
    private let ringView = UIView()
    private let checkView = UIImageView()
    private let nameLabel = UILabel()

    private(set) var targetId: String?
    private(set) var isChosen = false

    /// 用例：换掉头像来源（测试环境的通讯录是假的，AvatarBuilder 画真头像会强转 OWSContactsManager 崩掉）
    static var avatarOverrideForTesting: ((TellomiForwardTarget) -> UIImage?)?

    override init(frame: CGRect) {
        super.init(frame: frame)

        ringView.isUserInteractionEnabled = false
        ringView.layer.borderWidth = Metrics.ringWidth
        ringView.layer.cornerRadius = Metrics.ringSize / 2
        ringView.alpha = 0
        contentView.addSubview(ringView)

        avatarContainer.isUserInteractionEnabled = false
        contentView.addSubview(avatarContainer)
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        avatarContainer.addSubview(avatarView)
        NSLayoutConstraint.activate([
            avatarView.leadingAnchor.constraint(equalTo: avatarContainer.leadingAnchor),
            avatarView.topAnchor.constraint(equalTo: avatarContainer.topAnchor),
        ])

        checkView.image = UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .bold))
        checkView.contentMode = .center
        checkView.tintColor = .white
        checkView.layer.cornerRadius = Metrics.checkSize / 2
        checkView.layer.borderWidth = Metrics.ringWidth
        checkView.clipsToBounds = true
        checkView.alpha = 0
        contentView.addSubview(checkView)

        nameLabel.font = Metrics.nameFont
        nameLabel.numberOfLines = 2
        nameLabel.textAlignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail
        contentView.addSubview(nameLabel)

        isAccessibilityElement = true
        applyColors()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyColors()
    }

    private func applyColors() {
        let traits = traitCollection
        ringView.layer.borderColor = UIColor.Signal.accent.resolvedColor(with: traits).cgColor
        checkView.backgroundColor = UIColor.Signal.accent
        // 勾外面一圈与卡片同色，压在头像上像 Telegram 那样「抠」出来
        checkView.layer.borderColor = TellomiForwardGridViewController.Colors.card.resolvedColor(with: traits).cgColor
        nameLabel.textColor = isChosen ? UIColor.Signal.accent : UIColor.Signal.label
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = contentView.bounds.width
        let avatarFrame = CGRect(
            x: floor((width - Metrics.avatarSize) / 2),
            y: Metrics.avatarTop,
            width: Metrics.avatarSize,
            height: Metrics.avatarSize,
        )
        avatarContainer.bounds = CGRect(origin: .zero, size: avatarFrame.size)
        avatarContainer.center = CGPoint(x: avatarFrame.midX, y: avatarFrame.midY)
        ringView.bounds = CGRect(origin: .zero, size: .square(Metrics.ringSize))
        ringView.center = avatarContainer.center
        // 勾带缩放动画：有 transform 时不能设 frame，用 bounds + center
        checkView.bounds = CGRect(origin: .zero, size: .square(Metrics.checkSize))
        checkView.center = CGPoint(
            x: avatarFrame.maxX - 14 + Metrics.checkSize / 2,
            y: avatarFrame.maxY - 15 + Metrics.checkSize / 2,
        )
        let nameTop = avatarFrame.maxY + Metrics.nameTopSpacing
        let nameSize = nameLabel.sizeThatFits(CGSize(width: width - 4, height: .greatestFiniteMagnitude))
        let maxNameHeight = ceil(Metrics.nameFont.lineHeight * 2)
        nameLabel.frame = CGRect(x: 2, y: nameTop, width: width - 4, height: min(ceil(nameSize.height), maxNameHeight))
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        targetId = nil
        setChosen(false, animated: false)
    }

    func configure(target: TellomiForwardTarget, isChosen: Bool) {
        targetId = target.id
        nameLabel.text = target.shortName
        accessibilityLabel = target.fullName
        avatarView.updateWithSneakyTransactionIfNecessary { config in
            if let avatarOverride = Self.avatarOverrideForTesting {
                config.dataSource = .asset(avatar: avatarOverride(target), badge: nil)
                return
            }
            switch target.kind {
            case .savedMessages(let address), .contact(let address):
                config.dataSource = .address(address)
            case .group(let groupThread):
                config.dataSource = .thread(groupThread)
            }
        }
        setChosen(isChosen, animated: false)
        // 复用的格子换了名字：重新量两行高度
        setNeedsLayout()
    }

    func setChosen(_ chosen: Bool, animated: Bool) {
        isChosen = chosen
        accessibilityTraits = chosen ? [.button, .selected] : .button
        nameLabel.textColor = chosen ? UIColor.Signal.accent : UIColor.Signal.label
        let changes = {
            self.avatarContainer.transform = chosen ? .scale(Metrics.selectedAvatarScale) : .identity
            self.ringView.alpha = chosen ? 1 : 0
            self.checkView.alpha = chosen ? 1 : 0
            self.checkView.transform = chosen ? .identity : .scale(0.5)
        }
        guard animated else {
            changes()
            return
        }
        UIView.animate(
            withDuration: chosen ? 0.2 : 0.3,
            delay: 0,
            usingSpringWithDamping: 0.8,
            initialSpringVelocity: 0,
            options: [.beginFromCurrentState, .allowUserInteraction],
            animations: changes,
        )
    }

    // MARK: - 用例读状态

    var avatarScaleForTesting: CGFloat { avatarContainer.transform.a }
    var isRingVisibleForTesting: Bool { ringView.alpha > 0 }
    var isCheckVisibleForTesting: Bool { checkView.alpha > 0 }
    var nameTextForTesting: String? { nameLabel.text }
    var nameColorForTesting: UIColor? { nameLabel.textColor }
    var nameFrameForTesting: CGRect { nameLabel.frame }
    var avatarFrameForTesting: CGRect { avatarContainer.frame }
}

/// 搜索结果的分组标题（我的收藏 / 聊天 / 联系人 / 群组 / 最近）。
final class TellomiForwardSectionHeader: UICollectionReusableView {

    static let reuseIdentifier = "TellomiForwardSectionHeader"
    static let height: CGFloat = 28

    let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = UIColor.Signal.secondaryLabel
        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        accessibilityTraits = .header
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
