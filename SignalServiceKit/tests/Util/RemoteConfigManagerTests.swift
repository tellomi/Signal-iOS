//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import LibSignalClient
import Testing

@testable import SignalServiceKit

struct RemoteConfigTests {
    @Test(arguments: [
        ("research.megaphone.1", "15b9729c-51ea-4ddb-b516-652befe78062", 1_000_000, 243_315),
        ("research.megaphone.2", "15b9729c-51ea-4ddb-b516-652befe78062", 1_000_000, 551_742),
        ("research.megaphone.1", "5f5b28bb-f485-4a0a-a85c-13fc047524b1", 1_000_000, 365_381),
        ("research.megaphone.1", "15b9729c-51ea-4ddb-b516-652befe78062", 100_000, 43_315),
    ])
    func bucketCalculation(testCase: (key: String, uuidString: String, bucketSize: UInt64, expectedBucket: UInt64)) {
        let actualBucket = RemoteConfig.bucket(key: testCase.key, aci: Aci.constantForTesting(testCase.uuidString), bucketSize: testCase.bucketSize)
        #expect(actualBucket == testCase.expectedBucket)
    }

    @Test(arguments: [
        ("1", true),
        ("true", true),
        ("TRUE", true),
        ("false", false),
        ("", false),
        ("11", false),
    ])
    func isEnabledFlag(testCase: (rawValue: String, isEnabled: Bool)) {
        let remoteConfig = RemoteConfig(clockSkew: 0, valueFlags: ["global.gifSearch": testCase.rawValue])
        #expect(remoteConfig.enableGifSearch == testCase.isEnabled)
    }

    @Test
    func testHotSwapping() {
        let remoteConfig = RemoteConfig(clockSkew: 0, valueFlags: [
            "test.hotSwappable.enabled": "false",
            "test.nonSwappable.enabled": "false",
            "test.hotSwappable.value": "abc",
            "test.nonSwappable.value": "abc",
        ])
        #expect(remoteConfig.testHotSwappable == false)
        #expect(remoteConfig.testNonSwappable == false)
        #expect(remoteConfig.testHotSwappableValue == "abc")
        #expect(remoteConfig.testNonSwappableValue == "abc")
        #expect(remoteConfig.lastKnownClockSkew == 0)

        let unchangedConfig = remoteConfig.merging(
            newValueFlags: nil,
            newClockSkew: 1,
        )
        #expect(unchangedConfig.testHotSwappable == false)
        #expect(unchangedConfig.testNonSwappable == false)
        #expect(unchangedConfig.testHotSwappableValue == "abc")
        #expect(unchangedConfig.testNonSwappableValue == "abc")
        #expect(unchangedConfig.lastKnownClockSkew == 1)

        let mergedEmptyConfig = remoteConfig.merging(
            newValueFlags: [:],
            newClockSkew: 2,
        )
        #expect(mergedEmptyConfig.testHotSwappable == nil)
        #expect(mergedEmptyConfig.testNonSwappable == false)
        #expect(mergedEmptyConfig.testHotSwappableValue == nil)
        #expect(mergedEmptyConfig.testNonSwappableValue == "abc")
        #expect(mergedEmptyConfig.lastKnownClockSkew == 2)

        let mergedConfig = remoteConfig.merging(
            newValueFlags: [
                "test.hotSwappable.enabled": "true",
                "test.nonSwappable.enabled": "true",
                "test.hotSwappable.value": "123",
                "test.nonSwappable.value": "123",
            ],
            newClockSkew: 3,
        )
        #expect(mergedConfig.testHotSwappable == true)
        #expect(mergedConfig.testNonSwappable == false)
        #expect(mergedConfig.testHotSwappableValue == "123")
        #expect(mergedConfig.testNonSwappableValue == "abc")
        #expect(mergedConfig.lastKnownClockSkew == 3)
    }

    @Test
    func testNetConfig() {
        let remoteConfig = RemoteConfig(clockSkew: 0, valueFlags: [
            "ios.libsignal.config1": "true",
            "ios.libsignal.config2": "false",
            "global.libsignal.config3": "value",
            "global.libsignal.config4": "4",
            "ios.libsignal.config4": "four",
        ])
        let netConfig = remoteConfig.netConfig()
        #expect(netConfig == [
            "config1": "true",
            "config4": "four",
        ])
    }
}

struct RemoteConfigStoreTests {
    let db = InMemoryDB()
    let keyValueStore = KeyValueStore(collection: "")
    let store: RemoteConfigStore

    init() {
        self.store = RemoteConfigStore(keyValueStore: self.keyValueStore)
    }

