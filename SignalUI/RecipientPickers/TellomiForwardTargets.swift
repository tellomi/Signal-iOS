//
// Copyright 2026 Tellomi
// SPDX-License-Identifier: AGPL-3.0-only
//

public import SignalServiceKit

/// 转发网格（tellomi/tellomi#1259）里的一格：一个能转发过去的聊天。
public struct TellomiForwardTarget {
    public enum Kind {
        case savedMessages(SignalServiceAddress)
        case contact(SignalServiceAddress)
        case group(TSGroupThread)
    }

    public let kind: Kind
    /// 交给转发的发送流程（选中、建会话、发）
    public let item: ConversationItem
    /// 网格里头像下面的名字：人用短名（同 Telegram 的 compactDisplayTitle），群用群名
    public let shortName: String
    /// 副标题与发出后的提示条用的名字
    public let fullName: String

    public var isSavedMessages: Bool {
        if case .savedMessages = kind {
            return true
        }
        return false
    }

    public var isGroup: Bool {
        if case .group = kind {
            return true
        }
        return false
    }

    /// 同一个聊天不管从网格、最近一排还是搜索结果来，都是同一个 id
    public var id: String {
        switch item.messageRecipient {
        case .contact(let address):
            return "contact:" + (address.serviceIdUppercaseString ?? address.phoneNumber ?? "")
        case .group(let groupThreadId):
            return "group:" + groupThreadId
        case .privateStory(let storyThreadId, _):
            return "story:" + storyThreadId
        }
    }
}

/// 搜索态（F-9）的结果，按需求的顺序分组：我的收藏 · 聊天 · 联系人（含没聊过的）· 群组。
public struct TellomiForwardSearchResults {
    public let savedMessages: TellomiForwardTarget?
    public let chats: [TellomiForwardTarget]
    public let contacts: [TellomiForwardTarget]
    public let groups: [TellomiForwardTarget]

    public var isEmpty: Bool {
        savedMessages == nil && chats.isEmpty && contacts.isEmpty && groups.isEmpty
    }

    public static let empty = TellomiForwardSearchResults(savedMessages: nil, chats: [], contacts: [], groups: [])
}

/// 转发网格的候选聊天（tellomi/tellomi#1259 F-5 / F-9）。
///
/// 第一格固定「我的收藏」——沿用 #1174 的 `TellomiSavedMessagesConversationItem`（会话还没建过、新注册账号也有）；
/// 之后与聊天列表同序：置顶的按置顶顺序在前，其余按最后一条消息从新到旧，归档的排最后，最多 `maxChats` 个。
/// 不出现：自己不能发言的群（含只有管理员能发言的群）、已退出 / 被移出的群、拉黑的、隐藏的、还没接受的消息请求；
/// 「动态」（Signal Story）不进网格（owner D6）。
public enum TellomiForwardTargets {

    public static let maxChats = 150

    public static func load(maxChats: Int = maxChats, tx: DBReadTransaction) -> [TellomiForwardTarget] {
        var targets: [TellomiForwardTarget] = []
        if let savedMessages = savedMessagesTarget(tx: tx) {
            targets.append(savedMessages)
        }

        var seenThreadIds = Set<String>()
        var chatCount = 0
        let consider = { (thread: TSThread) in
            guard chatCount < maxChats, !seenThreadIds.contains(thread.uniqueId) else {
                return
            }
            seenThreadIds.insert(thread.uniqueId)
            guard let target = chatTarget(thread: thread, tx: tx) else {
                return
            }
            targets.append(target)
            chatCount += 1
        }

        for thread in DependenciesBridge.shared.pinnedThreadManager.pinnedThreads(tx: tx) {
            consider(thread)
        }
        let threadFinder = ThreadFinder()
        threadFinder.enumerateVisibleThreads(isArchived: false, transaction: tx) { consider($0) }
        threadFinder.enumerateVisibleThreads(isArchived: true, transaction: tx) { consider($0) }
        return targets
    }

    /// 搜索态空查询时的「最近联系人」一排：网格里的一对一聊天（不含我的收藏和群），按网格顺序。
    public static func recentContacts(in targets: [TellomiForwardTarget], limit: Int = 12) -> [TellomiForwardTarget] {
        let contacts = targets.filter { target in
            if case .contact = target.kind {
                return true
            }
            return false
        }
        return Array(contacts.prefix(limit))
    }

