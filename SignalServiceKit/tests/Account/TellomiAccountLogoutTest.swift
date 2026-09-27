//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import GRDB
import LibSignalClient
import XCTest

@testable import SignalServiceKit

/// ADR-0072 §4.1 / §4.3：主设备退出登录。
/// - 顺序：已链接设备（勾了才做）→ `DELETE /v1/accounts/apn` → 本机「已退出」标记；
/// - 任何一步失败（没网）都不写标记，交给界面提示「退出登录需要联网」；
/// - 标记在的时候注册状态报 `.deregistered`，本地身份、凭据原样留着。
final class TellomiAccountLogoutTest: XCTestCase {

    private var db: InMemoryDB!
    private var deviceStore: OWSDeviceStore!
    private var deviceService: RecordingDeviceService!
    private var networkManager: MockNetworkManager!
    private var registrationStateChangeManager: MockRegistrationStateChangeManager!
    private var isReachable = true
    private var forgotUploadedPushTokenCount = 0
    /// 按发生的先后记下每一步。
    private var events = [String]()

    override func setUp() {
        super.setUp()
        db = InMemoryDB()
        deviceStore = OWSDeviceStore()
        deviceService = RecordingDeviceService()
        networkManager = MockNetworkManager()
        registrationStateChangeManager = MockRegistrationStateChangeManager()
        isReachable = true
        forgotUploadedPushTokenCount = 0
        events = []
        deviceService.onEvent = { [unowned self] in self.events.append($0) }
    }

    private func makeLogout() -> TellomiAccountLogout {
        return TellomiAccountLogout(
            db: db,
            deviceService: deviceService,
            deviceStore: deviceStore,
            networkManager: networkManager,
            registrationStateChangeManager: registrationStateChangeManager,
            registrationSessionManager: RegistrationSessionManagerMock(),
            isReachable: { [unowned self] in self.isReachable },
            forgetUploadedPushToken: { [unowned self] in self.forgotUploadedPushTokenCount += 1 },
        )
    }

    private func storeDevices(_ deviceIds: [DeviceId]) {
        db.write { tx in
            _ = deviceStore.replaceAll(
                with: deviceIds.map { OWSDevice(deviceId: $0, createdAt: .distantPast, lastSeenAt: Date(), name: nil) },
                tx: tx,
            )
        }
    }

    private func respondToPushTokenDeletion(with result: Result<Int, Error>) {
        networkManager.asyncRequestHandlers.append({ [unowned self] request, _ in
            self.events.append("\(request.method) \(request.url.relativeString)")
            switch result {
            case .success(let statusCode):
                return HTTPResponse(requestUrl: request.url, status: statusCode, headers: HttpHeaders(), bodyData: nil)
            case .failure(let error):
                throw error
            }
        })
    }

    private var loggedOutValues: [Bool] { registrationStateChangeManager.tellomiLoggedOutValues }

    // MARK: - 退出登录（保留聊天记录）

    func testLogOutDeletesThePushTokenThenMarksThisDeviceLoggedOut() async throws {
        storeDevices([.primary, DeviceId(validating: 2)!])
        respondToPushTokenDeletion(with: .success(204))

        try await makeLogout().logOut(alsoUnlinkLinkedDevices: false)

        XCTAssertEqual(events, ["DELETE v1/accounts/apn"], "没勾「同时让已链接的设备退出」就不碰已链接设备")
        XCTAssertEqual(loggedOutValues, [true])
        XCTAssertEqual(forgotUploadedPushTokenCount, 1, "重新登录时要重新登记推送令牌")
    }

    func testLogOutAlsoUnlinksLinkedDevicesFirstWhenAsked() async throws {
        storeDevices([.primary, DeviceId(validating: 2)!, DeviceId(validating: 3)!])
        respondToPushTokenDeletion(with: .success(204))

        try await makeLogout().logOut(alsoUnlinkLinkedDevices: true)

        XCTAssertEqual(
            events,
            ["refreshDevices", "DELETE v1/devices/2", "DELETE v1/devices/3", "DELETE v1/accounts/apn"],
            "ADR-0072 §4.1：先让已链接设备退出，再注销推送令牌；主设备自己不删",
        )
        XCTAssertEqual(loggedOutValues, [true])
    }

