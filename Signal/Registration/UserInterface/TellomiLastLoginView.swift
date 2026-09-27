//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

/// 本机已退出登录的账号：欢迎页「上次登录」要显示的内容（ADR-0072 §4.1 第 4 步）。
public struct TellomiLastLogin: Equatable {
    /// 例如 `+86 138****5678`。
    let maskedPhoneNumber: String
    /// 画头像用；本机身份缺失时为 nil（只显示默认头像）。
    let localAddress: SignalServiceAddress?
}

/// 欢迎页上方的「上次登录」：头像 + 打码的手机号，整块可点，点了直接给这个号码发验证码。
/// 用现有的头像组件和系统字体、配色，不另做视觉（需求 §3.5）。
final class TellomiLastLoginView: UIControl {

    static let accessibilityIdentifierValue = "tellomi.splash.lastLogin"

    let lastLogin: TellomiLastLogin
    private let onTap: () -> Void

    init(lastLogin: TellomiLastLogin, onTap: @escaping () -> Void) {
        self.lastLogin = lastLogin
        self.onTap = onTap
        super.init(frame: .zero)

        backgroundColor = .Signal.secondaryBackground
        layer.cornerRadius = 16
        layer.masksToBounds = true

        let avatarView = ConversationAvatarView(
            sizeClass: .customDiameter(44),
            localUserDisplayMode: .asUser,
            badged: false,
        )
        if let localAddress = lastLogin.localAddress {
            avatarView.updateWithSneakyTransactionIfNecessary { config in
                config.dataSource = .address(localAddress)
            }
        }

        let titleLabel = UILabel()
        titleLabel.text = Self.titleText
        titleLabel.font = .dynamicTypeFootnote
        titleLabel.textColor = .Signal.secondaryLabel
        titleLabel.adjustsFontForContentSizeCategory = true

        let phoneNumberLabel = UILabel()
        phoneNumberLabel.text = lastLogin.maskedPhoneNumber
        phoneNumberLabel.font = .dynamicTypeHeadline
        phoneNumberLabel.textColor = .Signal.label
        phoneNumberLabel.adjustsFontForContentSizeCategory = true
        phoneNumberLabel.numberOfLines = 0

        let labels = UIStackView(arrangedSubviews: [titleLabel, phoneNumberLabel])
        labels.axis = .vertical
        labels.spacing = 2

        let chevron = UIImageView(image: UIImage(systemName: CurrentAppContext().isRTL ? "chevron.left" : "chevron.right"))
        chevron.tintColor = .Signal.tertiaryLabel
        chevron.contentMode = .scaleAspectFit
        chevron.setContentHuggingHigh()
        chevron.setCompressionResistanceHigh()

        let row = UIStackView(arrangedSubviews: [avatarView, labels, chevron])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        row.isUserInteractionEnabled = false
        addSubview(row)
        row.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))

        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "\(Self.titleText), \(lastLogin.maskedPhoneNumber)"
        accessibilityIdentifier = Self.accessibilityIdentifierValue

        addTarget(self, action: #selector(didTap), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        owsFail("Not implemented")
    }

    static var titleText: String {
        OWSLocalizedString(
            "TELLOMI_LOGOUT_LAST_LOGIN_TITLE",
            comment: "Tellomi: Caption above the masked phone number of the logged-out account on the welcome screen. Tapping the block logs back in with that number.",
        )
    }

    override var isHighlighted: Bool {
        didSet {
            backgroundColor = isHighlighted ? .Signal.tertiaryBackground : .Signal.secondaryBackground
        }
    }

    @objc
    private func didTap() {
        onTap()
    }
}
