//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalUI
import UIKit

/// Tellomi（tellomi/tellomi#1121 F-6）：「最近发送的文件」行左边的 40 pt 文件图标——折角的文件形状，里面是小写扩展名。
/// 颜色按扩展名分组（照 Telegram iOS `ListMessageFileItemNode` 的分组，图形是自己画的）：
/// 红 = 演示 / PDF，绿 = 表格，橙 = 压缩包，其它一律蓝。
final class TellomiFileTypeIcon: UIView {

    enum Tint: Equatable {
        case red
        case green
        case orange
        case blue

        var color: UIColor {
            switch self {
            case .red: return UIColor(rgbHex: 0xE5484D)
            case .green: return UIColor(rgbHex: 0x30A46C)
            case .orange: return UIColor(rgbHex: 0xF76B15)
            case .blue: return UIColor(rgbHex: 0x3E8BF0)
            }
        }
    }

    static let side: CGFloat = 40
    private static let foldSide: CGFloat = 12

    /// 扩展名 = 最后一个「.」之后，小写；没有就空。
    static func fileExtension(of fileName: String) -> String {
        guard let dot = fileName.lastIndex(of: "."), dot != fileName.index(before: fileName.endIndex) else {
            return ""
        }
        return String(fileName[fileName.index(after: dot)...]).lowercased()
    }

    static func tint(forExtension fileExtension: String) -> Tint {
        switch fileExtension {
        case "ppt", "pptx", "pdf", "key": return .red
        case "xls", "xlsx", "csv", "numbers": return .green
        case "zip", "rar", "gz", "gzip", "7z", "tar", "ai": return .orange
        default: return .blue
        }
    }

    private let shapeLayer = CAShapeLayer()
    private let foldLayer = CAShapeLayer()
    private let label = UILabel()

    private(set) var tint: Tint = .blue

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.side, height: Self.side))
        layer.addSublayer(shapeLayer)
        layer.addSublayer(foldLayer)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .white
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        addSubview(label)
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: Self.side, height: Self.side)
    }

    func configure(fileName: String) {
        let fileExtension = Self.fileExtension(of: fileName)
        tint = Self.tint(forExtension: fileExtension)
        label.text = fileExtension
        shapeLayer.fillColor = tint.color.cgColor
        foldLayer.fillColor = UIColor.white.withAlphaComponent(0.35).cgColor
        setNeedsLayout()
    }

    var extensionTextForTesting: String? { label.text }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rect = bounds
        let fold = Self.foldSide
        // 文件形状：右上角切掉一个折角
        let body = UIBezierPath()
        body.move(to: CGPoint(x: rect.minX + 4, y: rect.minY))
        body.addLine(to: CGPoint(x: rect.maxX - fold, y: rect.minY))
        body.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + fold))
        body.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 4))
        body.addQuadCurve(to: CGPoint(x: rect.maxX - 4, y: rect.maxY), controlPoint: CGPoint(x: rect.maxX, y: rect.maxY))
        body.addLine(to: CGPoint(x: rect.minX + 4, y: rect.maxY))
        body.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - 4), controlPoint: CGPoint(x: rect.minX, y: rect.maxY))
        body.addLine(to: CGPoint(x: rect.minX, y: rect.minY + 4))
        body.addQuadCurve(to: CGPoint(x: rect.minX + 4, y: rect.minY), controlPoint: CGPoint(x: rect.minX, y: rect.minY))
        body.close()
        shapeLayer.path = body.cgPath

        let foldPath = UIBezierPath()
        foldPath.move(to: CGPoint(x: rect.maxX - fold, y: rect.minY))
        foldPath.addLine(to: CGPoint(x: rect.maxX - fold, y: rect.minY + fold - 2))
        foldPath.addQuadCurve(to: CGPoint(x: rect.maxX - fold + 2, y: rect.minY + fold), controlPoint: CGPoint(x: rect.maxX - fold, y: rect.minY + fold))
        foldPath.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + fold))
        foldPath.close()
        foldLayer.path = foldPath.cgPath

        label.frame = CGRect(x: 3, y: rect.midY - 2, width: rect.width - 6, height: rect.height / 2)
    }
}
