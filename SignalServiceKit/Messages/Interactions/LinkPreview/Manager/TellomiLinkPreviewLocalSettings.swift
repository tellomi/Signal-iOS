//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// 链接预览里**只存本机**的设置（ADR-0063 §8.1 第 9 行、§九.4；owner 2026-09-27）。
///
/// 放在独立的集合里，不在 `SSKPreferences.store`：不进 storage service、不发配置同步消息，主设备和关联设备各管各的
/// （要跨设备同步得给 storage service 的记录加字段，P1 不做）。
public enum TellomiLinkPreviewLocalSettings {
    private static let store = KeyValueStore(collection: "TellomiLinkPreviewLocalSettings")
    private static let expandShortLinksKey = "expandShortLinks"

    /// 「展开短链接」：默认开。只对注册表声明的短链域名生效（§4.4）；关掉以后发送端不去问短链服务，短链按它自己的域名出卡。
    public static func isShortLinkExpansionEnabled(tx: DBReadTransaction) -> Bool {
        return store.getBool(expandShortLinksKey, defaultValue: true, transaction: tx)
    }

    public static func setShortLinkExpansionEnabled(_ isEnabled: Bool, tx: DBWriteTransaction) {
        store.setBool(isEnabled, key: expandShortLinksKey, transaction: tx)
    }
}
