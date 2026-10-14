//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Tellomi（tellomi/tellomi#1519 M-4，方案 `docs/product/specs/scheduled-send-ios-plan.md` §6.1）：一条还没发出去的定时消息。
///
/// 不是会话里的消息：到点才用当时的会话生成真正的外发消息（时间戳 = 实际发出时刻，阅后即焚取当时的设置，同安卓
/// `MessageTable.clearScheduledStatus`）。所以会话、未读、搜索、备份都看不到它，不用到处加过滤。
/// 附件在排定时已经渲染 / 压缩完，文件复制在 `TellomiScheduledMessageStore.directory(for:)` 里。
public struct TellomiScheduledMessage: Codable, Equatable {

    public struct Attachment: Codable, Equatable {
        /// 记录目录里的文件名。
        public let fileName: String
        public let dataUTI: String
        public let mimeType: String
        public let sourceFilename: String?
        public let renderingFlag: AttachmentReference.RenderingFlag

        public init(fileName: String, dataUTI: String, mimeType: String, sourceFilename: String?, renderingFlag: AttachmentReference.RenderingFlag) {
            self.fileName = fileName
            self.dataUTI = dataUTI
            self.mimeType = mimeType
            self.sourceFilename = sourceFilename
            self.renderingFlag = renderingFlag
        }
    }

    /// `OWSLinkPreviewDraft` 的字段（排定时已经取好，到点不再上网取）。
    public struct LinkPreview: Codable, Equatable {
        public let url: URL
        public let title: String?
        public let imageData: Data?
        public let imageMimeType: String?
        public let previewDescription: String?
        public let date: Date?
        public let isForwarded: Bool
        public let rich: Data?

        public init(_ draft: OWSLinkPreviewDraft) {
            url = draft.url
            title = draft.title
            imageData = draft.imageData
            imageMimeType = draft.imageMimeType
            previewDescription = draft.previewDescription
            date = draft.date
            isForwarded = draft.isForwarded
            rich = draft.rich
        }

        public var draft: OWSLinkPreviewDraft {
            OWSLinkPreviewDraft(
                url: url,
                title: title,
                imageData: imageData,
                imageMimeType: imageMimeType,
                previewDescription: previewDescription,
                date: date,
                isForwarded: isForwarded,
                rich: rich,
            )
        }
    }

    public let id: String
    public let threadUniqueId: String
    public var scheduledAt: Date
    /// 同一时刻排了几条（例如「单独发送」拆开的）时按它排先后。
    public let createdAt: Date
    /// `MessageBody`（文字 + @ / 样式）按 NSSecureCoding 归档。
    public let body: Data?
    public let attachments: [Attachment]
    public let isViewOnce: Bool
    public let captionAboveMedia: Bool
    /// 引用回复：到点按它在会话里重新找原消息（同上游草稿的 `ThreadReplyInfo`）；原消息没了就不带引用。
    public let replyInfo: ThreadReplyInfo?
    public let linkPreview: LinkPreview?

    public init(
        id: String = UUID().uuidString,
        threadUniqueId: String,
        scheduledAt: Date,
        createdAt: Date = Date(),
        body: MessageBody?,
        attachments: [Attachment],
        isViewOnce: Bool,
        captionAboveMedia: Bool,
        replyInfo: ThreadReplyInfo?,
        linkPreview: LinkPreview?,
    ) throws {
        self.id = id
        self.threadUniqueId = threadUniqueId
        self.scheduledAt = scheduledAt
        self.createdAt = createdAt
        self.body = try body.map { try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
        self.attachments = attachments
        self.isViewOnce = isViewOnce
        self.captionAboveMedia = captionAboveMedia
        self.replyInfo = replyInfo
        self.linkPreview = linkPreview
    }

    public func messageBody() throws -> MessageBody? {
        guard let body else { return nil }
        guard let messageBody = try NSKeyedUnarchiver.unarchivedObject(ofClass: MessageBody.self, from: body) else {
            throw OWSAssertionError("Couldn't decode the scheduled message body.")
        }
        return messageBody
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.threadUniqueId == rhs.threadUniqueId
            && lhs.scheduledAt == rhs.scheduledAt
            && lhs.createdAt == rhs.createdAt
            && lhs.body == rhs.body
            && lhs.attachments == rhs.attachments
            && lhs.isViewOnce == rhs.isViewOnce
            && lhs.captionAboveMedia == rhs.captionAboveMedia
            && lhs.replyInfo?.timestamp == rhs.replyInfo?.timestamp
            && lhs.replyInfo?.author == rhs.replyInfo?.author
            && lhs.linkPreview == rhs.linkPreview
    }
}

/// Tellomi（#1519 M-4）：定时消息的记录（KeyValueStore 一个 collection，键 = id）和附件文件（共享容器 `TellomiScheduled/<id>/`）。
///
/// 只在这台 iPhone 上（同安卓）：文件不进 iCloud 备份，记录不进 Signal 备份（备份只导出会话里的消息）。
/// 改动在事务提交后发 `didChange`，执行器据此重排定时器、界面据此刷新。
public enum TellomiScheduledMessageStore {

