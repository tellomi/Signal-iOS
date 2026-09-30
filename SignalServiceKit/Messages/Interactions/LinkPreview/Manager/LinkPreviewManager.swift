//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

public struct LinkPreviewDataSource {
    public let metadata: OWSLinkPreview.Metadata
    public let imageDataSource: AttachmentDataSource?
    public let isForwarded: Bool
}

public struct ValidatedLinkPreviewProto {
    public let preview: OWSLinkPreview
    public let imageProto: SSKProtoAttachmentPointer?
}

public struct ValidatedLinkPreviewDataSource {
    public let preview: OWSLinkPreview
    public let imageDataSource: AttachmentDataSource?
}

// MARK: -

public protocol LinkPreviewManager {
    func validateAndBuildLinkPreview(
        from proto: SSKProtoPreview,
        dataMessage: SSKProtoDataMessage,
    ) throws -> ValidatedLinkPreviewProto

    func validateAndBuildStoryLinkPreview(
        from proto: SSKProtoPreview,
    ) throws -> ValidatedLinkPreviewProto

    func buildDataSource(
        from draft: OWSLinkPreviewDraft,
    ) async throws -> LinkPreviewDataSource

    func validateDataSource(
        dataSource: LinkPreviewDataSource,
        tx: DBWriteTransaction,
    ) throws -> ValidatedLinkPreviewDataSource

    func buildProtoForSending(
        _ linkPreview: OWSLinkPreview,
        parentMessage: TSMessage,
        tx: DBReadTransaction,
    ) throws -> SSKProtoPreview

    func buildProtoForSending(
        _ linkPreview: OWSLinkPreview,
        parentStoryMessage: StoryMessage,
        tx: DBReadTransaction,
    ) throws -> SSKProtoPreview
}

// MARK: -

class LinkPreviewManagerImpl: LinkPreviewManager {
    private let attachmentStore: AttachmentStore
    private let attachmentValidator: AttachmentContentValidator
    private let db: any DB
    private let linkPreviewSettingStore: LinkPreviewSettingStore
    /// Tellomi：收到预览时的判定（`receive_check`）和预览图门控用它；测试里换成假的。
    private let tellomiClassifier: TellomiLinkClassifier

    init(
        attachmentStore: AttachmentStore,
        attachmentValidator: AttachmentContentValidator,
        db: any DB,
        linkPreviewSettingStore: LinkPreviewSettingStore,
        tellomiClassifier: TellomiLinkClassifier = TellomiLinkRegistry.classifier,
    ) {
        self.attachmentStore = attachmentStore
        self.attachmentValidator = attachmentValidator
        self.db = db
        self.linkPreviewSettingStore = linkPreviewSettingStore
        self.tellomiClassifier = tellomiClassifier
    }

    // MARK: - Public

    func validateAndBuildLinkPreview(
        from proto: SSKProtoPreview,
        dataMessage: SSKProtoDataMessage,
    ) throws -> ValidatedLinkPreviewProto {
        if dataMessage.attachments.count == 1, dataMessage.attachments[0].contentType != MimeType.textXSignalPlain.rawValue {
            Logger.error("Discarding link preview; message has non-text attachment.")
            throw LinkPreviewError.invalidPreview
        }
        if dataMessage.attachments.count > 1 {
            Logger.error("Discarding link preview; message has attachments.")
            throw LinkPreviewError.invalidPreview
        }
        guard let messageBody = dataMessage.body else {
            Logger.error("Url not present in body")
            throw LinkPreviewError.invalidPreview
        }
        // Tellomi（ADR-0063 §5.1 铁律 4、§6.1、§7.4，口径 S2）：上游原来的「链接在正文里」子串检查并进 rust/links 的 `receive_check`。
        let attachmentContentTypes = dataMessage.attachments.compactMap(\.contentType)
        let keepRich = try tellomiReceiveCheck(proto: proto, body: messageBody, attachmentContentTypes: attachmentContentTypes)
        guard
            LinkValidator.canParseURLs(in: messageBody),
            LinkValidator.isValidLink(linkText: proto.url)
        else {
            Logger.error("Discarding link preview; can't parse URLs in message.")
            throw LinkPreviewError.invalidPreview
        }

        let validated = try buildValidatedLinkPreview(proto: proto, keepRich: keepRich)
        return tellomiGatingImage(validated, body: messageBody, attachmentContentTypes: attachmentContentTypes)
    }

