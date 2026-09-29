//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import XCTest
@testable import SignalServiceKit

/// Tellomi（tellomi/tellomi#1406，owner 2026-09-27「先下掉」）：不内置任何 Signal 贴纸包。
///
/// 上游只在连 Signal 生产服务时内置这 11 个包；这个 fork 的所有构建都连我们自己的服务端（`TSConstants` 里是 `.staging`），
/// 所以今天恰好一个都不装。但将来 `.production` 换成我们自己的生产环境时，那道按环境的闸会把它们放回来——
/// 这里按「连生产服务」的分支钉住：哪个环境都是空的。
final class TellomiDefaultStickersTest: XCTestCase {
    /// 上游 `DefaultStickers.swift` 里的 11 个 Signal 包（Rocky Talk、My Daily Life 1 / 2、Zozo、Croco、Cozy Season、
    /// Chug、Bandit、Swoon Hands、Swoon Faces、Day by Day）。
    private let signalPackIdsHex = [
        "42fb75e1827c0c945cfb5ca0975db03c",
        "ccc89a05dc077856b57351e90697976c",
        "fb535407d2f6497ec074df8b9c51dd1d",
        "3044281a51307306e5442f2e9070953a",
        "a2414255948558316f37c1d36c64cd28",
        "684d2b7bcfc2eec6f57f2e7be0078e0f",
        "f19548e5afa38d1ce4f5c3191eba5e30",
        "9acc9e8aba563d26a4994e69263e3b25",
        "e61fa0867031597467ccc036cc65d403",
        "cca32f5b905208b7d0f1e17f23fdc185",
        "cfc50156556893ef9838069d3890fe49",
    ]

    func testNoBuiltInPacksEvenWhenConnectedToProductionService() {
        XCTAssertEqual(DefaultStickerPack.packs(isUsingProductionService: true).count, 0)
        XCTAssertEqual(DefaultStickerPack.packs(isUsingProductionService: false).count, 0)
    }

    func testFirstLaunchDownloadsNoPacks() {
        XCTAssertTrue(DefaultStickerPack.packsToAutoInstall.isEmpty)
        XCTAssertTrue(DefaultStickerPack.packsToNotAutoInstall.isEmpty)
    }

    /// 不算内置 = 用户自己装过的照旧保留（清孤儿时只看 isInstalled），没装、只作参考的会被清掉；贴纸页也不再给它们标「官方」。
    func testNoSignalPackCountsAsDefault() throws {
        for hex in signalPackIdsHex {
            let packId = try XCTUnwrap(Data.data(fromHex: hex))
            XCTAssertFalse(StickerManager.isDefaultStickerPack(packId: packId), hex)
        }
    }
}
