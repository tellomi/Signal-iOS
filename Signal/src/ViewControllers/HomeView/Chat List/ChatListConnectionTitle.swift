//
// Copyright 2026 Tellomi
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

/// Tellomi（tellomi/tellomi#1218 F-04）：会话列表标题在没连上服务器时换成连接状态 + 小转圈，连上后换回「聊天」。
/// 大陆连香港时断时续，标题直接说「现在卡在哪一步」，比一条故障横幅有用。
///
/// 只由四样东西决定（`from`）：能不能连（注册着、没过期）、系统有没有网、收消息的那条（已认证）连接的状态、
/// 连上之后服务器上积压的消息收完没有（`hasEmptiedInitialQueue`：服务器发来「队列已空」时置位，断开即清）。
///
/// 机制参照 Telegram（只读，独立实现，一行未搬）：iOS `ChatListController` 的 `NetworkStatusTitle`
/// （等待网络 / 连接中 / 更新中 + 标题左边一个小转圈；离开「已连上」时先等 0.3 秒）；
/// Android `LaunchActivity.updateCurrentConnectionState`。Android 端同一功能见 Signal-Android `main/ConnectionTitle.kt`。
enum ChatListConnectionTitle: Equatable, CustomStringConvertible {
    case connected
    case waitingForNetwork
    case connecting
    case updating

    /// 与 Telegram iOS 同一取舍：一闪而过的断线不值得让标题晃一下。
    static let leaveConnectedDelay: TimeInterval = 0.3

    static func from(
        canConnect: Bool,
        isReachable: Bool,
        identifiedConnectionState: OWSChatConnectionState,
        hasEmptiedInitialQueue: Bool,
    ) -> ChatListConnectionTitle {
        // 没注册 / 被解绑 / 版本过期时根本不会去连，上游各有自己的提示，标题别陪着一直转圈
        guard canConnect else {
            return .connected
        }
        guard isReachable else {
            return .waitingForNetwork
        }
        switch identifiedConnectionState {
        case .open:
            return hasEmptiedInitialQueue ? .connected : .updating
        case .connecting, .closed:
            return .connecting
        }
    }

    /// 从「已连上」变成别的状态时先等 `leaveConnectedDelay`，等待期间又连回来就什么都不显示；别的变化立刻显示。
    /// 第一次（`previous` 为 nil）立刻显示：刚进列表就没连上，应该马上说。
    static func shouldDelay(from previous: ChatListConnectionTitle?, to next: ChatListConnectionTitle) -> Bool {
        return previous == .connected && next != .connected
    }

    /// `nil` = 显示原来的标题。
    var text: String? {
        switch self {
        case .connected:
            return nil
        case .waitingForNetwork:
            return OWSLocalizedString(
                "CHAT_LIST_TITLE_WAITING_FOR_NETWORK_TELLOMI",
                value: "Waiting for network…",
                comment: "Chat list title while the device has no network connection. Shown next to a small spinner.",
            )
        case .connecting:
            return OWSLocalizedString(
                "CHAT_LIST_TITLE_CONNECTING_TELLOMI",
                value: "Connecting…",
                comment: "Chat list title while the app is connecting to the server. Shown next to a small spinner.",
            )
        case .updating:
            return OWSLocalizedString(
                "CHAT_LIST_TITLE_UPDATING_TELLOMI",
                value: "Updating…",
                comment: "Chat list title while the app is receiving the messages that arrived while it was offline. Shown next to a small spinner.",
            )
        }
    }

    var description: String {
        switch self {
        case .connected: "connected"
        case .waitingForNetwork: "waitingForNetwork"
        case .connecting: "connecting"
        case .updating: "updating"
        }
    }
}

protocol ChatListConnectionTitleDelegate: AnyObject {
    func didUpdateConnectionTitle(_ connectionTitle: ChatListConnectionTitle)
}

@MainActor
final class ChatListConnectionTitleObserver {
    weak var delegate: ChatListConnectionTitleDelegate?

    private(set) var title: ChatListConnectionTitle = .connected

    private var lastComputed: ChatListConnectionTitle?
    private var refreshGeneration = 0
    private var pendingPublish: Task<Void, Never>?
    private var observers = [NSObjectProtocol]()

