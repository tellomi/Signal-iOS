//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

/// Tellomi（tellomi/tellomi#1261 P-7、P-8）：选图网格的布局。
///
/// 正方形格子、间距 1：边长按屏幕像素向下取整，除不尽的摊进列间距（同 flow layout，不会被摊成 1.5 以上）。
/// 顶上可选一条整行的受限访问横幅（section header）。「最近」里左上角挖出一格宽、两行高（含中间 1 的间距）的相机位，
/// 其它格子绕开它排——照 Telegram（iOS MediaPickerScreen 的 camera cutout、Android ChatAttachAlertPhotoLayout 的
/// itemSize * 2 + GAP）。
final class TellomiPhotoPickerGridLayout: UICollectionViewLayout {

    var columns = 3 {
        didSet { if oldValue != columns { invalidateLayout() } }
    }

    var spacing: CGFloat = 1 {
        didSet { if oldValue != spacing { invalidateLayout() } }
    }

    var headerHeight: CGFloat = 0 {
        didSet { if oldValue != headerHeight { invalidateLayout() } }
    }

    var showsCamera = false {
        didSet { if oldValue != showsCamera { invalidateLayout() } }
    }

    var screenScale: CGFloat = UIScreen.main.scale

    private(set) var itemSide: CGFloat = 0
    private var itemAttributes = [UICollectionViewLayoutAttributes]()
    private var headerAttributes: UICollectionViewLayoutAttributes?
    private var cameraAttributes: UICollectionViewLayoutAttributes?
    private var contentHeight: CGFloat = 0

    /// 第 `index` 张落在第几行第几列：有相机时前两行的第 0 列让给相机。
    static func slot(forItem index: Int, columns: Int, showsCamera: Bool) -> (row: Int, column: Int) {
        guard showsCamera, columns > 1 else {
            return (index / columns, index % columns)
        }
        let perRowBesideCamera = columns - 1
        if index < perRowBesideCamera * 2 {
            return (index / perRowBesideCamera, 1 + index % perRowBesideCamera)
        }
        let rest = index - perRowBesideCamera * 2
        return (2 + rest / columns, rest % columns)
    }

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }

        let width = collectionView.bounds.width
        let count = collectionView.numberOfSections > 0 ? collectionView.numberOfItems(inSection: 0) : 0
        let columnCount = CGFloat(max(columns, 1))
        itemSide = max(0, floor((width - spacing * (columnCount - 1)) / columnCount * screenScale) / screenScale)
        let gap = columns > 1 ? (width - itemSide * columnCount) / (columnCount - 1) : 0

        func x(_ column: Int) -> CGFloat {
            (CGFloat(column) * (itemSide + gap) * screenScale).rounded() / screenScale
        }
        func y(_ row: Int) -> CGFloat {
            headerHeight + CGFloat(row) * (itemSide + spacing)
        }

        if headerHeight > 0 {
            let header = UICollectionViewLayoutAttributes(forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, with: IndexPath(item: 0, section: 0))
            header.frame = CGRect(x: 0, y: 0, width: width, height: headerHeight)
            headerAttributes = header
        } else {
            headerAttributes = nil
        }

        if showsCamera {
            let camera = UICollectionViewLayoutAttributes(forSupplementaryViewOfKind: TellomiPhotoPickerCameraCell.kind, with: IndexPath(item: 0, section: 0))
            camera.frame = CGRect(x: x(0), y: y(0), width: itemSide, height: itemSide * 2 + spacing)
            cameraAttributes = camera
        } else {
            cameraAttributes = nil
        }

        itemAttributes = (0..<count).map { index in
            let slot = Self.slot(forItem: index, columns: columns, showsCamera: showsCamera)
            let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
            attributes.frame = CGRect(x: x(slot.column), y: y(slot.row), width: itemSide, height: itemSide)
            return attributes
        }

        var rows = count > 0 ? Self.slot(forItem: count - 1, columns: columns, showsCamera: showsCamera).row + 1 : 0
        if showsCamera {
            rows = max(rows, 2)
        }
        contentHeight = rows > 0 ? y(rows) - spacing : headerHeight
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: collectionView?.bounds.width ?? 0, height: contentHeight)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        var result = itemAttributes.filter { $0.frame.intersects(rect) }
        for supplementary in [headerAttributes, cameraAttributes].compactMap({ $0 }) where supplementary.frame.intersects(rect) {
            result.append(supplementary)
        }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        itemAttributes.indices.contains(indexPath.item) ? itemAttributes[indexPath.item] : nil
    }

    override func layoutAttributesForSupplementaryView(ofKind elementKind: String, at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        switch elementKind {
        case UICollectionView.elementKindSectionHeader:
            return headerAttributes
        case TellomiPhotoPickerCameraCell.kind:
            return cameraAttributes
        default:
            return nil
        }
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.width != collectionView?.bounds.width
    }
}