    func testOfflineLogOutStaysLoggedIn() async {
        respondToPushTokenDeletion(with: .failure(OWSHTTPError.networkFailure(.genericFailure)))

        do {
            try await makeLogout().logOut(alsoUnlinkLinkedDevices: false)
            XCTFail("Expected an error")
        } catch .networkUnavailable {
            // 界面据此提示「退出登录需要联网，请稍后再试。」
        } catch {
            XCTFail("Unexpected error \(error)")
        }

        XCTAssertEqual(events, ["DELETE v1/accounts/apn"])
        XCTAssertEqual(loggedOutValues, [], "推送令牌没删掉就不退出（ADR-0072 §4.1 第 2 步）")
        XCTAssertEqual(forgotUploadedPushTokenCount, 1, "请求可能到了服务端：让下次同步重新登记令牌")
    }

    func testUnreachableLogOutSendsNothingAndStaysLoggedIn() async {
        isReachable = false

        do {
            try await makeLogout().logOut(alsoUnlinkLinkedDevices: true)
            XCTFail("Expected an error")
        } catch .networkUnavailable {
        } catch {
            XCTFail("Unexpected error \(error)")
        }

        XCTAssertEqual(events, [])
        XCTAssertEqual(loggedOutValues, [])
        XCTAssertEqual(forgotUploadedPushTokenCount, 0)
    }