    /// Tellomi：预览留不留、`rich` 留不留，以 rust/links 的 `receive_check` 为准：
    /// `keep_preview` 为 false → 整个预览丢掉（消息照收，就当没有预览）；`keep_preview` 为 true 而 `keep_rich` 为 false → 只丢 `rich`，
    /// snapshot 照存。保留时 `rich` 的字节原样存（§7.4）。返回 `rich` 留不留。
    /// 没有判定（注册表没装上、桥出错、答案读不懂）就退回改动前：上游的子串检查照旧，`rich` 照存——收消息绝不因为这里出错而失败。
    private func tellomiReceiveCheck(
        proto: SSKProtoPreview,
        body: String,
        attachmentContentTypes: [String],
    ) throws -> Bool {
        let received = TellomiLinkClassifier.PreviewInput(
            url: proto.url,
            hasImage: proto.image != nil,
            rich: TellomiRichContent.receivedBytes(proto),
        )
        guard
            let check = tellomiClassifier.receiveCheck(
                received,
                body: body,
                isStory: false,
                attachmentContentTypes: attachmentContentTypes,
            )
        else {
            guard body.contains(proto.url) else {
                Logger.error("Url not present in body")
                throw LinkPreviewError.invalidPreview
            }
            return true
        }
        guard check.keepPreview else {
            Logger.error("Discarding link preview; the receive check refused it.")
            throw LinkPreviewError.invalidPreview
        }
        if received.rich != nil, !check.keepRich {
            Logger.warn("Dropping rich content that failed the receive check; keeping the snapshot.")
        }
        return check.keepRich
    }

    /// Tellomi（ADR-0063 §7.4，口径 S2）：预览图附件只在卡片确实要显示图的时候才建——判为纯链接、品牌壳、用户卡、官网卡的预览，
    /// 收到时就不为它的图建附件指针，也就不会下载。判的是渲染时用的同一个 `classify`，级别在收到这一刻定、不追热更；
    /// 判不出（没有注册表、出错）就照旧建。故事里的预览不走这里（渲染时也不走 classify）。
    private func tellomiGatingImage(
        _ validated: ValidatedLinkPreviewProto,
        body: String,
        attachmentContentTypes: [String],
    ) -> ValidatedLinkPreviewProto {
        guard validated.imageProto != nil, let urlString = validated.preview.urlString else {
            return validated
        }
        let card = tellomiClassifier.classify(
            TellomiLinkClassifier.PreviewInput(
                url: urlString,
                title: validated.preview.title,
                description: validated.preview.previewDescription,
                hasImage: true,
                date: validated.preview.date,
                rich: validated.preview.rich,
            ),
            body: body,
            isStory: false,
            attachmentContentTypes: attachmentContentTypes,
        )
        guard let card, !card.showImage else {
            return validated
        }
        // 只记级别，不记 URL。
        Logger.info("Not creating an attachment for the image of a \(card.level.rawValue) link preview: the card does not show it.")
        return ValidatedLinkPreviewProto(preview: validated.preview, imageProto: nil)
    }

    func validateAndBuildStoryLinkPreview(
        from proto: SSKProtoPreview,
    ) throws -> ValidatedLinkPreviewProto {
        guard LinkValidator.isValidLink(linkText: proto.url) else {
            Logger.error("Discarding link preview; can't parse URLs in story message.")
            throw LinkPreviewError.invalidPreview
        }
        return try buildValidatedLinkPreview(proto: proto)
    }

    func buildDataSource(
        from draft: OWSLinkPreviewDraft,
    ) async throws -> LinkPreviewDataSource {
        let areLinkPreviewsEnabled = db.read { linkPreviewSettingStore.areLinkPreviewsEnabled(tx: $0) }
        guard draft.isForwarded || areLinkPreviewsEnabled else {
            throw LinkPreviewError.featureDisabled
        }

        let metadata = OWSLinkPreview.Metadata(
            urlString: draft.urlString,
            title: draft.title,
            previewDescription: draft.previewDescription,
            date: draft.date,
            rich: draft.rich, // Tellomi（ADR-0063 §7.4）：转发时 rich 原样带过去
        )

        if
            let imageData = draft.imageData,
            let imageMimeType = draft.imageMimeType
        {
            let pendingAttachment = try await attachmentValidator.validateDataContents(
                imageData,
                mimeType: imageMimeType,
                renderingFlag: .default,
                sourceFilename: nil,
            )

            return LinkPreviewDataSource(
                metadata: metadata,
                imageDataSource: .pendingAttachment(pendingAttachment),
                isForwarded: draft.isForwarded,
            )
        } else {
            return LinkPreviewDataSource(
                metadata: metadata,
                imageDataSource: nil,
                isForwarded: draft.isForwarded,
            )
        }
    }

