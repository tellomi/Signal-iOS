//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import SignalServiceKit
import SignalUI

#if USE_DEBUG_UI

/// 只在调试构建里：往一个假联系人的会话里塞几条「收到的」带 `rich` 的链接预览，不用第二个账号就能看气泡
/// （tellomi/tellomi#1423）。网址取自 `links/tests/corpus/` 里的真实样例，标题和作者是演示用的假值；第一方链接用合成值。
class DebugUITellomiLinkCards: DebugUIPage {

    let name = "Tellomi link cards"

    private struct Fixture {
        let title: String
        /// 消息正文；不写就是这条链接本身（「只有一条链接」的情形）。
        let body: String?
        let url: String
        let previewTitle: String?
        let previewDescription: String?
        let rich: Rich?
        /// false：只发正文，不带预览（预览关了或没抓到）。
        var hasPreview = true

        struct Rich {
            let kind: String
            let provider: String
            let canonicalUrl: String?
            let level: UInt32
            let attrs: [(String, String)]
        }
    }

    private static let fixtures: [Fixture] = [
        Fixture(
            title: "B 站视频（结构化）",
            body: nil,
            url: "https://www.bilibili.com/video/BV1YDhJ6ZEL6",
            previewTitle: "【演示】给朋友发一条视频链接会长什么样",
            previewDescription: "发送端写的描述——不该出现在卡片上",
            rich: .init(
                kind: "video",
                provider: "bilibili",
                canonicalUrl: "https://www.bilibili.com/video/BV1YDhJ6ZEL6",
                level: 2,
                attrs: [("author", "演示UP主"), ("duration_ms", "257000"), ("published_at", "2025-03-14T10:00:00Z")],
            ),
        ),
        Fixture(
            title: "淘宝商品（品牌壳）",
            body: nil,
            url: "https://item.taobao.com/item.htm?id=674169489573",
            previewTitle: "登录",
            previewDescription: nil,
            rich: .init(kind: "product", provider: "taobao", canonicalUrl: nil, level: 1, attrs: []),
        ),
        Fixture(
            title: "网易云单曲（结构化）",
            body: nil,
            url: "https://music.163.com/song?id=1901371647",
            previewTitle: "演示歌曲",
            previewDescription: nil,
            rich: .init(
                kind: "music.track",
                provider: "netease-music",
                canonicalUrl: nil,
                level: 2,
                attrs: [("artist", "演示歌手"), ("album", "演示专辑"), ("duration_ms", "213000")],
            ),
        ),
        Fixture(
            title: "Tellomi 用户（tell.cc/用户名）",
            body: nil,
            url: "https://tell.cc/hk881qb",
            previewTitle: "Tellomi",
            previewDescription: nil,
            rich: nil,
        ),
        Fixture(
            title: "Tellomi 官网",
            body: nil,
            url: "https://tellomi.app/download",
            previewTitle: "Tellomi",
            previewDescription: nil,
            rich: nil,
        ),
        Fixture(
            title: "普通网页（有标题和描述）",
            body: nil,
            url: "https://example.com/",
            previewTitle: "Example Domain",
            previewDescription: "This domain is for use in illustrative examples in documents.",
            rich: nil,
        ),
        Fixture(
            title: "正文还有别的字 + 链接",
            body: "看看这个 https://www.bilibili.com/video/BV1YDhJ6ZEL6",
            url: "https://www.bilibili.com/video/BV1YDhJ6ZEL6",
            previewTitle: "【演示】给朋友发一条视频链接会长什么样",
            previewDescription: nil,
            rich: .init(
                kind: "video",
                provider: "bilibili",
                canonicalUrl: nil,
                level: 2,
                attrs: [("author", "演示UP主"), ("duration_ms", "257000")],
            ),
        ),
        Fixture(
            title: "只有链接、没有预览",
            body: nil,
            url: "https://www.bilibili.com/video/BV1YDhJ6ZEL6",
            previewTitle: nil,
            previewDescription: nil,
            rich: nil,
            hasPreview: false,
        ),
        Fixture(
            title: "仿冒域名（没有预览）",
            body: nil,
            url: "https://www.bi1ibili.com/video/BV1YDhJ6ZEL6",
            previewTitle: nil,
            previewDescription: nil,
            rich: nil,
            hasPreview: false,
        ),
    ]

