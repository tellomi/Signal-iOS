//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// ADR-0063 §5.1 铁律 2：故事编辑器取不到链接预览时不出错误提示（tellomi/tellomi#1423）。
final class TellomiStoryLinkComposerTest: XCTestCase {

    func testFailedPreviewFallsBackToThePlainLinkCard() {
        let url = URL(string: "https://www.tellomi-test.cn/article/1")!
        for error in [LinkPreviewError.fetchFailure, .noPreview, .invalidPreview, .featureDisabled] {
            // OWSLinkPreviewDraft 的 == 比的是对象本身，这里逐个字段核：只有 URL，没有任何从网上来的东西
            guard case .draft(let draft) = LinkPreviewAttachmentViewController.panelState(for: .failed(error), currentUrl: url) else {
                XCTFail("expected a plain-link draft for \(error)")
                continue
            }
            XCTAssertEqual(draft.url, url)
            XCTAssertNil(draft.title)
            XCTAssertNil(draft.imageData)
            XCTAssertNil(draft.previewDescription)
        }
    }

    func testOtherStatesAreUnchanged() {
        let url = URL(string: "https://www.tellomi-test.cn/article/1")!
        let draft = OWSLinkPreviewDraft(url: url, title: "标题", isForwarded: false)
        XCTAssertEqual(LinkPreviewAttachmentViewController.panelState(for: .none, currentUrl: nil), .placeholder)
        XCTAssertEqual(LinkPreviewAttachmentViewController.panelState(for: .loading, currentUrl: url), .loading)
        XCTAssertEqual(LinkPreviewAttachmentViewController.panelState(for: .loaded(draft), currentUrl: url), .draft(draft))
    }
}