    /// 搜索（F-9）。匹配规则沿用上游会话搜索（名字 / 用户名 / 号码；「我的收藏」按它的名字匹配，「收藏」也能搜到）。
    /// `chats` 是网格里现有的候选（`load` 的结果），命中的聊天按网格顺序排在「聊天」组；没聊过的人进「联系人」，
    /// 网格里没有的群进「群组」，同一个聊天只出现一次。
    public static func search(
        query: String,
        chats: [TellomiForwardTarget],
        tx: DBReadTransaction,
    ) throws(CancellationError) -> TellomiForwardSearchResults {
        let searchText = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchText.isEmpty else {
            return .empty
        }
        guard let localAddress = DependenciesBridge.shared.tsAccountManager.localIdentifiers(tx: tx)?.aciAddress else {
            return .empty
        }

        let resultSet = try FullTextSearcher.shared.searchForRecipients(
            searchText: searchText,
            includeLocalUser: true,
            includeStories: false,
            tx: tx,
        )

        var matchedIds = Set<String>()
        var savedMessages: TellomiForwardTarget?
        var otherContacts: [TellomiForwardTarget] = []
        for contactResult in resultSet.contactResults {
            let address = contactResult.recipientAddress
            if address == localAddress {
                savedMessages = savedMessagesTarget(tx: tx)
                continue
            }
            guard let target = contactTarget(address: address, tx: tx) else {
                continue
            }
            matchedIds.insert(target.id)
            otherContacts.append(target)
        }

        var otherGroups: [TellomiForwardTarget] = []
        for groupThread in resultSet.groupThreads {
            guard let target = chatTarget(thread: groupThread, tx: tx) else {
                continue
            }
            matchedIds.insert(target.id)
            otherGroups.append(target)
        }

        let matchedChats = chats.filter { !$0.isSavedMessages && matchedIds.contains($0.id) }
        let chatIds = Set(matchedChats.map(\.id))
        return TellomiForwardSearchResults(
            savedMessages: savedMessages,
            chats: matchedChats,
            contacts: otherContacts.filter { !chatIds.contains($0.id) },
            groups: otherGroups.filter { !chatIds.contains($0.id) },
        )
    }

    // MARK: -

    static func savedMessagesTarget(tx: DBReadTransaction) -> TellomiForwardTarget? {
        guard let item = TellomiSavedMessagesConversationItem.contactItem(tx: tx) else {
            return nil
        }
        let name = MessageStrings.noteToSelf
        return TellomiForwardTarget(kind: .savedMessages(item.address), item: item, shortName: name, fullName: name)
    }

    /// 聊天列表里的一个会话能不能进网格；能就给出那一格。每道判据只在这里查一次。
    static func chatTarget(thread: TSThread, tx: DBReadTransaction) -> TellomiForwardTarget? {
        // 不能发言的群（只有管理员能发言、已退出 / 被移出、GV1、已解散）、官方通知号
        guard thread.canSendChatMessagesToThread() else {
            return nil
        }
        guard !SSKEnvironment.shared.blockingManagerRef.isThreadBlocked(thread, transaction: tx) else {
            return nil
        }
        guard !ThreadFinder().hasPendingMessageRequest(thread: thread, transaction: tx) else {
            return nil
        }

        switch thread {
        case let contactThread as TSContactThread:
            let address = contactThread.contactAddress
            guard !address.isLocalAddress else {
                // 「我的收藏」固定在第一格，不再按会话出现一次
                return nil
            }
            guard !DependenciesBridge.shared.recipientHidingManager.isHiddenAddress(address, tx: tx) else {
                return nil
            }
            return buildContactTarget(address: address, thread: contactThread, tx: tx)
        case let groupThread as TSGroupThread:
            let dmConfig = DependenciesBridge.shared.disappearingMessagesConfigurationStore.fetchOrBuildDefault(
                for: .thread(groupThread),
                tx: tx,
            )
            let item = GroupConversationItem(
                groupThreadId: groupThread.uniqueId,
                isBlocked: false,
                disappearingMessagesConfig: dmConfig,
            )
            let name = groupThread.groupNameOrDefault
            return TellomiForwardTarget(kind: .group(groupThread), item: item, shortName: name, fullName: name)
        default:
            return nil
        }
    }

    /// 搜索里的人（可能还没聊过）：没拉黑、没隐藏、有会话的话不是未接受的消息请求。
    static func contactTarget(address: SignalServiceAddress, tx: DBReadTransaction) -> TellomiForwardTarget? {
        guard !address.isLocalAddress else {
            return nil
        }
        guard !SSKEnvironment.shared.blockingManagerRef.isAddressBlocked(address, transaction: tx) else {
            return nil
        }
        guard !DependenciesBridge.shared.recipientHidingManager.isHiddenAddress(address, tx: tx) else {
            return nil
        }
        let thread = TSContactThread.getWithContactAddress(address, transaction: tx)
        if let thread, ThreadFinder().hasPendingMessageRequest(thread: thread, transaction: tx) {
            return nil
        }
        return buildContactTarget(address: address, thread: thread, tx: tx)
    }

    private static func buildContactTarget(address: SignalServiceAddress, thread: TSContactThread?, tx: DBReadTransaction) -> TellomiForwardTarget {
        let dmConfigurationStore = DependenciesBridge.shared.disappearingMessagesConfigurationStore
        let dmConfig = thread.map { dmConfigurationStore.fetchOrBuildDefault(for: .thread($0), tx: tx) }
        let displayName = SSKEnvironment.shared.contactManagerRef.displayName(for: address, tx: tx)
        let item = ContactConversationItem(
            address: address,
            isBlocked: false,
            disappearingMessagesConfig: dmConfig,
            comparableName: ComparableDisplayName(address: address, displayName: displayName, config: .current()),
        )
        return TellomiForwardTarget(
            kind: .contact(address),
            item: item,
            shortName: displayName.resolvedValue(useShortNameIfAvailable: true),
            fullName: displayName.resolvedValue(),
        )
    }
}
