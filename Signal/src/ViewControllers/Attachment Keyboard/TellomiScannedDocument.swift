//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import UIKit

/// Tellomi（tellomi/tellomi#1121 F-5）：系统文档扫描器扫出来的几页合成**一个 PDF**（同 Telegram iOS
/// `ChatControllerOpenDocumentScanner`：所有页一个文件、文件名是扫描的标题），每页按图片原尺寸一页。
enum TellomiScannedDocument {

    /// 文件名：扫描的标题（去掉不能进文件名的字符）或「扫描」，加 `.pdf`。
    static func fileName(title: String?) -> String {
        let fallback = OWSLocalizedString("ATTACHMENT_FILES_TELLOMI_SCAN_FILENAME", comment: "File name (without .pdf) of a scanned document that has no title.")
        let cleaned = (title ?? "")
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned.isEmpty ? fallback : cleaned) + ".pdf"
    }

    /// 把 [pages] 画成一个 PDF，写到临时目录，返回文件地址。
    static func makePDF(pages: [UIImage], title: String?) throws -> URL {
        guard let first = pages.first else {
            throw OWSAssertionError("No pages to scan")
        }
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName(title: title))
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: first.size))
        try renderer.writePDF(to: url) { context in
            for page in pages {
                let bounds = CGRect(origin: .zero, size: page.size)
                context.beginPage(withBounds: bounds, pageInfo: [:])
                page.draw(in: bounds)
            }
        }
        return url
    }
}
