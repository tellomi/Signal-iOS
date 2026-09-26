//
// Copyright 2022 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import XCTest

@testable import SignalServiceKit

final class ContactDiscoveryManagerTest: XCTestCase {
    private class MockContactDiscoveryTaskQueue: ContactDiscoveryTaskQueue {
        var onPerform: ((Set<String>, ContactDiscoveryMode) async throws -> [SignalRecipient])?

        func perform(for phoneNumbers: Set<String>, mode: ContactDiscoveryMode) async throws -> [SignalRecipient] {
            return try await onPerform!(phoneNumbers, mode)
        }

        static func foundResponse(for phoneNumbers: Set<String>) -> [SignalRecipient] {
            let db = InMemoryDB()
            return db.write { tx in
                return phoneNumbers.map {
                    return try! SignalRecipient.insertRecord(
                        aci: Aci.randomForTesting(),
                        phoneNumber: E164($0)!,
                        pni: Pni.randomForTesting(),
                        deviceIds: [DeviceId(validating: 1)!],
                        tx: tx,
                    )
                }
            }
        }
    }

    private lazy var taskQueue = MockContactDiscoveryTaskQueue()
    /// Tellomi：缺省是上游档（`TSConstantsMock` 取 `TSConstantsProduction` 的值，有 CDSI），上游用例测的就是这一档；
    /// 进程里全局的 `TSConstants.shared` 在 Tellomi 是没有 CDSI 的那档，拿它跑 testQueueing 会一直挂着。
    private lazy var tsConstants = TSConstantsMock()
    private lazy var manager = ContactDiscoveryManagerImpl(contactDiscoveryTaskQueue: taskQueue, tsConstants: tsConstants)

    func testQueueing() async throws {
        // Start the first stateful request, but don't resolve it yet.
        let initialRequest = CancellableContinuation<CheckedContinuation<[SignalRecipient], any Error>>()
        taskQueue.onPerform = { phoneNumbers, mode in
            return try await withCheckedThrowingContinuation { continuation in
                initialRequest.resume(with: .success(continuation))
            }
        }
        async let _ = manager.lookUp(phoneNumbers: ["+16505550100"], mode: .contactIntersection)
        let initialContinuation = try await initialRequest.wait()

        // Schedule the next stateful request, which will be queued.
        taskQueue.onPerform = { phoneNumbers, mode in
            return MockContactDiscoveryTaskQueue.foundResponse(for: phoneNumbers)
        }
        async let queuedResult = manager.lookUp(phoneNumbers: ["+16505550101"], mode: .contactIntersection)

        // Finish the initial request, which should unblock the queued request.
        initialContinuation.resume(returning: [])

        let queuedResults = try await queuedResult.map { $0.phoneNumber!.stringValue }
        XCTAssertEqual(queuedResults, ["+16505550101"])
    }

    func testRateLimit() async throws {
        let retryDate1 = Date(timeIntervalSinceNow: 30)
        let retryDate2 = Date(timeIntervalSinceNow: 60)

        // Step 1: Contact intersection fails with a rate limit error.
        taskQueue.onPerform = { phoneNumbers, mode in
            throw ContactDiscoveryError.rateLimit(retryAfter: retryDate1)
        }
        let result1 = try await lookUpAndReturnRateLimitDate(phoneNumbers: ["+16505550100"], mode: .contactIntersection)
        XCTAssertEqual(result1, retryDate1)

        // Step 2: One-off requests should still be possible, despite the earlier error.
        taskQueue.onPerform = { phoneNumbers, mode in
            throw ContactDiscoveryError.rateLimit(retryAfter: retryDate2)
        }
        let result2 = try await lookUpAndReturnRateLimitDate(phoneNumbers: ["+16505550100"], mode: .oneOffUserRequest)
        XCTAssertEqual(result2, retryDate2)

        // Step 3: Contact intersection should now be stuck behind the one-off retry date.
        taskQueue.onPerform = nil
        let result3 = try await lookUpAndReturnRateLimitDate(phoneNumbers: ["+16505550100"], mode: .contactIntersection)
        XCTAssertEqual(result3, retryDate2)
    }