    func validateDataSource(
        dataSource: LinkPreviewDataSource,
        tx: DBWriteTransaction,
    ) throws -> ValidatedLinkPreviewDataSource {
        guard dataSource.isForwarded || linkPreviewSettingStore.areLinkPreviewsEnabled(tx: tx) else {
            throw LinkPreviewError.featureDisabled
        }
        return ValidatedLinkPreviewDataSource(
            preview: OWSLinkPreview(metadata: dataSource.metadata),
            imageDataSource: dataSource.imageDataSource,
        )
    }

    func buildProtoForSending(
        _ linkPreview: OWSLinkPreview,
        parentMessage: TSMessage,
        tx: DBReadTransaction,
    ) throws -> SSKProtoPreview {
        let linkPreviewReferencedAttachment = parentMessage.sqliteRowId.flatMap { id in
            return attachmentStore.fetchAnyReferencedAttachment(
                for: .messageLinkPreview(messageRowId: id),
                tx: tx,
            )
        }

        return try buildProtoForSending(
            linkPreview: linkPreview,
            linkPreviewReferencedAttachment: linkPreviewReferencedAttachment,
            tx: tx,
        )
    }

    func buildProtoForSending(
        _ linkPreview: OWSLinkPreview,
        parentStoryMessage: StoryMessage,
        tx: DBReadTransaction,
    ) throws -> SSKProtoPreview {
        let linkPreviewReferencedAttachment = parentStoryMessage.id.flatMap { id in
            return attachmentStore.fetchAnyReferencedAttachment(
                for: .storyMessageLinkPreview(storyMessageRowId: id),
                tx: tx,
            )
        }

        return try buildProtoForSending(
            linkPreview: linkPreview,
            linkPreviewReferencedAttachment: linkPreviewReferencedAttachment,
            tx: tx,
        )
    }

    private func buildValidatedLinkPreview(
        proto: SSKProtoPreview,
        keepRich: Bool = true,
    ) throws -> ValidatedLinkPreviewProto {
        let urlString = proto.url

        guard let url = URL(string: urlString), LinkPreviewHelper.isPermittedLinkPreviewUrl(url) else {
            Logger.error("Could not parse preview url.")
            throw LinkPreviewError.invalidPreview
        }

        var title: String?
        var previewDescription: String?
        if let rawTitle = proto.title {
            let normalizedTitle = LinkPreviewHelper.normalizeString(rawTitle, maxLines: 2)
            if !normalizedTitle.isEmpty {
                title = normalizedTitle
            }
        }
        if let rawDescription = proto.previewDescription, proto.title != proto.previewDescription {
            let normalizedDescription = LinkPreviewHelper.normalizeString(rawDescription, maxLines: 3)
            if !normalizedDescription.isEmpty {
                previewDescription = normalizedDescription
            }
        }

        // Zero check required. Some devices in the wild will explicitly set zero to mean "no date"
        let date: Date?
        if proto.hasDate, proto.date > 0 {
            date = Date(millisecondsSince1970: proto.date)
        } else {
            date = nil
        }

        return ValidatedLinkPreviewProto(
            preview: OWSLinkPreview(metadata: OWSLinkPreview.Metadata(
                urlString: urlString,
                title: title,
                previewDescription: previewDescription,
                date: date,
                // Tellomi（ADR-0063 §7.4）：rich（1000 号字段）按收到的字节带着，含本机不认识的字段；
                // 只有 receive_check 说它超长 / 畸形（§6.1）时才不带，snapshot 照存。
                rich: keepRich ? TellomiRichContent.receivedBytes(proto) : nil,
            )),
            imageProto: proto.image,
        )
    }

    // MARK: - Private, generating outgoing proto

    private func buildProtoForSending(
        linkPreview: OWSLinkPreview,
        linkPreviewReferencedAttachment: ReferencedAttachment?,
        tx: DBReadTransaction,
    ) throws -> SSKProtoPreview {
        guard let urlString = linkPreview.urlString else {
            Logger.error("Preview does not have url.")
            throw LinkPreviewError.invalidPreview
        }

        let builder = SSKProtoPreview.builder(url: urlString)

        if let title = linkPreview.title {
            builder.setTitle(title)
        }

        if let previewDescription = linkPreview.previewDescription {
            builder.setPreviewDescription(previewDescription)
        }

        if
            let linkPreviewReferencedAttachment,
            let attachmentProto = linkPreviewReferencedAttachment.asProtoForSending()
        {
            builder.setImage(attachmentProto)
        }

        if let date = linkPreview.date, date.timeIntervalSince1970 > 0 {
            builder.setDate(date.ows_millisecondsSince1970)
        }

        // Tellomi（ADR-0063 §7.4）：rich 原样发出；没有就不带，与上游逐字节相同。
        if let rich = TellomiRichContent.forSending(linkPreview.rich) {
            builder.setRich(rich)
        }

        return try builder.build()
    }
}
