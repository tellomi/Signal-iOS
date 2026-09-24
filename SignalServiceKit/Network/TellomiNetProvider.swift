//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
public import LibSignalClient

public extension Notification.Name {
    /// Tellomi（#1056 第三刀）：本进程换了区，`Net` 已经换成新区的。聊天连接收到后 `cycleSocket()`，按新的 `Net` 重连。
    static let tellomiRegionDidChange = Notification.Name("tellomiRegionDidChange")
}

public enum TellomiRegionSwitchError: Error, Equatable {
    /// 不分区的环境（USE_PRODUCTION = 上游服务器），或还没接好重建（`AppSetup` 之前、测试）。
    case notApplicable
    /// 这个进程不认识的区。
    case unknown
    /// 那个区关着（契约第六节：disabled 的区直接报错）。这一步在建 `Net` 之前，不碰网络。
    case disabled
}

/// Tellomi（tellomi/tellomi#1056 第三刀）：本进程生效的区和 libsignal `Net`，放在同一个原子状态里。
///
/// `Net` 改不了主机名（libsignal 的 `ConnectionManager.env` 不可变），切区只能换一个新的 `Net`。
/// 所以用 `Net` 的对象都从这里**现取**，不再各存一份：换的时候只换这里，旧实例没有别的强引用，才放得掉。
/// 区和 `Net` 一起换，REST（`TSConstants`）和 libsignal 两侧在进程内同时切，不会「半切换」。
public final class TellomiNetProvider: Sendable {
    private struct State {
        let region: TellomiRegionProfile
        let net: Net
        let generation: Int
    }

    /// 切区时怎么建、怎么配一个新的 `Net`（`AppSetup` 在依赖都建好以后接上）。
    public struct Rebuild {
        let makeNet: (TellomiRegionProfile) -> Net
        let configure: (Net) -> Void

        public init(makeNet: @escaping (TellomiRegionProfile) -> Net, configure: @escaping (Net) -> Void) {
            self.makeNet = makeNet
            self.configure = configure
        }
    }

    private struct RetiredNet {
        let net: Net
        let generation: Int
    }

    private let state: AtomicValue<State>
    private let rebuild = AtomicValue<Rebuild?>(nil, lock: .init())
    private let switchLock = UnfairLock()
    private let retired = AtomicValue<[RetiredNet]>([], lock: .init())
    private let retireDelay: TimeInterval

    /// 旧 `Net` 在这条队列上放掉：不在 libsignal 自己的 tokio 线程上（在那上面 drop 运行时会 panic），也不卡主线程。
    private static let retireQueue = DispatchQueue(label: "org.tellomi.retired-net", qos: .utility)

    /// 这个进程认识的区：默认是编进包里的表（`TellomiRegions.all`）。
    public let profiles: [TellomiRegionProfile]

