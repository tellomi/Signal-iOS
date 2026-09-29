//
// Copyright 2019 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

struct DefaultStickerPack {
    private let info: StickerPackInfo
    private let shouldAutoInstall: Bool

    private init(packIdHex: String, packKeyHex: String, shouldAutoInstall: Bool) {
        guard let info = StickerPackInfo.parse(packIdHex: packIdHex, packKeyHex: packKeyHex) else {
            owsFail("Invalid info")
        }

        self.info = info
        self.shouldAutoInstall = shouldAutoInstall
    }

    private static let allPacks: [DefaultStickerPack] = packs(isUsingProductionService: TSConstants.isUsingProductionService)

    /// Tellomi（tellomi/tellomi#1406，owner 2026-09-27「先下掉」；ADR-0064）：不内置任何 Signal 贴纸包，哪个环境都一样。
    /// 上游只在连 Signal 生产服务时内置 11 个包；这个 fork 的 `.production` 仍指 Signal 官方（见 `TSConstants`），
    /// 将来换成我们自己的生产环境时，按环境的那道闸会把 Signal 的包放回来，所以不再按环境判断。
    /// Tellomi 自有包等 M5。用户已经装过的包是用户自己的，不在这里删：清孤儿时照旧保留 `isInstalled` 的包。
    static func packs(isUsingProductionService: Bool) -> [DefaultStickerPack] {
        return []
    }

    private static let allPacksById: [Data: DefaultStickerPack] = {
        var result = [Data: DefaultStickerPack]()
        for pack in allPacks {
            result[pack.info.packId] = pack
        }
        return result
    }()

    // MARK: -

    static var packsToAutoInstall: [StickerPackInfo] {
        allPacks
            .filter { $0.shouldAutoInstall }
            .map { $0.info }
    }

    static var packsToNotAutoInstall: [StickerPackInfo] {
        allPacks
            .filter { !$0.shouldAutoInstall }
            .map { $0.info }
    }

    static func isDefaultStickerPack(packId: Data) -> Bool {
        allPacksById[packId] != nil
    }
}
