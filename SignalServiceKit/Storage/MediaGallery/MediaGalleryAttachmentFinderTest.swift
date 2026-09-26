//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB
import XCTest
@testable import SignalServiceKit

class MediaGalleryAttachmentFinderTest: XCTestCase {
    private let attachmentStore = AttachmentStore()
    private var db: InMemoryDB!

    override func setUp() async throws {
        db = InMemoryDB()
    }

    // MARK: - Queries

    func testQueryDateRange() throws {
        let (thread, messageRowId) = insertThreadAndInteraction()
        let threadRowId = thread.sqliteRowId!

        // Insert one matching content type before the date range
        insertAttachment(
            messageRowId: messageRowId,
            threadRowId: threadRowId,
            receivedAtTimestamp: 100,
            mimeType: "image/jpeg",
            orderInMessage: 0,
        )
        // ...and one matching content type after the date range
        insertAttachment(
            messageRowId: messageRowId,
            threadRowId: threadRowId,
            receivedAtTimestamp: 300,
            mimeType: "image/jpeg",
            orderInMessage: 1,
        )
        // ...and one non-matching content type within the date range
        insertAttachment(
            messageRowId: messageRowId,
            threadRowId: threadRowId,
            receivedAtTimestamp: 200,
            mimeType: "audio/mp3",
            orderInMessage: 2,
        )
        // ...and two matching content type within the date range
        insertAttachment(
            messageRowId: messageRowId,
            threadRowId: threadRowId,
            receivedAtTimestamp: 200,
            mimeType: "image/jpeg",
            orderInMessage: 3,
        )
        insertAttachment(
            messageRowId: messageRowId,
            threadRowId: threadRowId,
            receivedAtTimestamp: 200,
            mimeType: "image/jpeg",
            orderInMessage: 4,
        )
        // ...and one within the date range that we will exclude.
        insertAttachment(
            messageRowId: messageRowId,
            threadRowId: threadRowId,
            receivedAtTimestamp: 200,
            mimeType: "image/jpeg",
            orderInMessage: 5,
        )
        // ...and a view once attachment that will be excluded.
        insertAttachment(
            messageRowId: messageRowId,
            threadRowId: threadRowId,
            receivedAtTimestamp: 200,
            mimeType: "image/jpeg",
            orderInMessage: 6,
            isViewOnce: true,
        )
        let exclusionSet = Set<AttachmentReferenceId>([
            .init(ownerId: .messageBodyAttachment(messageRowId: messageRowId), orderInMessage: 5),
        ])

        let finder = MediaGalleryAttachmentFinder(threadId: thread.grdbId!.int64Value, filter: .allPhotoVideoCategory)

        // Should get two results with offset 0
        var query = finder.galleryItemQuery(
            in: .init(
                start: .init(millisecondsSince1970: 150),
                end: .init(millisecondsSince1970: 250),
            ),
            excluding: exclusionSet,
            offset: 0,
            ascending: true,
        )

        var results = try db.read { tx in
            return try query.fetchAll(tx.database)
        }

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].receivedAtTimestamp, 200)
        XCTAssertEqual(results[0].orderInMessage, 3)
        XCTAssertEqual(results[1].receivedAtTimestamp, 200)
        XCTAssertEqual(results[1].orderInMessage, 4)

        // Should get just the second result with offset 1
        query = finder.galleryItemQuery(
            in: .init(
                start: .init(millisecondsSince1970: 150),
                end: .init(millisecondsSince1970: 250),
            ),
            excluding: exclusionSet,
            offset: 1,
            ascending: true,
        )

        results = try db.read { tx in
            return try query.fetchAll(tx.database)
        }

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].receivedAtTimestamp, 200)
        XCTAssertEqual(results[0].orderInMessage, 4)
    }

    func testFiltersDistinguishGifsAndPhotos() throws {
        let (thread, messageRowId) = insertThreadAndInteraction()
        let threadRowId = thread.sqliteRowId!

        // Four representative cases the gifs/photos virtual columns must distinguish:
        // - image/jpeg → photo
        // - image/gif → gif (regardless of renderingFlag)
        // - looping mp4 (renderingFlag=shouldLoop) → gif
        // - non-looping mp4 → video
        let jpegId = insertAttachment(
            messageRowId: messageRowId,
            threadRowId: threadRowId,
            receivedAtTimestamp: 100,
            mimeType: "image/jpeg",
            orderInMessage: 0,
        )
        let gifFileId = insertAttachment(
            messageRowId: messageRowId,
            threadRowId: threadRowId,
            receivedAtTimestamp: 200,
            mimeType: "image/gif",
            orderInMessage: 1,
        )
        let loopingMp4Id = insertAttachment(
            messageRowId: messageRowId,
            threadRowId: threadRowId,
            receivedAtTimestamp: 300,
            mimeType: "video/mp4",
            orderInMessage: 2,
            renderingFlag: .shouldLoop,
        )
        let nonLoopingMp4Id = insertAttachment(
            messageRowId: messageRowId,
            threadRowId: threadRowId,
            receivedAtTimestamp: 400,
            mimeType: "video/mp4",
            orderInMessage: 3,
        )

        func attachmentRowIds(filter: AllMediaFilter) throws -> Set<Attachment.IDType> {
            let finder = MediaGalleryAttachmentFinder(threadId: threadRowId, filter: filter)
            let query = finder.galleryItemQuery(
                in: nil,
                excluding: [],
                offset: 0,
                ascending: true,
            )
            return try db.read { tx in
                Set(try query.fetchAll(tx.database).map(\.attachmentRowId))
            }
        }

        XCTAssertEqual(try attachmentRowIds(filter: .gifs), [gifFileId, loopingMp4Id])
        XCTAssertEqual(try attachmentRowIds(filter: .photos), [jpegId])
        XCTAssertEqual(try attachmentRowIds(filter: .videos), [nonLoopingMp4Id])
        XCTAssertEqual(
            try attachmentRowIds(filter: .allPhotoVideoCategory),
            [jpegId, gifFileId, loopingMp4Id, nonLoopingMp4Id],
        )
    }

    // MARK: - Index Usage

    func testAllQueriesUseIndex() throws {
        let (thread, _) = insertThreadAndInteraction()

        // Set up some parametrized values for tests.
        // Specific values for many things don't matter, just presence
        // and combinations thereof.
        let dateIntervals: [DateInterval?] = [
            nil,
            .init(
                start: .init(millisecondsSince1970: 100),
                end: .init(millisecondsSince1970: 200),
            ),
        ]
        let exclusionSets: [Set<AttachmentReferenceId>] = [
            Set(),
            Set([.init(ownerId: .messageBodyAttachment(messageRowId: 100), orderInMessage: nil)]),
            Set([.init(ownerId: .messageBodyAttachment(messageRowId: 200), orderInMessage: 5)]),
            Set([
                .init(ownerId: .messageBodyAttachment(messageRowId: 100), orderInMessage: nil),
                .init(ownerId: .messageBodyAttachment(messageRowId: 200), orderInMessage: nil),
                .init(ownerId: .messageBodyAttachment(messageRowId: 300), orderInMessage: 5),
            ]),
        ]
        let offsets: [Int] = [0, 5]
        let limits: [Int] = [5, 100]
        let ascendings: [Bool] = [true, false]

        for filter in AllMediaFilter.allCases {
            let finder = MediaGalleryAttachmentFinder(threadId: thread.grdbId!.int64Value, filter: filter)
            var queries = [QueryInterfaceRequest<RecordType>]()

            for dateInterval in dateIntervals {
                for exclusionSet in exclusionSets {
                    for offset in offsets {
                        for ascending in ascendings {
                            queries.append(finder.galleryItemQuery(
                                in: dateInterval,
                                excluding: exclusionSet,
                                offset: offset,
                                ascending: ascending,
                            ))
                        }
                    }
                }
            }
            for dateInterval in dateIntervals.compacted() {
                for exclusionSet in exclusionSets {
                    for offset in offsets {
                        for limit in limits {
                            queries.append(finder.enumerateMediaAttachmentsQuery(
                                in: dateInterval,
                                excluding: exclusionSet,
                                range: .init(location: offset, length: limit),
                            ))
                        }
                    }
                }
            }
            for dateInterval in dateIntervals {
                for exclusionSet in exclusionSets {
                    for limit in limits {
                        queries.append(finder.enumerateTimestampsQuery(
                            beforeDate: dateInterval?.end,
                            afterDate: nil,
                            excluding: exclusionSet,
                            count: limit,
                            ascending: false,
                        ))
                        queries.append(finder.enumerateTimestampsQuery(
                            beforeDate: nil,
                            afterDate: dateInterval?.start,
                            excluding: exclusionSet,
                            count: limit,
                            ascending: true,
                        ))
                    }
                }
            }
            for limit in limits {
                queries.append(finder.recentMediaAttachmentsQuery(limit: limit))
            }

            try db.read { tx in
                for query in queries {
                    let preparedStatement = try query.makePreparedRequest(tx.database).statement
                    let queryPlan: [String] = try Row.fetchAll(
                        tx.database,
                        sql: "EXPLAIN QUERY PLAN \(preparedStatement.sql);",
                        arguments: preparedStatement.arguments,
                    ).map { $0["detail"] }

                    // Ensure we use the relevant indexes and...
                    // * we use all the columns up to the ordering columns
                    // * we DONT use expensive B trees for ordering
                    let allowedQueryPlans: [String] = [
                        "SEARCH MessageAttachmentReference USING INDEX message_attachment_reference_media_gallery_single_content_type_index",
                        "SEARCH MessageAttachmentReference USING INDEX message_attachment_reference_media_gallery_visualMedia_content_type_index",
                        "SEARCH MessageAttachmentReference USING INDEX message_attachment_reference_media_gallery_fileOrInvalid_content_type_index",
                        "SEARCH MessageAttachmentReference USING INDEX message_attachment_reference_media_gallery_gifs_index",
                        "SEARCH MessageAttachmentReference USING INDEX message_attachment_reference_media_gallery_photos_index",
                    ]
                    XCTAssert(queryPlan.allSatisfy { queryPlan in
                        for allowedQueryPlan in allowedQueryPlans {
                            if queryPlan.hasPrefix(allowedQueryPlan) {
                                return true
                            }
                        }
                        return false
                    })
                    // There should NOT be expensive B-TREE usage.
                    XCTAssert(queryPlan.allSatisfy { !$0.contains("USE TEMP B-TREE") })
                }
            }
        }
    }

    // MARK: - Helpers

    typealias RecordType = MediaGalleryAttachmentFinder.RecordType

    private func insertThreadAndInteraction() -> (thread: TSThread, interactionRowId: Int64) {
        let thread = TSThread(uniqueId: UUID().uuidString)
        let interaction = TSInteraction(timestamp: 0, receivedAtTimestamp: 0, thread: thread)

        db.write { tx in
            try! thread.insert(tx.database)
            try! interaction.asRecord().insert(tx.database)
        }

        return (thread, interaction.sqliteRowId!)
    }

    @discardableResult
    private func insertAttachment(
        messageRowId: Int64,
        threadRowId: Int64,
        receivedAtTimestamp: UInt64,
        mimeType: String,
        orderInMessage: UInt32,
        isViewOnce: Bool = false,
        renderingFlag: AttachmentReference.RenderingFlag = .default,
    ) -> Attachment.IDType {
        db.write { tx in
            var attachmentRecord = Attachment.Record.mockStream(
                mimeType: mimeType,
            )
            try! attachmentRecord.insert(tx.database)

            let attachment = Attachment(record: attachmentRecord)

            let referenceParams = AttachmentReference.ConstructionParams.mock(
                owner: .message(.bodyAttachment(.init(
                    messageRowId: messageRowId,
                    receivedAtTimestamp: receivedAtTimestamp,
                    threadRowId: threadRowId,
                    contentType: attachment.contentType,
                    mimeType: attachment.mimeType,
                    isPastEditRevision: false,
                    caption: nil,
                    renderingFlag: renderingFlag,
                    orderInMessage: orderInMessage,
                    idInOwner: nil,
                    isViewOnce: isViewOnce,
                ))),
            )

            attachmentStore.addReference(
                referenceParams,
                attachmentRowId: attachment.id,
                tx: tx,
            )

            return attachment.id
        }
    }
}