    /// - Parameter retireDelay: 换下来的旧 `Net` 留多久再放。要长过 provisioning 的 90 s、请求超时和 keepalive 的 30 s，
    ///   这期间旧连接的回调可能还在用它；上游从来不放 `Net`，放它是 Tellomi 才有的路径。
    public init(
        region: TellomiRegionProfile,
        net: Net,
        profiles: [TellomiRegionProfile] = TellomiRegions.all,
        retireDelay: TimeInterval = 3 * .minute,
    ) {
        self.state = AtomicValue(State(region: region, net: net, generation: 0), lock: .init())
        self.profiles = profiles
        self.retireDelay = retireDelay
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

    /// 换下来、还没放掉的旧 `Net` 有几个（调试入口显示，#1056 判据 2）。
    public var retiredCount: Int { retired.get().count }

    /// 换成新的 `Net` 和区，返回换下来的 `Net`。旧实例什么时候放掉由调用方决定。
    @discardableResult
    func replace(net: Net, region: TellomiRegionProfile) -> Net {
        state.update { state in
            let old = state.net
            state = State(region: region, net: net, generation: state.generation + 1)
            return old
        }
    }

    // MARK: - 切区（契约第六节 switchTo）

    /// 接上切区时建、配新 `Net` 的两步。USE_PRODUCTION（上游服务器）不分区，不接，`switchTo` 报 `.notApplicable`。
    public func setRebuild(_ rebuild: Rebuild) {
        self.rebuild.set(rebuild)
    }

    /// 切到另一个区：建新 `Net` → 配好代理和审查规避开关 → 记进 app group（主 App 才记）→ 原子换上 → 通知聊天连接重连。
    ///
    /// 不认识的区、关着的区直接报错，**在建 `Net` 之前**，不查 DNS、不建连接（判据 4 在切换器这一层）。
    /// 跟生效区相同就什么都不做，返回 false。旧 `Net` 进退役区，`retireDelay` 之后在专用队列上放掉。
    /// 驻留时间、失败阈值这些策略归选路器（第四刀），不在这里。
    @discardableResult
    public func switchTo(_ id: TellomiRegionId, store: TellomiRegionStore? = .appGroup, now: Date = Date()) throws -> Bool {
        guard let rebuild = rebuild.get() else {
            throw TellomiRegionSwitchError.notApplicable
        }
        guard let target = profiles.first(where: { $0.id == id }) else {
            throw TellomiRegionSwitchError.unknown
        }
        guard target.enabled else {
            throw TellomiRegionSwitchError.disabled
        }

        let swapped: (old: Net, oldGeneration: Int)? = switchLock.withLock {
            guard activeRegion.id != id else {
                return nil
            }
            let newNet = rebuild.makeNet(target)
            // 先配好再换上：换上的那一刻就可能有新连接，没配代理就会直连（用户开着应用内代理时是泄漏）
            rebuild.configure(newNet)
            store?.record(id, at: now)
            let oldGeneration = generation
            return (replace(net: newNet, region: target), oldGeneration)
        }
        guard let swapped else {
            return false
        }

        Logger.info("[Tellomi region] switched to \(id.rawValue) (net generation \(swapped.oldGeneration) → \(generation))")
        retire(swapped.old, generation: swapped.oldGeneration)
        NotificationCenter.default.postOnMainThread(name: .tellomiRegionDidChange, object: nil)
        // 幂等再配一次：补上「配完到换上之间代理设置刚好变了」的竞态
        rebuild.configure(current)
        return true
    }

    /// NSE 每条通知 re-warm 时调：主 App 在 app group 里记了别的区，就跟着换（不写 store，只有主 App 决定区）。
    @discardableResult
    public func adoptStoredRegionIfChanged(store: TellomiRegionStore = .appGroup) -> Bool {
        let stored = TellomiRegions.resolve(storedId: store.storedRegionId(), profiles: profiles)
        guard stored.id != activeRegion.id else {
            return false
        }
        do {
            return try switchTo(stored.id, store: nil)
        } catch {
            Logger.warn("[Tellomi region] can't adopt stored region \(stored.id.rawValue): \(error)")
            return false
        }
    }

    private func retire(_ old: Net, generation: Int) {
        retired.update { $0.append(RetiredNet(net: old, generation: generation)) }
        Self.retireQueue.asyncAfter(deadline: .now() + retireDelay) { [weak self] in
            var released: Net?
            self?.retired.update { list in
                if let index = list.firstIndex(where: { $0.generation == generation }) {
                    released = list.remove(at: index).net
                }
            }
            weak let probe = released
            // 最后一个强引用在这里放掉（专用后台队列）
            released = nil
            if probe == nil {
                Logger.info("[Tellomi region] retired net generation \(generation) released")
            } else {
                // 还有别处持有：门禁没挡住的持有方，或还没断开的旧连接（#1056 判据 2 要追的就是这个）
                owsFailDebug("[Tellomi region] retired net generation \(generation) is still referenced")
            }
        }
    }
}
