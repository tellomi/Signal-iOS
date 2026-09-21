//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import UIKit

extension UIApplication {
    var currentAppIcon: AppIcon {
        if let alternateIconName, let appIcon = AppIcon(alternateIconName: alternateIconName) {
            return appIcon
        }
        return .default
    }
}

// Tellomi：上游的 white / color / dark / dark-variant 四个备用图标画的是 Signal 的标，
// 按商标红线整套删掉（.icon 包、预览图、pbxproj 条目、ALTERNATE_APPICON_NAMES 一并删）。
// 剩下的是「伪装」图标（新闻 / 备忘 / 天气…），不含 Signal 品牌，保留。
enum AppIcon: String {
    case `default` = "AppIcon"
    case chat = "AppIcon-chat"
    case bubbles = "AppIcon-bubbles"
    case yellow = "AppIcon-yellow"
    case news = "AppIcon-news"
    case notes = "AppIcon-notes"
    case weather = "AppIcon-weather"
    case waves = "AppIcon-wave"

    init?(alternateIconName: String) {
        if let asset = AppIcon(rawValue: alternateIconName) {
            self = asset
        } else {
            owsFailDebug("Unknown alternative app icon name '\(alternateIconName)'")
            return nil
        }
    }

    var alternateIconName: String? {
        if case .default = self {
            nil
        } else {
            rawValue
        }
    }

    var previewImageResource: ImageResource {
        switch self {
        case .default: ImageResource.AppIconPreview.default
        case .chat: ImageResource.AppIconPreview.chat
        case .bubbles: ImageResource.AppIconPreview.bubbles
        case .yellow: ImageResource.AppIconPreview.yellow
        case .news: ImageResource.AppIconPreview.news
        case .notes: ImageResource.AppIconPreview.notes
        case .weather: ImageResource.AppIconPreview.weather
        case .waves: ImageResource.AppIconPreview.wave
        }
    }
}
