//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

/// tellomi/tellomi#1257（owner 2026-09-25，照 Telegram）：查看器里的按钮一律是深色的，不管系统是浅色还是深色模式、
/// 也不管背后的图有多亮。
///
/// iOS 26 的玻璃会跟着背后内容的亮度自己变浅：白底的图（截图、文档）上，按钮成了白玻璃，看不清；加深色 tint 也压不住
/// （白底上量出来仍是中灰）。Telegram 的查看器（GalleryTitleView、底栏 GlassControlPanelComponent）写死深色主题，还把玻璃的
/// 亮度锁在深色区间（私有参数，这里不用）；它在没有玻璃的旧系统上画的是约 11% 灰、0.85 不透明的实心底。
/// 这里照后者：按钮是实心深色圆钮、白色图标；顶栏按钮不要系统的共享玻璃底；只建一次的玻璃（标题胶囊）垫一层深色底；
/// 会在「有玻璃 / 无玻璃」之间切换的底（说明、视频进度条）用透明玻璃 + 深色 tint。iOS 26 以前上游查看器本来就强制深色，不用改。
@available(iOS 26, *)
enum TellomiViewerGlass {
    /// 深色底：约 11% 灰、0.85 不透明。
    static let fill = UIColor(white: 0.11, alpha: 0.85)

    /// 说明、视频进度条这类会切换的底：透明玻璃（自己几乎不提亮）+ 深色 tint。
    static func effect(interactive: Bool = true) -> UIGlassEffect {
        let effect = UIGlassEffect(style: .clear)
        effect.tintColor = UIColor(white: 0.0, alpha: 0.72)
        effect.isInteractive = interactive
        return effect
    }

    /// 只建一次、不切换的玻璃（标题胶囊）：再垫一层深色底。
    static func darken(_ view: UIVisualEffectView) {
        view.contentView.backgroundColor = fill
        // 深色底要跟着玻璃的形状（胶囊）裁掉，不然四个角会露出直角。
        view.clipsToBounds = true
    }

    static func buttonConfiguration() -> UIButton.Configuration {
        var configuration = UIButton.Configuration.filled()
        configuration.baseBackgroundColor = fill
        configuration.baseForegroundColor = .white
        configuration.cornerStyle = .capsule
        return configuration
    }

    /// 顶栏按钮换成深色圆钮；点按、菜单、读屏文字照搬原来那个。
    static func barButtonItem(from item: UIBarButtonItem) -> UIBarButtonItem {
        barButtonItem(image: item.image, accessibilityLabel: item.accessibilityLabel, action: item.primaryAction, menu: item.menu)
    }

    static func barButtonItem(image: UIImage?, accessibilityLabel: String?, action: UIAction?, menu: UIMenu?) -> UIBarButtonItem {
        var configuration = buttonConfiguration()
        configuration.image = image
        configuration.contentInsets = .init(margin: 10)
        let button = UIButton(configuration: configuration, primaryAction: action)
        if let menu {
            button.menu = menu
            button.showsMenuAsPrimaryAction = true
        }
        button.accessibilityLabel = accessibilityLabel
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 44),
            button.heightAnchor.constraint(equalToConstant: 44),
        ])
        let barButtonItem = UIBarButtonItem(customView: button)
        // 系统给顶栏按钮的共享玻璃底会跟着背后的图变浅，不要它。
        barButtonItem.hidesSharedBackground = true
        barButtonItem.menu = menu
        return barButtonItem
    }
}
