//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit

/// Tellomi（tellomi/tellomi#1139，需求 app-update-and-version-policy 第 3.4 节）：「必须更新」阻断页。
///
/// 服务端对本版本回 499（或远程配置宣布到期）时整页盖住 App：主按钮「立即更新」，下面始终有「暂不更新，只看聊天记录」。
/// owner 2026-09-24 定：聊天记录只在这台手机上，任何情况下都不能把人锁在外面。选了只看记录，就回到上游的做法：
/// 会话列表顶上挂「已过期」提示、输入框换成「更新」，能看历史、不能收发。
///
/// 页面上没有任何私人内容，所以窗口放在应用锁之上（见 `WindowManager`）；从这里进只读要先过应用锁。
/// 什么时候盖由 `TellomiUpdateRequiredMonitoringManager` 决定：本机构建到期、没有可用的更新渠道时都不盖。
public class TellomiUpdateRequiredAppBlockingViewController: AppBlockingViewController {

    private let openUpdatePage: @MainActor () -> Void
    private let viewChatsOnly: @MainActor () -> Void

    public init(
        openUpdatePage: @escaping @MainActor () -> Void,
        viewChatsOnly: @escaping @MainActor () -> Void,
    ) {
        self.openUpdatePage = openUpdatePage
        self.viewChatsOnly = viewChatsOnly

        // 这几条只写了 4 种语言。iOS 找不到键时不回落英文、直接显示键名，所以都带英文 value（taishi 审查 b15 不阻塞 1）。
        super.init(
            headerImage: UIImage(named: "signal-logo-128")!.withRenderingMode(.alwaysTemplate),
            title: OWSLocalizedString(
                "APP_EXPIRED_TELLOMI_BLOCKING_TITLE",
                value: "Update Tellomi to continue",
                comment: "Tellomi: Title of the full-screen page shown when this version of the app can no longer be used and must be updated.",
            ),
            subtitle: Self.subtitle,
        )
    }

    public static var subtitle: String {
        let reasonText = OWSLocalizedString(
            "APP_EXPIRED_TELLOMI_BLOCKING_REASON_SERVER_REJECTED",
            value: "This version can no longer communicate with the server. Update to keep sending and receiving messages.",
            comment: "Tellomi: On the 'update required' page, why the app must be updated: the server no longer accepts this version.",
        )
        let chatsKept = OWSLocalizedString(
            "APP_EXPIRED_TELLOMI_BLOCKING_CHATS_KEPT",
            value: "Updating keeps all the chats on this phone.",
            comment: "Tellomi: On the 'update required' page, reassurance that updating keeps the chats on this phone.",
        )
        return reasonText + "\n\n" + chatsKept
    }

    // MARK: - Views

    public private(set) lazy var updateButton: UIButton = {
        let button = UIButton(
            configuration: .largePrimary(title: OWSLocalizedString(
                "APP_EXPIRED_TELLOMI_BLOCKING_UPDATE_BUTTON",
                value: "Update now",
                comment: "Tellomi: The main button on the 'update required' page. Opens the page where the new version can be installed.",
            )),
        )
        // 和上游 ClockSkewAppBlockingViewController 一样，从 @objc 方法（MainActor）里调外面给的回调。
        button.addTarget(self, action: #selector(didTapUpdate), for: .primaryActionTriggered)
        button.accessibilityIdentifier = "tellomi.updateRequired.updateButton"
        return button
    }()

    public private(set) lazy var viewChatsOnlyButton: UIButton = {
        let button = UIButton(
            configuration: .mediumBorderless(title: OWSLocalizedString(
                "APP_EXPIRED_TELLOMI_BLOCKING_VIEW_CHATS_ONLY_BUTTON",
                value: "Not now, just view my chats",
                comment: "Tellomi: Secondary button on the 'update required' page. Leaves the page without updating; the app then only shows the chat history and can't send or receive.",
            )),
        )
        button.addTarget(self, action: #selector(didTapViewChatsOnly), for: .primaryActionTriggered)
        button.accessibilityIdentifier = "tellomi.updateRequired.viewChatsOnlyButton"
        return button
    }()

    @objc
    private func didTapUpdate() {
        openUpdatePage()
    }

    /// 先说清后果再放行，和 Android 上游「不要更新」的确认框同一个意思。
    @objc
    private func didTapViewChatsOnly() {
        let actionSheet = ActionSheetController(
            title: nil,
            message: OWSLocalizedString(
                "APP_EXPIRED_TELLOMI_BLOCKING_VIEW_CHATS_ONLY_CONFIRM_MESSAGE",
                value: "You can view your chat history, but you won't be able to send or receive messages until you update.",
                comment: "Tellomi: Confirmation shown after tapping 'Not now, just view my chats' on the 'update required' page.",
            ),
        )
        actionSheet.addAction(ActionSheetAction(
            title: OWSLocalizedString(
                "APP_EXPIRED_TELLOMI_BLOCKING_VIEW_CHATS_ONLY_CONFIRM",
                value: "Don't Update",
                comment: "Tellomi: Button in the confirmation after tapping 'Not now, just view my chats'. Leaves the 'update required' page without updating.",
            ),
            handler: { [weak self] _ in
                self?.viewChatsOnly()
            },
        ))
        actionSheet.addAction(OWSActionSheets.cancelAction)
        presentActionSheet(actionSheet)
    }

    // MARK: - Lifecycle

    override public func viewDidLoad() {
        super.viewDidLoad()

        // 下面的窗口（没上锁时的会话列表）不能被旁白读到、点到（taishi 审查 b15 要改 2）。
        view.accessibilityViewIsModal = true

        // 给底部两个按钮让出位置：标、标题、说明在剩下的空间里居中，不会压到按钮。
        view.directionalLayoutMargins.bottom += 140

        view.addSubview(updateButton)
        view.addSubview(viewChatsOnlyButton)
        updateButton.translatesAutoresizingMaskIntoConstraints = false
        viewChatsOnlyButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            updateButton.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            updateButton.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            updateButton.bottomAnchor.constraint(equalTo: viewChatsOnlyButton.topAnchor, constant: -8),

            viewChatsOnlyButton.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            viewChatsOnlyButton.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            viewChatsOnlyButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])
    }
}

// MARK: -

#if DEBUG

@available(iOS 17, *)
#Preview {
    TellomiUpdateRequiredAppBlockingViewController(openUpdatePage: {}, viewChatsOnly: {})
}

#endif
