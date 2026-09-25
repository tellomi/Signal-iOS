//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import GRDB
import SignalServiceKit

/// Tellomi（tellomi/tellomi#1121 F-6）：「最近发送的文件」从本机数据库读——我发出的消息正文里的文件类附件
/// （上游「所有媒体 → 文件」同一个判据 `isInvalidOrFileContentType`，只是不按会话、只要我发出的）。
///
/// 上游的 `MediaGalleryAttachmentFinder` 只按会话查、字段在 SignalServiceKit 里不公开，这里直接读同一组列：
/// - 一份内容只有一行 `Attachment`（`sha256ContentHash` 唯一），同一个文件发给几个人是几条引用、同一个 `attachmentRowId`，
///   所以按 `attachmentRowId` 去重就是按内容去重，留最新的一次；
/// - 本机还有文件 = 上游 `Attachment.init` 建 `streamInfo` 要的五列都在（被存储管理清掉的就不在了）。
final class TellomiRecentFilesDatabaseSource: TellomiRecentFilesSource {

    func loadRecentFiles(limit: Int, completion: @escaping ([TellomiRecentFile]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let files = SSKEnvironment.shared.databaseStorageRef.read { tx in
                Self.fetch(limit: limit, tx: tx)
            }
            DispatchQueue.main.async {
                completion(files)
            }
        }
    }

    static func fetch(limit: Int, tx: DBReadTransaction) -> [TellomiRecentFile] {
        let sql = """
            SELECT
                r.attachmentRowId, r.ownerRowId, r.sourceFilename, r.receivedAtTimestamp,
                COALESCE(a.unencryptedByteCount, r.sourceUnencryptedByteCount, 0) AS byteCount,
                a.mimeType,
                (a.sha256ContentHash IS NOT NULL AND a.encryptedByteCount IS NOT NULL AND a.unencryptedByteCount IS NOT NULL
                    AND a.digestSHA256Ciphertext IS NOT NULL AND a.localRelativeFilePath IS NOT NULL) AS isOnDevice
            FROM MessageAttachmentReference AS r
            JOIN Attachment AS a ON a.id = r.attachmentRowId
            JOIN model_TSInteraction AS i ON i.id = r.ownerRowId
            WHERE r.ownerType = 0
                AND r.isViewOnce = 0
                AND r.ownerIsPastEditRevision = 0
                AND r.isInvalidOrFileContentType = 1
                AND i.recordType = \(SDSRecordType.outgoingMessage.rawValue)
            ORDER BY r.receivedAtTimestamp DESC, r.ownerRowId DESC, r.orderInMessage DESC
            """
        var seen = Set<Int64>()
        var files = [TellomiRecentFile]()
        do {
            let cursor = try Row.fetchCursor(tx.database, sql: sql)
            while files.count < limit, let row = try cursor.next() {
                let attachmentRowId: Int64 = row["attachmentRowId"]
                guard seen.insert(attachmentRowId).inserted else { continue }
                let mimeType: String? = row["mimeType"]
                files.append(TellomiRecentFile(
                    id: "\(attachmentRowId)",
                    attachmentRowId: attachmentRowId,
                    messageRowId: row["ownerRowId"],
                    fileName: displayName(sourceFilename: row["sourceFilename"], mimeType: mimeType),
                    byteCount: UInt64(max(0, row["byteCount"] as Int64)),
                    sentAt: Date(millisecondsSince1970: row["receivedAtTimestamp"]),
                    isOnDevice: row["isOnDevice"],
                ))
            }
        } catch {
            owsFailDebug("Couldn't read recent files: \(error)")
        }
        return files
    }

    /// 没有原文件名的（很少见）：上游的默认名 + 按类型补的扩展名。
    static func displayName(sourceFilename: String?, mimeType: String?) -> String {
        if let name = sourceFilename?.strippedOrNil {
            return name
        }
        let base = OWSLocalizedString("ATTACHMENT_DEFAULT_FILENAME", comment: "Generic filename for an attachment with no known name")
        if let mimeType, let fileExtension = MimeTypeUtil.fileExtensionForMimeType(mimeType) {
            return "\(base).\(fileExtension)"
        }
        return base
    }
}