// MARK: - Tellomi（tellomi/tellomi#1174）

/// 「我的收藏」的所有媒体里按类型搜：当前这一类里文件名或说明文字包含这段字的留下（需求 official-account-and-saved §3.2 第 2 条）。
class TellomiMediaGallerySearchTest: XCTestCase {
    private let attachmentStore = AttachmentStore()
    private var db: InMemoryDB!

    override func setUp() async throws {
        db = InMemoryDB()
    }

    func testFileNamesAndCaptionsAreSearchedInsideTheCurrentKindOnly() throws {
        let thread = TSThread(uniqueId: UUID().uuidString)
        let interaction = TSInteraction(timestamp: 0, receivedAtTimestamp: 0, thread: thread)
        db.write { tx in
            try! thread.insert(tx.database)
            try! interaction.asRecord().insert(tx.database)
        }
        let messageRowId = interaction.sqliteRowId!
        let threadRowId = thread.sqliteRowId!
        insert(messageRowId, threadRowId, order: 0, mimeType: "application/pdf", fileName: "第三季度报告.pdf", caption: nil)
        insert(messageRowId, threadRowId, order: 1, mimeType: "application/pdf", fileName: "发票.pdf", caption: "报销用的")
        insert(messageRowId, threadRowId, order: 2, mimeType: "application/pdf", fileName: "100%_done.pdf", caption: nil)
        insert(messageRowId, threadRowId, order: 3, mimeType: "image/jpeg", fileName: "IMG_0001.jpg", caption: "季度报告的封面")

        func fileNames(_ filter: AllMediaFilter, _ query: String?) throws -> Set<String?> {
            var finder = MediaGalleryAttachmentFinder(threadId: threadRowId, filter: filter)
            finder.tellomiQuery = query
            let records = try db.read { tx in try finder.recentMediaAttachmentsQuery(limit: 100).fetchAll(tx.database) }
            return Set(records.map(\.sourceFilename))
        }

        XCTAssertEqual(try fileNames(.otherFiles, nil), ["第三季度报告.pdf", "发票.pdf", "100%_done.pdf"])
        XCTAssertEqual(try fileNames(.otherFiles, "  "), ["第三季度报告.pdf", "发票.pdf", "100%_done.pdf"])
        XCTAssertEqual(try fileNames(.otherFiles, "季度报告"), ["第三季度报告.pdf"])
        XCTAssertEqual(try fileNames(.otherFiles, "报销"), ["发票.pdf"])
        XCTAssertEqual(try fileNames(.otherFiles, "%_"), ["100%_done.pdf"])
        XCTAssertEqual(try fileNames(.allPhotoVideoCategory, "季度报告"), ["IMG_0001.jpg"])
    }