    public static let didChange = Notification.Name("TellomiScheduledMessageStoreDidChange")

    private static let store = KeyValueStore(collection: "TellomiScheduledMessage")

    public static func rootDirectory() -> URL {
        OWSFileSystem.appSharedDataDirectoryURL().appendingPathComponent("TellomiScheduled", isDirectory: true)
    }

    public static func directory(for id: String) -> URL {
        rootDirectory().appendingPathComponent(id, isDirectory: true)
    }

    public static func fileUrl(for attachment: TellomiScheduledMessage.Attachment, messageId: String) -> URL {
        directory(for: messageId).appendingPathComponent(attachment.fileName)
    }

    // MARK: - Reads

    /// 全部，按到点时刻（再按排定先后）排好。
    public static func fetchAll(tx: DBReadTransaction) -> [TellomiScheduledMessage] {
        let messages: [TellomiScheduledMessage]
        do {
            messages = try store.allCodableValues(transaction: tx)
        } catch {
            owsFailDebug("Couldn't read scheduled messages: \(error)")
            return []
        }
        return messages.sorted { lhs, rhs in
            if lhs.scheduledAt != rhs.scheduledAt {
                return lhs.scheduledAt < rhs.scheduledAt
            }
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id < rhs.id
        }
    }

    public static func fetch(id: String, tx: DBReadTransaction) -> TellomiScheduledMessage? {
        do {
            return try store.getCodableValue(forKey: id, transaction: tx)
        } catch {
            owsFailDebug("Couldn't read scheduled message: \(error)")
            return nil
        }
    }

    /// 到点（`scheduledAt ≤ now`）的，按先后。
    public static func fetchDue(now: Date, tx: DBReadTransaction) -> [TellomiScheduledMessage] {
        fetchAll(tx: tx).filter { $0.scheduledAt <= now }
    }

    public static func nextScheduledAt(tx: DBReadTransaction) -> Date? {
        fetchAll(tx: tx).first?.scheduledAt
    }

    public static func fetchAll(threadUniqueId: String, tx: DBReadTransaction) -> [TellomiScheduledMessage] {
        fetchAll(tx: tx).filter { $0.threadUniqueId == threadUniqueId }
    }

    // MARK: - Writes

    /// 记下一条（文件要先放进 `directory(for:)`）。
    public static func insert(_ message: TellomiScheduledMessage, tx: DBWriteTransaction) throws {
        try store.setCodable(message, key: message.id, transaction: tx)
        postDidChange(tx: tx)
    }

    /// 改到点时刻。记录已经没了（发出 / 删掉）返回 false。
    @discardableResult
    public static func reschedule(id: String, to date: Date, tx: DBWriteTransaction) throws -> Bool {
        guard var message = fetch(id: id, tx: tx) else {
            return false
        }
        message.scheduledAt = date
        try store.setCodable(message, key: id, transaction: tx)
        postDidChange(tx: tx)
        return true
    }

    /// 删掉记录；事务提交后删文件。记录本来就没有返回 false——到点发送用它「认领」：和消息落库在同一个写事务里，
    /// 谁先删到谁发，崩溃重来、几处同时触发都不会重发。
    @discardableResult
    public static func remove(id: String, tx: DBWriteTransaction) -> Bool {
        guard store.hasValue(id, transaction: tx) else {
            return false
        }
        store.removeValue(forKey: id, transaction: tx)
        tx.addSyncCompletion {
            deleteDirectory(id: id)
        }
        postDidChange(tx: tx)
        return true
    }

    /// 删会话时一起删（同安卓：定时消息就在会话的消息表里，跟着会话删）。
    public static func removeAll(threadUniqueId: String, tx: DBWriteTransaction) {
        let ids = fetchAll(threadUniqueId: threadUniqueId, tx: tx).map(\.id)
        guard !ids.isEmpty else { return }
        Logger.info("Removing \(ids.count) scheduled message(s) of a deleted chat.")
        for id in ids {
            remove(id: id, tx: tx)
        }
    }

    /// 没有记录的目录（删记录后、删文件前崩了，或排定时写了文件、没写成记录）：启动时清掉。
    public static func deleteOrphanedDirectories(tx: DBReadTransaction) {
        let ids = Set(store.allKeys(transaction: tx))
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(at: rootDirectory(), includingPropertiesForKeys: nil)
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
            return
        } catch {
            Logger.warn("Couldn't list scheduled message files: \(error)")
            return
        }
        for url in contents where !ids.contains(url.lastPathComponent) {
            Logger.info("Deleting orphaned scheduled message files.")
            deleteDirectory(url)
        }
    }

    private static func deleteDirectory(id: String) {
        deleteDirectory(directory(for: id))
    }

    private static func deleteDirectory(_ url: URL) {
        do {
            try OWSFileSystem.deleteFileIfExists(url: url)
        } catch {
            Logger.warn("Couldn't delete scheduled message files: \(error)")
        }
    }

    private static func postDidChange(tx: DBWriteTransaction) {
        tx.addSyncCompletion {
            NotificationCenter.default.postOnMainThread(name: didChange, object: nil)
        }
    }
}
