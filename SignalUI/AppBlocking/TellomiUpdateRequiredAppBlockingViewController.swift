//
// Copyright 2026 Tellomi
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit

/// Tellomi（tellomi/tellomi#1139，需求 app-update-and-version-policy 第 3.4 节）：「必须更新」阻断页。
///
/// 服务端对本版本回 499，或构建过了有效期，都会让 `AppExpiry` 判定过期。上游只在会话列表顶上挂一条提示、
/// 把输入框换成「更新」，App 其余部分照常能点，只是什么都发不出去。这里整页盖住 App，只留一个「立即更新」。
/// 页面上没有任何私人内容，所以窗口放在应用锁之上（见 `WindowManager`）。
public class TellomiUpdateRequiredAppBlockingViewController: AppBlockingViewController {

    public enum Reason: Equatable {
        /// 服务端拒绝了这个版本（499），或远程配置宣布它到期。
        case serverRejected
        /// 构建本身过了有效期（Signal 自带的兜底）。
        case buildTooOld
    }

    public var reason: Reason {
        didSet {
            subtitle = Self.subtitle(for: reason)
        }
    }

    private let openUpdatePage: @MainActor () -> Void

    public init(reason: Reason, openUpdatePage: @escaping @MainActor () -> Void) {
        self.reason = reason
        self.openUpdatePage = openUpdatePage

        super.init(
            headerImage: UIImage(named: "signal-logo-128")!.withRenderingMode(.alwaysTemplate),
            title: OWSLocalizedString(
                "APP_EXPIRED_TELLOMI_BLOCKING_TITLE",
                comment: "Tellomi: Title of the full-screen page shown when this version of the app can no longer be used and must be updated.",
            ),
            subtitle: Self.subtitle(for: reason),
        )
    }

    public static func subtitle(for reason: Reason) -> String {
        let reasonText: String
        switch reason {
        case .serverRejected:
            reasonText = OWSLocalizedString(
                "APP_EXPIRED_TELLOMI_BLOCKING_REASON_SERVER_REJECTED",
                comment: "Tellomi: On the 'update required' page, why the app must be updated: the server no longer accepts this version.",
            )
        case .buildTooOld:
            reasonText = OWSLocalizedString(
                "APP_EXPIRED_TELLOMI_BLOCKING_REASON_BUILD_TOO_OLD",
                comment: "Tellomi: On the 'update required' page, why the app must be updated: this version is too old.",
            )
        }
        let chatsKept = OWSLocalizedString(
            "APP_EXPIRED_TELLOMI_BLOCKING_CHATS_KEPT",
            comment: "Tellomi: On the 'update required' page, reassurance that updating keeps the chats on this phone.",
        )
        return reasonText + "\n\n" + chatsKept
    }

    // MARK: - Views

    public private(set) lazy var updateButton: UIButton = {
        let button = UIButton(
            configuration: .largePrimary(title: OWSLocalizedString(
                "APP_EXPIRED_TELLOMI_BLOCKING_UPDATE_BUTTON",
                comment: "Tellomi: The only button on the 'update required' page. Opens the page where the new version can be installed.",
            )),
        )
        // 和上游 ClockSkewAppBlockingViewController 一样，从 @objc 方法（MainActor）里调外面给的回调。
        button.addTarget(self, action: #selector(didTapUpdate), for: .primaryActionTriggered)
        button.accessibilityIdentifier = "tellomi.updateRequired.updateButton"
        return button
    }()

    @objc
    private func didTapUpdate() {
        openUpdatePage()
    }

    // MARK: - Lifecycle

    override public func viewDidLoad() {
        super.viewDidLoad()

        // 给底部按钮让出位置：标、标题、说明在剩下的空间里居中，不会压到按钮。
        view.directionalLayoutMargins.bottom += 90

        // 唯一主按钮放在底部（需求 3.4：一个主按钮，没有关闭）。
        view.addSubview(updateButton)
        updateButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            updateButton.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            updateButton.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            updateButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
        ])
    }
}

// MARK: -

#if DEBUG

@available(iOS 17, *)
#Preview {
    TellomiUpdateRequiredAppBlockingViewController(reason: .serverRejected, openUpdatePage: {})
}

#endif