    init() {
        // 连接状态变化与「队列已空」都会发 chatConnectionStateDidChange（后者状态不变、只为唤醒等待者）
        let names: [Notification.Name] = [
            OWSChatConnection.chatConnectionStateDidChange,
            SSKReachability.owsReachabilityDidChange,
            .registrationStateDidChange,
        ]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main,
                using: { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } },
            ))
        }
        refresh()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// 「队列收完没有」只能异步取。每次都按**当前值**整体重算，并且只采用最后一次发起的那次结果——
    /// 否则较早发起、较晚返回的一次会把标题改回旧状态（例如停在「收取中…」）。
    private func refresh() {
        refreshGeneration += 1
        let generation = refreshGeneration
        let chatConnectionManager = DependenciesBridge.shared.chatConnectionManager
        Task { @MainActor [weak self] in
            let hasEmptiedInitialQueue = await chatConnectionManager.hasEmptiedInitialQueue
            guard let self, generation == self.refreshGeneration else {
                return
            }
            let registrationState = DependenciesBridge.shared.tsAccountManager.registrationStateWithMaybeSneakyTransaction
            self.apply(ChatListConnectionTitle.from(
                canConnect: registrationState.isRegistered && !DependenciesBridge.shared.appExpiry.isExpired(now: Date()),
                isReachable: SSKEnvironment.shared.reachabilityManagerRef.isReachable,
                identifiedConnectionState: chatConnectionManager.identifiedConnectionState,
                hasEmptiedInitialQueue: hasEmptiedInitialQueue,
            ))
        }
    }

    private func apply(_ computed: ChatListConnectionTitle) {
        let previous = lastComputed
        guard computed != previous else {
            return
        }
        lastComputed = computed

        pendingPublish?.cancel()
        pendingPublish = nil

        if ChatListConnectionTitle.shouldDelay(from: previous, to: computed) {
            pendingPublish = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(ChatListConnectionTitle.leaveConnectedDelay * 1_000_000_000))
                guard !Task.isCancelled else {
                    return
                }
                self?.publish(computed)
            }
        } else {
            publish(computed)
        }
    }

    private func publish(_ newTitle: ChatListConnectionTitle) {
        guard newTitle != title else {
            return
        }
        title = newTitle
        // 用户说「一直显示连接中」时，日志里能看到标题是什么时候、按什么顺序变的
        Logger.info("Title: \(newTitle)")
        delegate?.didUpdateConnectionTitle(newTitle)
    }
}

/// 转圈 + 状态文字，颜色跟导航栏标题一样（黑白两色，随深浅色走）。
final class ChatListConnectionTitleView: UIView {
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let label = UILabel()

    init(text: String) {
        super.init(frame: .zero)

        spinner.color = .Signal.label
        spinner.startAnimating()

        label.font = .dynamicTypeHeadlineClamped
        label.textColor = .Signal.label
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.7

        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 6
        addSubview(stack)
        stack.autoPinEdgesToSuperviewEdges()

        isAccessibilityElement = true
        accessibilityTraits = .header
        setText(text, animated: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setText(_ text: String, animated: Bool) {
        accessibilityLabel = text
        guard animated else {
            label.text = text
            return
        }
        UIView.transition(with: label, duration: 0.2, options: .transitionCrossDissolve) {
            self.label.text = text
        }
    }
}

extension ChatListViewController: ChatListConnectionTitleDelegate {
    func didUpdateConnectionTitle(_ connectionTitle: ChatListConnectionTitle) {
        // 归档列表不显示（它有自己的标题，而且不是用户停留的首屏）
        guard viewState.chatListMode == .inbox else {
            return
        }

        if let text = connectionTitle.text, let titleView = navigationItem.titleView as? ChatListConnectionTitleView {
            titleView.setText(text, animated: true)
            return
        }

        // 原标题 ↔ 状态之间换 titleView，整条导航栏做个淡入淡出，免得标题硬切
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.2
        navigationController?.navigationBar.layer.add(fade, forKey: "tellomiConnectionTitle")
        navigationItem.titleView = connectionTitle.text.map { ChatListConnectionTitleView(text: $0) }
    }
}
