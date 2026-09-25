//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import GRDB
import SignalServiceKit
import SignalUI

class AllMediaViewController: OWSViewController {
    private let tileViewController: MediaTileViewController
    private let accessoriesHelper = MediaGalleryAccessoriesHelper()
    private let thread: TSThread

    /// Tellomi：从「我的收藏」的分类点进来时一开始停在哪一段（#1174）。
    var tellomiInitialSegmentIndex: Int?
    private var tellomiLinksViewController: TellomiSavedLinksViewController?

    override var navigationItem: UINavigationItem {
        return tileViewController.navigationItem
    }

    init(
        thread: TSThread,
        spoilerState: SpoilerRenderState,
        name: String?,
    ) {
        tileViewController = MediaTileViewController(
            thread: thread,
            accessoriesHelper: accessoriesHelper,
            spoilerState: spoilerState,
        )
        self.thread = thread
        super.init()
        navigationItem.title = name
        accessoriesHelper.viewController = tileViewController
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(tileViewController)
        view.addSubview(tileViewController.view)
        tileViewController.view.autoPinEdgesToSuperviewEdges()

        accessoriesHelper.tellomiLinksSelectionChanged = { [weak self] showsLinks in
            self?.tellomiShowLinks(showsLinks)
        }
        if let tellomiInitialSegmentIndex {
            accessoriesHelper.tellomiSelectSegment(tellomiInitialSegmentIndex)
        }
    }

    /// Tellomi：「链接」一段是一张盖在媒体网格上面的列表（#1174）。
    private func tellomiShowLinks(_ showsLinks: Bool) {
        if showsLinks {
            guard tellomiLinksViewController == nil else {
                return
            }
            let links = TellomiSavedLinksViewController(threadUniqueId: thread.uniqueId)
            addChild(links)
            view.addSubview(links.view)
            links.view.autoPinEdgesToSuperviewEdges()
            links.didMove(toParent: self)
            tellomiLinksViewController = links
        } else if let links = tellomiLinksViewController {
            links.willMove(toParent: nil)
            links.view.removeFromSuperview()
            links.removeFromParent()
            tellomiLinksViewController = nil
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func themeDidChange() {
        owsNavigationController?.updateNavbarAppearance()
    }
}

extension AllMediaViewController: MediaPresentationContextProvider {

    func mediaPresentationContext(item: Media, in coordinateSpace: UICoordinateSpace) -> MediaPresentationContext? {
        return tileViewController.mediaPresentationContext(item: item, in: coordinateSpace)
    }
}

extension AllMediaViewController: OWSNavigationChildController {

    var navbarBackgroundColorOverride: UIColor? { Theme.tableView2PresentedBackgroundColor }
}

// MARK: - Tellomi（tellomi/tellomi#1174）

/// 带链接预览的消息。iOS「所有媒体」原来没有「链接」这一段，Tellomi 补上（Android 按同样的条件列：消息带链接预览）。
enum TellomiSavedLinks {

    struct Item: Equatable {
        let interactionUniqueId: String
        let url: URL
        let title: String?
        let timestamp: UInt64
    }

    private static let interactionTable = "model_TSInteraction"

    static func hasAny(threadUniqueId: String, tx: DBReadTransaction) -> Bool {
        let sql = "SELECT EXISTS(SELECT 1 FROM \(interactionTable) WHERE uniqueThreadId = ? AND linkPreview IS NOT NULL)"
        do {
            return try Bool.fetchOne(tx.database, sql: sql, arguments: [threadUniqueId]) ?? false
        } catch {
            owsFailDebug("Couldn't look for links: \(error)")
            return false
        }
    }

    /// 新的在上；链接预览里没有网址的跳过。
    static func items(threadUniqueId: String, tx: DBReadTransaction) -> [Item] {
        let sql = "SELECT uniqueId FROM \(interactionTable) WHERE uniqueThreadId = ? AND linkPreview IS NOT NULL ORDER BY id DESC"
        let uniqueIds: [String]
        do {
            uniqueIds = try String.fetchAll(tx.database, sql: sql, arguments: [threadUniqueId])
        } catch {
            owsFailDebug("Couldn't list links: \(error)")
            return []
        }
        return uniqueIds.compactMap { uniqueId in
            guard
                let message = TSInteraction.anyFetch(uniqueId: uniqueId, transaction: tx) as? TSMessage,
                let linkPreview = message.linkPreview,
                let urlString = linkPreview.urlString,
                let url = URL(string: urlString)
            else {
                return nil
            }
            return Item(interactionUniqueId: uniqueId, url: url, title: linkPreview.title, timestamp: message.timestamp)
        }
    }
}

/// 「所有媒体」的「链接」一段：带链接预览的消息，新的在上；一行 = 标题（没有就用域名）· 网址 · 日期，点了用浏览器打开（Android 同）。
final class TellomiSavedLinksViewController: OWSTableViewController2 {

    private let threadUniqueId: String

    init(threadUniqueId: String) {
        self.threadUniqueId = threadUniqueId
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        reloadLinks()
    }

    func reloadLinks() {
        let items = SSKEnvironment.shared.databaseStorageRef.read { tx in
            TellomiSavedLinks.items(threadUniqueId: threadUniqueId, tx: tx)
        }
        let section = OWSTableSection()
        if items.isEmpty {
            section.add(.label(withText: TellomiSavedCategory.localized("ALL_MEDIA_TELLOMI_LINKS_EMPTY", english: "No links yet"), accessoryType: .none))
        }
        for item in items {
            let date = Date(millisecondsSince1970: item.timestamp)
            section.add(.disclosureItem(
                withText: item.title ?? item.url.host ?? item.url.absoluteString,
                subtitle: item.url.absoluteString,
                accessoryText: DateUtil.formatDateShort(date),
                actionBlock: {
                    UIApplication.shared.open(item.url)
                },
            ))
        }
        contents = OWSTableContents(sections: [section])
    }
}
