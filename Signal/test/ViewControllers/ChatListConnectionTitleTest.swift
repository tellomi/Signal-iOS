//
// Copyright 2026 Tellomi
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import XCTest
@testable import Signal

/// Tellomi（tellomi/tellomi#1218 F-04）。
final class ChatListConnectionTitleTest: XCTestCase {
    private func title(
        canConnect: Bool = true,
        isReachable: Bool = true,
        _ state: OWSChatConnectionState,
        emptied: Bool,
    ) -> ChatListConnectionTitle {
        return ChatListConnectionTitle.from(
            canConnect: canConnect,
            isReachable: isReachable,
            identifiedConnectionState: state,
            hasEmptiedInitialQueue: emptied,
        )
    }

    func testNoNetworkWinsOverAStaleConnectionState() {
        for state in [OWSChatConnectionState.closed, .connecting, .open] {
            XCTAssertEqual(title(isReachable: false, state, emptied: true), .waitingForNetwork, "\(state)")
        }
    }

    func testOpenShowsUpdatingUntilTheQueueIsEmptied() {
        XCTAssertEqual(title(.open, emptied: false), .updating)
        XCTAssertEqual(title(.open, emptied: true), .connected)
    }

    func testClosedOrConnectingWithNetworkIsConnecting() {
        XCTAssertEqual(title(.closed, emptied: false), .connecting)
        XCTAssertEqual(title(.connecting, emptied: false), .connecting)
    }

    func testNotRegisteredOrExpiredNeverSpins() {
        XCTAssertEqual(title(canConnect: false, isReachable: false, .closed, emptied: false), .connected)
        XCTAssertEqual(title(canConnect: false, .closed, emptied: false), .connected)
    }

    func testOnlyLeavingConnectedIsDelayed() {
        XCTAssertTrue(ChatListConnectionTitle.shouldDelay(from: .connected, to: .connecting))
        XCTAssertTrue(ChatListConnectionTitle.shouldDelay(from: .connected, to: .waitingForNetwork))
        XCTAssertTrue(ChatListConnectionTitle.shouldDelay(from: .connected, to: .updating))

        // 第一次立刻显示；不是从「已连上」离开的变化立刻显示；回到「已连上」立刻显示
        XCTAssertFalse(ChatListConnectionTitle.shouldDelay(from: nil, to: .connecting))
        XCTAssertFalse(ChatListConnectionTitle.shouldDelay(from: .connecting, to: .updating))
        XCTAssertFalse(ChatListConnectionTitle.shouldDelay(from: .waitingForNetwork, to: .connecting))
        XCTAssertFalse(ChatListConnectionTitle.shouldDelay(from: .updating, to: .connected))
    }

    func testOnlyConnectedKeepsTheOriginalTitle() {
        XCTAssertNil(ChatListConnectionTitle.connected.text)
        for status in [ChatListConnectionTitle.waitingForNetwork, .connecting, .updating] {
            XCTAssertFalse(status.text?.isEmpty ?? true, "\(status)")
            XCTAssertFalse(status.text?.hasSuffix("_TELLOMI") ?? true, "\(status) 显示成了键名")
        }
    }
}
