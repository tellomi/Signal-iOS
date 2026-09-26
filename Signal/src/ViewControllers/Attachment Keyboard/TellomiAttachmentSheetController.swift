//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalUI
import UIKit

/// Tellomi（tellomi/tellomi#1121 F-1）：附件 Sheet 的容器。dock 的「相册」「文件」在同一个 Sheet 里换页，不收起 Sheet
/// （照 Telegram iOS `AttachmentController`：换页时内容交叉淡入淡出，Sheet 高度不变）。
/// 两页各自带着同一位置的 dock（选中的格子不同），所以换页时 dock 看起来不动。
final class TellomiAttachmentSheetController: UIViewController {

    enum Page: Equatable {
        case gallery
        case files
    }

    let photoPicker: TellomiPhotoPickerViewController
    private let makeFilesPage: () -> UIViewController
    private var filesPage: UIViewController?

    private(set) var page: Page = .gallery

    init(photoPicker: TellomiPhotoPickerViewController, makeFilesPage: @escaping () -> UIViewController) {
        self.photoPicker = photoPicker
        self.makeFilesPage = makeFilesPage
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .Signal.background
        embed(photoPicker)
    }

    /// 选图页选了照片时不许下拉直接关（它自己按「有没有选中」设）：跟着当前页。
    override var isModalInPresentation: Bool {
        get { currentChild.isModalInPresentation || super.isModalInPresentation }
        set { super.isModalInPresentation = newValue }
    }

    /// 换到 [page]；已经是这一页就什么都不做（重复点当前格由页面自己处理：回到顶部并展开）。
    func show(_ page: Page, animated: Bool = true) {
        guard page != self.page else { return }
        let from: UIViewController = currentChild
        self.page = page
        let to: UIViewController
        switch page {
        case .gallery:
            to = photoPicker
        case .files:
            let files = filesPage ?? makeFilesPage()
            filesPage = files
            to = files
        }
        embed(to)
        to.view.alpha = animated ? 0 : 1
        let finish = {
            from.willMove(toParent: nil)
            from.view.removeFromSuperview()
            from.removeFromParent()
        }
        guard animated else {
            finish()
            return
        }
        UIView.animate(withDuration: 0.2, animations: {
            to.view.alpha = 1
            from.view.alpha = 0
        }, completion: { _ in
            from.view.alpha = 1
            finish()
        })
    }

    private var currentChild: UIViewController {
        switch page {
        case .gallery: return photoPicker
        case .files: return filesPage ?? photoPicker
        }
    }

    private func embed(_ child: UIViewController) {
        guard child.parent !== self else { return }
        addChild(child)
        child.view.frame = view.bounds
        child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(child.view)
        child.didMove(toParent: self)
    }

    var visibleChildForTesting: UIViewController? { children.last }
}