    func section(thread: TSThread?) -> OWSTableSection? {
        var items = [OWSTableItem]()

        items.append(OWSTableItem(title: "新建假联系人会话（已接受）并塞入全部", actionBlock: {
            let thread = Self.makeFakeContactThread(accepted: true)
            Self.insertAll(into: thread)
        }))
        items.append(OWSTableItem(title: "新建假联系人会话（消息请求）并塞入全部", actionBlock: {
            let thread = Self.makeFakeContactThread(accepted: false)
            Self.insertAll(into: thread)
        }))

        if let contactThread = thread as? TSContactThread {
            items.append(OWSTableItem(title: "往当前会话塞入全部", actionBlock: {
                Self.insertAll(into: contactThread)
            }))
            for fixture in Self.fixtures {
                items.append(OWSTableItem(title: "当前会话：\(fixture.title)", actionBlock: {
                    Self.insert(fixture, into: contactThread)
                }))
            }
        }

        return OWSTableSection(title: name, items: items)
    }

    // MARK: -

    private static func makeFakeContactThread(accepted: Bool) -> TSContactThread {
        let aci = Aci(fromUUID: UUID())
        let thread = TSContactThread.getOrCreateThread(contactAddress: SignalServiceAddress(aci))
        if accepted {
            SSKEnvironment.shared.databaseStorageRef.write { tx in
                var recipient = DependenciesBridge.shared.recipientFetcher.fetchOrCreate(serviceId: aci, tx: tx)
                SSKEnvironment.shared.profileManagerRef.addRecipientToProfileWhitelist(
                    &recipient,
                    userProfileWriter: .debugging,
                    tx: tx,
                )
            }
        }
        return thread
    }

    private static func insertAll(into thread: TSContactThread) {
        for fixture in fixtures {
            insert(fixture, into: thread)
        }
    }

    private static func insert(_ fixture: Fixture, into thread: TSContactThread) {
        guard let authorAci = thread.contactAddress.aci else {
            owsFailDebug("The thread has no ACI.")
            return
        }
        let richBytes = fixture.rich.flatMap { rich -> Data? in
            let builder = SSKProtoRichContent.builder()
            builder.setKind(rich.kind)
            builder.setProvider(rich.provider)
            builder.setSchema(1)
            if let canonicalUrl = rich.canonicalUrl {
                builder.setCanonicalURL(canonicalUrl)
            }
            builder.setLevel(rich.level)
            for (key, value) in rich.attrs {
                let attr = SSKProtoAttr.builder()
                attr.setKey(key)
                attr.setValue(value)
                builder.addAttrs(attr.buildInfallibly())
            }
            return try? builder.buildSerializedData()
        }
        SSKEnvironment.shared.databaseStorageRef.write { tx in
            let body = DependenciesBridge.shared.attachmentContentValidator.truncatedMessageBodyForInlining(
                MessageBody(text: fixture.body ?? fixture.url, ranges: .empty),
                tx: tx,
            )
            let linkPreview = fixture.hasPreview
                ? OWSLinkPreview(
                    urlString: fixture.url,
                    title: fixture.previewTitle,
                    previewDescription: fixture.previewDescription,
                    date: nil,
                    rich: richBytes,
                )
                : nil
            let builder: TSIncomingMessageBuilder = .withDefaultValues(
                thread: thread,
                timestamp: Date.ows_millisecondTimestamp(),
                authorAci: authorAci,
                messageBody: body,
                linkPreview: linkPreview,
            )
            let message = builder.build()
            message.anyInsert(transaction: tx)
        }
    }
}

#endif