    func testTheLikePatternTreatsWildcardsAsText() {
        XCTAssertNil(MediaGalleryAttachmentFinder.tellomiLikePattern(nil))
        XCTAssertNil(MediaGalleryAttachmentFinder.tellomiLikePattern("  "))
        XCTAssertEqual(MediaGalleryAttachmentFinder.tellomiLikePattern(" 报告 "), "%报告%")
        XCTAssertEqual(MediaGalleryAttachmentFinder.tellomiLikePattern("100%_"), "%100\\%\\_%")
    }

    private func insert(_ messageRowId: Int64, _ threadRowId: Int64, order: UInt32, mimeType: String, fileName: String?, caption: String?) {
        db.write { tx in
            var attachmentRecord = Attachment.Record.mockStream(mimeType: mimeType)
            try! attachmentRecord.insert(tx.database)
            let attachment = Attachment(record: attachmentRecord)
            let referenceParams = AttachmentReference.ConstructionParams.mock(
                owner: .message(.bodyAttachment(.init(
                    messageRowId: messageRowId,
                    receivedAtTimestamp: 100 + UInt64(order),
                    threadRowId: threadRowId,
                    contentType: attachment.contentType,
                    mimeType: attachment.mimeType,
                    isPastEditRevision: false,
                    caption: caption,
                    renderingFlag: .default,
                    orderInMessage: order,
                    idInOwner: nil,
                    isViewOnce: false,
                ))),
                sourceFilename: fileName,
            )
            attachmentStore.addReference(referenceParams, attachmentRowId: attachment.id, tx: tx)
        }
    }
}
