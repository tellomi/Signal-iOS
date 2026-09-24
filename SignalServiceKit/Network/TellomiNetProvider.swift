//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
public import LibSignalClient

/// Tellomi（tellomi/tellomi#1056 第三刀）：本进程生效的区和 libsignal `Net`，放在同一个原子状态里。
///
/// `Net` 改不了主机名（libsignal 的 `ConnectionManager.env` 不可变），切区只能换一个新的 `Net`。
/// 所以用 `Net` 的对象都从这里**现取**，不再各存一份：换的时候只换这里，旧实例没有别的强引用，才放得掉。
/// 区和 `Net` 一起换，REST（`TSConstants`）和 libsignal 两侧在进程内同时切，不会「半切换」。
///
/// 这一刀只把持有方都改成经过这里，行为不变；`switchTo`、旧实例的延迟释放在后面的提交。
public final class TellomiNetProvider: Sendable {
    private struct State {
        let region: TellomiRegionProfile
        let net: Net
        let generation: Int
    }

    private let state: AtomicValue<State>

    /// 这个进程认识的区：默认是编进包里的表（`TellomiRegions.all`）。
    public let profiles: [TellomiRegionProfile]

    public init(region: TellomiRegionProfile, net: Net, profiles: [TellomiRegionProfile] = TellomiRegions.all) {
        self.state = AtomicValue(State(region: region, net: net, generation: 0), lock: .init())
        self.profiles = profiles
    }

    // MARK: - 本进程装上的那一个

    private static let installedProvider = AtomicValue<TellomiNetProvider?>(nil, lock: .init())

    /// 本进程装上的 provider（`AppSetup` 建好以后装上；主 App、NSE、分享扩展各一份）。还没装上时为 nil。
    public static var installed: TellomiNetProvider? { installedProvider.get() }

    /// 装成本进程的那一个：之后 `TellomiRegions.active()` 以它的区为准。
    public func install() {
        Self.installedProvider.set(self)
    }

#if TESTABLE_BUILD
    /// 测试用：换掉本进程装上的 provider，返回原来那个，用完装回去。
    @discardableResult
    static func installForTesting(_ provider: TellomiNetProvider?) -> TellomiNetProvider? {
        installedProvider.swap(provider)
    }
#endif

    /// 当前的 `Net`。用的时候取，别存下来。
    public var current: Net { state.get().net }

    /// 本进程生效的区。
    public var activeRegion: TellomiRegionProfile { state.get().region }

    /// 换过几次 `Net`（0 = 启动时建的那一个）。
    public var generation: Int { state.get().generation }

    /// 换成新的 `Net` 和区，返回换下来的 `Net`。旧实例什么时候放掉由调用方决定。
    @discardableResult
    func replace(net: Net, region: TellomiRegionProfile) -> Net {
        state.update { state in
            let old = state.net
            state = State(region: region, net: net, generation: state.generation + 1)
            return old
        }
    }
}
