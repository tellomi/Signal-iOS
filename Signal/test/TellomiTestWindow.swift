//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

extension UIWindow {
    /// 测试里用的窗口：挂到测试宿主的场景上。
    ///
    /// 应用改用 UIScene 之后（Signal-iOS#207），没挂在场景上的窗口（`UIWindow(frame:)`）不上屏：截图是白的，
    /// 在它上面 present 不出来，键盘也不弹。拿不到场景时（不该发生）退回老写法。
    @MainActor
    static func tellomiTestWindow(frame: CGRect) -> UIWindow {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            return UIWindow(frame: frame)
        }
        let window = UIWindow(windowScene: scene)
        window.frame = frame
        return window
    }
}