    @Test
    func migrationFallback() {
        self.db.write { tx in
            let isEnabledFlags: [String: Bool] = [
                "ios.abc": true,
                "ios.123": false,
            ]
            self.keyValueStore.setObject(isEnabledFlags as [NSString: NSNumber] as NSDictionary, key: "remoteConfigKey", transaction: tx)
        }
        let valueFlags = self.db.read { tx in
            return self.store.loadValueFlags(tx: tx)
        }
        #expect(valueFlags == ["ios.abc": "true", "ios.123": "false"])
    }

    @Test
    func migrationMerge() {
        self.db.write { tx in
            let valueFlags: [String: String] = [
                "ios.abc": "def",
                "ios.def": "ghi",
            ]
            let isEnabledFlags: [String: Bool] = [
                "ios.ghi": true,
                "ios.jkl": false,
            ]
            let timeGatedFlags: [String: Date] = [
                "ios.mno": Date(timeIntervalSince1970: 0),
                "ios.pqr": Date(timeIntervalSince1970: 1),
            ]
            self.keyValueStore.setObject(isEnabledFlags as [NSString: NSNumber] as NSDictionary, key: "remoteConfigKey", transaction: tx)
            self.keyValueStore.setObject(valueFlags as [NSString: NSString] as NSDictionary, key: "remoteConfigValueFlags", transaction: tx)
            self.keyValueStore.setObject(timeGatedFlags as [NSString: NSDate] as NSDictionary, key: "remoteConfigTimeGatedFlags", transaction: tx)
        }
        let valueFlags = self.db.read { tx in
            return self.store.loadValueFlags(tx: tx)
        }
        #expect(valueFlags == [
            "ios.abc": "def",
            "ios.def": "ghi",
            "ios.ghi": "true",
            "ios.jkl": "false",
            "ios.mno": "0.0",
            "ios.pqr": "1.0",
        ])
    }

    @Test
    func nilResult() {
        let valueFlags = self.db.read { tx in
            return self.store.loadValueFlags(tx: tx)
        }
        #expect(valueFlags == nil)
    }
}

// MARK: - Tellomi

/// Tellomi（#1078）：`global.gif.provider` 与上游 `global.gifSearch` 合成一个结论。
///
/// 这条不只是「功能开关」——大陆发行的包靠 `provider = none` 把 GIF 整条关掉，关掉之后
/// 包里才不会再有指向 `contentproxy.tellomi.app`（境外、**未备案**域）的连接。
/// 判错一次就是 ADR-0065 欠账 1 说的「漏一条就是漏报」，不是少一个表情面板。
///
/// 测的是纯函数 `RemoteConfig.isGifAvailable(enableGifSearch:provider:)`：
/// 为了测「两个值怎么合成一个结论」去构造一整个 `RemoteConfig` 不值当，
/// 而那一步正是会判错的地方。三端同口径（Desktop #1065、Android Signal-Android#9）。
struct TellomiGifRemoteConfigTests {
    @Test
    func noProviderDeliveredFallsBackToAvailable() {
        #expect(RemoteConfig.isGifAvailable(enableGifSearch: true, provider: nil))
    }

    @Test
    func providerGiphyKeepsGifAvailable() {
        #expect(RemoteConfig.isGifAvailable(enableGifSearch: true, provider: "giphy"))
    }

    @Test
    func providerNoneDisablesGif() {
        #expect(!RemoteConfig.isGifAvailable(enableGifSearch: true, provider: "none"))
    }

    /// 服务端那份 YAML 是人写的，别让一个大写把大陆包的 GIF 又打开。
    @Test(arguments: ["NONE", "None", "nOnE"])
    func providerNoneIsCaseInsensitive(value: String) {
        #expect(!RemoteConfig.isGifAvailable(enableGifSearch: true, provider: value))
    }

    /// 两个条件是**与**：上游整体关掉时，我们下发 provider=giphy 也不该把它打开。
    @Test
    func upstreamSwitchOffDisablesGifEvenWhenProviderSaysGiphy() {
        #expect(!RemoteConfig.isGifAvailable(enableGifSearch: false, provider: "giphy"))
    }

    /// 反向对照，也是大陆包实际走的那条：上游开着、我们说 none，结果必须是关。
    @Test
    func providerNoneWinsOverUpstreamSwitchOn() {
        #expect(!RemoteConfig.isGifAvailable(enableGifSearch: true, provider: "none"))
    }

    /// 以后接了别的源时，老客户端不认识它——该按「有源」处理，而不是悄悄关掉。
    /// 只有明确的 none 才是关。
    @Test
    func unknownProviderIsTreatedAsAvailable() {
        #expect(RemoteConfig.isGifAvailable(enableGifSearch: true, provider: "sogou"))
    }

    /// 服务端把值写成空串是配置错误，不该被当成「关掉」——那会变成一次查不出根因的
    /// 「GIF 标签不见了」。空串按「没下发」处理。
    @Test
    func emptyStringIsNotNone() {
        #expect(RemoteConfig.isGifAvailable(enableGifSearch: true, provider: ""))
    }
}
