//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

public import LibSignalClient
public import SignalServiceKit

public enum RegistrationMode: CustomDebugStringConvertible {
    case registering
    case reRegistering(ReregistrationParams)
    case changingNumber(ChangeNumberParams)

    public struct ReregistrationParams: Codable, Equatable {
        public let aci: Aci?
        public let e164: E164
        /// Tellomi（ADR-0072 §4.2）：这是「退出登录后重新登录」，不是重新注册。
        /// 同一个号码拿到 `verified=true` 的验证会话（开了注册锁的再在本机核对 PIN）就解锁本机，
        /// **绝不调** `POST /v1/registration`——服务端的 `reclaimAccount` 会清掉退出期间排队的消息。
        /// 也不走注册恢复密码 / SVR 那几条路（它们的终点同样是 `POST /v1/registration`）。
        public let isTellomiReLogin: Bool

        enum CodingKeys: String, CodingKey {
            case aci
            case e164
            case isTellomiReLogin
        }

        init(aci: Aci?, e164: E164, isTellomiReLogin: Bool = false) {
            self.aci = aci
            self.e164 = e164
            self.isTellomiReLogin = isTellomiReLogin
        }

        /// Tellomi（ADR-0072）：本机已退出登录的账号重新登录。
        public static func tellomiReLogin(aci: Aci?, e164: E164) -> ReregistrationParams {
            return ReregistrationParams(aci: aci, e164: e164, isTellomiReLogin: true)
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.aci = try container.decodeIfPresent(UUID.self, forKey: .aci).map({ Aci(fromUUID: $0) })
            self.e164 = try container.decode(E164.self, forKey: .e164)
            self.isTellomiReLogin = try container.decodeIfPresent(Bool.self, forKey: .isTellomiReLogin) ?? false
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(self.aci?.rawUUID, forKey: .aci)
            try container.encode(self.e164, forKey: .e164)
            if isTellomiReLogin {
                try container.encode(true, forKey: .isTellomiReLogin)
            }
        }
    }

    public struct ChangeNumberParams: Codable, Equatable {
        public let oldE164: E164
        public let oldAuthToken: String
        @AciUuid public var localAci: Aci
        public let localDeviceId: DeviceId
    }

    public var debugDescription: String {
        switch self {
        case .registering:
            return "registering"
        case .reRegistering(let params):
            return params.isTellomiReLogin ? "tellomiReLogin" : "reRegistering"
        case .changingNumber:
            return "changingNumber"
        }
    }
}
