//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest
@testable import SignalServiceKit

/// ADR-0063 §4.8：tell.cc 的保留路径常量与匹配顺序（tellomi/tellomi#1423）。
final class TellomiLinksFirstPartyTest: XCTestCase {

    /// 与超级仓库 `docs/adr/0063/registry/providers/first-party/tellomi.toml` 的 `reserved_paths`、
    /// Android `TellomiLinks.kt` 的 `RESERVED_FIRST_LEVEL_PATHS` 同一张表、同一个顺序。
    func testReservedFirstLevelPathsMatchTheRegistry() {
        XCTAssertEqual(TellomiLinks.reservedFirstLevelPaths, ["u", "g", "s", "call", "i", "m", "e", "a", "app", "b"])
        let pathConstants = [
            TellomiLinks.Path.contact, TellomiLinks.Path.group, TellomiLinks.Path.sticker, TellomiLinks.Path.call,
            TellomiLinks.Path.inviteReserved, TellomiLinks.Path.messageReserved, TellomiLinks.Path.eventReserved,
            TellomiLinks.Path.reservedA, TellomiLinks.Path.appReserved, TellomiLinks.Path.reservedB,
        ]
        XCTAssertEqual(pathConstants, TellomiLinks.reservedFirstLevelPaths.map { "/" + $0 })
    }

    func testFirstPartyShapes() {
        let cases: [(String, TellomiLinks.FirstPartyShape?)] = [
            // 一级路径优先
            ("https://tell.cc/u#u/kaixin", .user(username: "kaixin.01")),
            ("https://tell.cc/u#u/ceshi.57", .user(username: "ceshi.57")),
            ("https://tell.cc/u#eu/AbCdEfGhIjKlMnOpQrStUv", .userEncryptedLink),
            ("https://tell.cc/u#p/+8613800000004", .userPhoneNumber),
            ("https://tell.cc/u", .notAnObject),
            ("https://tell.cc/g#CjQKIGV4YW1wbGVtYXN0ZXJrZXk", .group),
            ("https://tell.cc/g", .notAnObject),
            ("https://tell.cc/call#key=bcdf-ghkm", .call),
            ("https://tell.cc/s#pack_id=00&pack_key=11", .stickerPack),
            ("https://tell.cc/i", .reservedPath("i")),
            ("https://tell.cc/app", .reservedPath("app")),
            ("https://tell.cc/APP", .reservedPath("app")),
            ("https://tell.cc/m", .reservedPath("m")),
            ("https://tell.cc/b/", .reservedPath("b")),
            // 其余单段路径按用户名：不带点 = `.01`（ADR-0066）
            ("https://tell.cc/kaixin", .user(username: "kaixin.01")),
            ("https://tell.cc/kaixin/", .user(username: "kaixin.01")),
            ("https://tell.cc/kaixin?from=wechat", .user(username: "kaixin.01")),
            ("https://tell.cc/kaixin.57", .user(username: "kaixin.57")),
            ("tellomi://tell.cc/kaixin", .user(username: "kaixin.01")),
            // 都不是：不是 Tellomi 对象
            ("https://tell.cc/", .notAnObject),
            ("https://tell.cc", .notAnObject),
            ("https://tell.cc/.well-known/apple-app-site-association", .notAnObject),
            ("https://tell.cc/.well-known", .notAnObject),
            ("https://tell.cc/ab", .notAnObject),
            ("https://tell.cc/1abc", .notAnObject),
            ("https://tell.cc/kaixin/extra", .notAnObject),
            ("https://tell.cc/%E8%B4%A6%E5%8F%B7", .notAnObject),
            // 不是 tell.cc
            ("https://tellomi.app/security", nil),
            ("https://evil.example/tell.cc/kaixin", nil),
            ("https://tell.cc.evil.cn/kaixin", nil),
            ("http://tell.cc/kaixin", nil),
        ]
        for (rawUrl, expected) in cases {
            let url = URL(string: rawUrl)!
            XCTAssertEqual(TellomiLinks.firstPartyShape(of: url), expected, rawUrl)
        }
    }

    /// `plainUsername` 的行为不因为常量公开而变（UrlOpenerTest 里有完整用例，这里只核保留路径那一半）。
    func testReservedPathsAreNeverUsernames() {
        for path in TellomiLinks.reservedFirstLevelPaths {
            XCTAssertNil(TellomiLinks.plainUsername(in: URL(string: "https://tell.cc/\(path)")!), path)
            XCTAssertNil(TellomiLinks.plainUsername(in: URL(string: "https://tell.cc/\(path.uppercased())")!), path)
        }
    }
}