    func testServerErrorStaysLoggedIn() async {
        respondToPushTokenDeletion(with: .failure(OWSHTTPError.serviceResponse(.init(
            requestUrl: URL(string: "v1/accounts/apn")!,
            responseStatus: 500,
            responseHeaders: HttpHeaders(),
            responseData: nil,
        ))))

        do {
            try await makeLogout().logOut(alsoUnlinkLinkedDevices: false)
            XCTFail("Expected an error")
        } catch .failed {
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        XCTAssertEqual(loggedOutValues, [])
    }

    func testFailingToUnlinkLinkedDevicesStaysLoggedInAndKeepsThePushToken() async {
        storeDevices([.primary, DeviceId(validating: 2)!])
        deviceService.unlinkError = OWSHTTPError.networkFailure(.genericFailure)

        do {
            try await makeLogout().logOut(alsoUnlinkLinkedDevices: true)
            XCTFail("Expected an error")
        } catch .networkUnavailable {
        } catch {
            XCTFail("Unexpected error \(error)")
        }

        XCTAssertEqual(events, ["refreshDevices", "DELETE v1/devices/2"], "推送令牌还没动")
        XCTAssertEqual(loggedOutValues, [])
        XCTAssertEqual(forgotUploadedPushTokenCount, 0)
    }

    func testPushTokenDeletionRequest() {
        let request = TellomiAccountLogout.deletePushTokenRequest()
        XCTAssertEqual(request.method, "DELETE")
        XCTAssertEqual(request.url.relativeString, "v1/accounts/apn")
    }

    // MARK: - 退出并删除本机数据（§4.3 第 1 步：尽量做，失败也不拦）

    func testBestEffortSignOffNeverThrows() async {
        storeDevices([.primary, DeviceId(validating: 2)!])
        deviceService.unlinkError = OWSHTTPError.networkFailure(.genericFailure)
        respondToPushTokenDeletion(with: .failure(OWSHTTPError.networkFailure(.genericFailure)))

        await makeLogout().signOffBestEffortBeforeDeletingLocalData(alsoUnlinkLinkedDevices: true)

        XCTAssertEqual(events, ["refreshDevices", "DELETE v1/devices/2", "DELETE v1/accounts/apn"])
        XCTAssertEqual(loggedOutValues, [], "删除本机数据不写「已退出」标记，数据马上就清空了")
    }

    func testBestEffortSignOffSkipsTheNetworkWhenOffline() async {
        isReachable = false
        await makeLogout().signOffBestEffortBeforeDeletingLocalData(alsoUnlinkLinkedDevices: true)
        XCTAssertEqual(events, [])
    }

    // MARK: - 本机标记 → 注册状态

    func testLoggedOutFlagMakesThePrimaryDeviceDeregisteredButKeepsItsIdentity() {
        let tsAccountManager = TSAccountManagerImpl(
            appReadiness: AppReadinessMock(),
            dateProvider: { Date() },
            databaseChangeObserver: UnusedDatabaseChangeObserver(),
            db: db,
        )
        let localIdentifiers = LocalIdentifiers.forUnitTests
        db.write { tx in
            tsAccountManager.initializeLocalIdentifiers(
                aci: localIdentifiers.aci,
                phoneNumber: (E164(localIdentifiers.phoneNumber)!, localIdentifiers.pni!),
                deviceId: .primary,
                serverAuthToken: "authToken",
                tx: tx,
            )
        }
        XCTAssertTrue(tsAccountManager.registrationStateWithMaybeSneakyTransaction.isRegisteredPrimaryDevice)
        XCTAssertFalse(tsAccountManager.isTellomiLoggedOutWithMaybeSneakyTransaction)

        XCTAssertTrue(db.write { tsAccountManager.setIsTellomiLoggedOut(true, tx: $0) })
        XCTAssertFalse(db.write { tsAccountManager.setIsTellomiLoggedOut(true, tx: $0) }, "值没变就返回 false")

        let loggedOutState = tsAccountManager.registrationStateWithMaybeSneakyTransaction
        guard case .deregistered(let deregisteredIdentifiers) = loggedOutState else {
            return XCTFail("Expected deregistered, got \(loggedOutState.logString)")
        }
        XCTAssertFalse(loggedOutState.isRegistered, "WebSocket、后台任务、通知扩展、分享扩展都看这个")
        XCTAssertEqual(deregisteredIdentifiers.phoneNumber, localIdentifiers.phoneNumber)
        XCTAssertTrue(tsAccountManager.isTellomiLoggedOutWithMaybeSneakyTransaction)
        // 本地身份、凭据原样保留（ADR-0072 §4.1 第 3 步）。
        XCTAssertEqual(tsAccountManager.localIdentifiersWithMaybeSneakyTransaction?.aci, localIdentifiers.aci)
        XCTAssertEqual(tsAccountManager.storedServerAuthTokenWithMaybeTransaction, "authToken")

        XCTAssertTrue(db.write { tsAccountManager.setIsTellomiLoggedOut(false, tx: $0) })
        XCTAssertTrue(tsAccountManager.registrationStateWithMaybeSneakyTransaction.isRegisteredPrimaryDevice)
        XCTAssertFalse(tsAccountManager.isTellomiLoggedOutWithMaybeSneakyTransaction)

        // 真正注册一次（比如换号码后清空重注册）也会去掉标记。
        db.write { _ = tsAccountManager.setIsTellomiLoggedOut(true, tx: $0) }
        db.write { tx in
            tsAccountManager.initializeLocalIdentifiers(
                aci: localIdentifiers.aci,
                phoneNumber: (E164(localIdentifiers.phoneNumber)!, localIdentifiers.pni!),
                deviceId: .primary,
                serverAuthToken: "authToken2",
                tx: tx,
            )
        }
        XCTAssertFalse(tsAccountManager.isTellomiLoggedOutWithMaybeSneakyTransaction)
    }

    // MARK: - 打码的手机号

    func testMaskedPhoneNumber() {
        XCTAssertEqual(TellomiMaskedPhoneNumber.format(callingCode: "86", nationalNumber: "13812345678"), "+86 138****5678")
        XCTAssertEqual(TellomiMaskedPhoneNumber.format(callingCode: "+1", nationalNumber: "2025550123"), "+1 202****0123")
        XCTAssertEqual(TellomiMaskedPhoneNumber.format(callingCode: "852", nationalNumber: "61234567"), "+852 612****4567")
        XCTAssertEqual(TellomiMaskedPhoneNumber.format(callingCode: "354", nationalNumber: "6111234"), "+354 ****1234")
        XCTAssertEqual(TellomiMaskedPhoneNumber.format(callingCode: "1", nationalNumber: "1234"), "+1 ****")
    }
}

// MARK: - Mocks

private final class RecordingDeviceService: OWSDeviceService {
    var onEvent: (String) -> Void = { _ in }
    var unlinkError: Error?

    func refreshDevices() async throws -> Bool {
        onEvent("refreshDevices")
        return false
    }

    func unlinkDevice(deviceId: DeviceId) async throws {
        onEvent("DELETE v1/devices/\(deviceId)")
        if let unlinkError {
            throw unlinkError
        }
    }

    func renameDevice(device: OWSDevice, newName: String) async throws {}
}

private final class UnusedDatabaseChangeObserver: DatabaseChangeObserver {
    func beginObserving(pool: DatabasePool) throws {}
    func stopObserving(pool: DatabasePool) throws {}
    func disable<T>(tx: DBWriteTransaction, during: (DBWriteTransaction) throws -> T) rethrows -> T { try during(tx) }
    func appendDatabaseChangeDelegate(_ databaseChangeDelegate: DatabaseChangeDelegate) {}
    func appendDatabaseWriteDelegate(_ delegate: DatabaseWriteDelegate) {}
}