    func testUndiscoverableCache() async throws {
        let phoneNumber1 = "+16505550101"
        let phoneNumber2 = "+16505550102"
        let phoneNumber3 = "+16505550103"
        let phoneNumber4 = "+16505550104"

        // Populate the cache with empty phone numbers.
        taskQueue.onPerform = { phoneNumbers, mode in
            if phoneNumbers == [phoneNumber1, phoneNumber2, phoneNumber3] {
                return []
            }
            throw OWSGenericError("Invalid request.")
        }
        let result1 = try await lookUpAndReturnResult(phoneNumbers: [phoneNumber1, phoneNumber2, phoneNumber3], mode: .outgoingMessage)
        XCTAssertEqual(result1, [])

        // Send a request for some of the same numbers -- these should be de-duped.
        taskQueue.onPerform = { phoneNumbers, mode in
            if phoneNumbers == [] {
                return []
            }
            throw OWSGenericError("Invalid request.")
        }
        let result2 = try await lookUpAndReturnResult(phoneNumbers: [phoneNumber1, phoneNumber2], mode: .outgoingMessage)
        XCTAssertEqual(result2, [])

        // Send another request, but include an unknown number to force a request.
        taskQueue.onPerform = { phoneNumbers, mode in
            if phoneNumbers == [phoneNumber1, phoneNumber4] {
                return MockContactDiscoveryTaskQueue.foundResponse(for: [phoneNumber4])
            }
            throw OWSGenericError("Invalid request.")
        }
        let result3 = try await lookUpAndReturnResult(phoneNumbers: [phoneNumber1, phoneNumber4], mode: .outgoingMessage)
        XCTAssertEqual(result3, [phoneNumber4])
    }

    private func lookUpAndReturnResult(phoneNumbers: Set<String>, mode: ContactDiscoveryMode) async throws -> Set<String> {
        let phoneNumbers = try await manager.lookUp(phoneNumbers: phoneNumbers, mode: mode).map {
            $0.phoneNumber!.stringValue
        }
        return Set(phoneNumbers)
    }

    private func lookUpAndReturnRateLimitDate(phoneNumbers: Set<String>, mode: ContactDiscoveryMode) async throws -> Date? {
        do {
            _ = try await manager.lookUp(phoneNumbers: phoneNumbers, mode: mode)
            return nil
        } catch ContactDiscoveryError.rateLimit(let retryAfter) {
            return retryAfter
        }
    }

    /// Tellomi：没有 CDSI enclave 的部署（`TSConstantsStaging`，docs/signal/ENCLAVES.md）里，
    /// 每种模式的 `lookUp` 都直接回空、不碰任务队列——按手机号找人关掉，按用户名找人。
    func testTellomiNoCDSI_lookUpReturnsEmptyWithoutQuerying() async throws {
        tsConstants.cdsiAvailable = false

        var performCount = 0
        taskQueue.onPerform = { phoneNumbers, _ in
            performCount += 1
            return MockContactDiscoveryTaskQueue.foundResponse(for: phoneNumbers)
        }

        for mode in ContactDiscoveryMode.allCasesOrderedByRateLimitPriority {
            let result = try await lookUpAndReturnResult(phoneNumbers: ["+16505550100"], mode: mode)
            XCTAssertEqual(result, [], "\(mode)")
        }
        XCTAssertEqual(performCount, 0)
    }

    /// Ensures that all modes are included in `allCasesOrderedByRateLimitPriority.`
    ///
    /// This test is written weirdly so that the compiler will complain if you
    /// add a new mode without also updating this test. If you add a new mode &
    /// update this test but don't add it to the list sorted by priority, you'll
    /// get a test failure.
    func testModeRateLimitPriority() {
        let allCases = ContactDiscoveryMode.allCasesOrderedByRateLimitPriority
        let uniqueCases = Set(allCases)
        XCTAssertEqual(allCases.count, uniqueCases.count) // no duplicates
        var caseCount = 0
        for mode in Set(ContactDiscoveryMode.allCasesOrderedByRateLimitPriority) {
            switch mode {
            case .oneOffUserRequest, .outgoingMessage, .contactIntersection:
                caseCount += 1
            }
        }
        XCTAssertEqual(caseCount, 3) // every case appears
    }
}
