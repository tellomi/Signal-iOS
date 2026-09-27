//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import CocoaLumberjack
import Foundation
import XCTest
@testable import SignalServiceKit
@testable import SignalUI

/// 发送端整条抓取（`LinkPreviewFetcherImpl` → `TellomiLinkFetcher`）的平台层用例（ADR-0063 §8.1 第 9、10 行；tellomi/tellomi#1423）。
final class TellomiLinkPreviewFetcherTest: XCTestCase {

    private var servers = [TellomiLocalHTTPTestServer]()
    private var capturingLogger: CapturingLogger?

    override func tearDown() {
        servers.forEach { $0.stop() }
        servers.removeAll()
        if let capturingLogger {
            DDLog.remove(capturingLogger)
        }
        capturingLogger = nil
        super.tearDown()
    }

    private final class CapturingLogger: DDAbstractLogger, @unchecked Sendable {
        private let lock = NSLock()
        private var _messages = [String]()

        var messages: [String] {
            lock.lock()
            defer { lock.unlock() }
            return _messages
        }

        override func log(message logMessage: DDLogMessage) {
            lock.lock()
            _messages.append(logMessage.message)
            lock.unlock()
        }
    }

    private func startServer(_ handler: @escaping TellomiLocalHTTPTestServer.Handler) async throws -> TellomiLocalHTTPTestServer {
        let server = try TellomiLocalHTTPTestServer(handler: handler)
        try await server.start()
        servers.append(server)
        return server
    }

    private struct NoDNS: TellomiLinkHostResolving {
        func resolve(host: String) async -> TellomiLinkResolution { .failed }
    }

    /// 生产校验，只把这一个测试服务的来源当成「https + 公网」。
    private func makeLinkFetcher(allowing server: TellomiLocalHTTPTestServer) -> TellomiLinkFetcher {
        let port = Int(server.port)
        let isTestOrigin: @Sendable (URL) -> Bool = { $0.scheme == "http" && $0.host == "127.0.0.1" && $0.port == port }
        let production = TellomiLinkURLGuard(resolver: NoDNS())
        let urlGuard = TellomiLinkURLGuard(
            checkShape: { isTestOrigin($0) ? .allowed : production.checkShape($0) },
            checkAddress: { url in isTestOrigin(url) ? .allowed : await production.checkAddress(url) },
        )
        return TellomiLinkFetcher(urlGuard: urlGuard, reachability: TellomiLinkReachability())
    }

    private func makeFetcher(linkFetcher: TellomiLinkFetcher, db: InMemoryDB = InMemoryDB()) -> LinkPreviewFetcherImpl {
        return LinkPreviewFetcherImpl(
            authCredentialManager: MockAuthCrededentialManager(),
            db: db,
            groupsV2: MockGroupsV2(),
            linkPreviewSettingStore: LinkPreviewSettingStore.mock(),
            tsAccountManager: MockTSAccountManager(),
            linkFetcher: linkFetcher,
        )
    }

    // MARK: - 日志里没有 URL（§6.5、§8.1 第 9 行的 canary 测法）

    func testLogsNeverContainTheUrlOrItsFragment() async throws {
        let pathCanary = "tellomi-path-canary-7f3a9c"
        let fragmentCanary = "tellomi-fragment-canary-91bc2e"
        let server = try await startServer { request in
            switch request.path {
            case "/ok/\(pathCanary)":
                return .html("<html><head><meta property=\"og:title\" content=\"ok\"><meta property=\"og:image\" content=\"/img/\(pathCanary).png\"></head></html>")
            case "/redirect/\(pathCanary)":
                return .redirect(to: "https://10.0.0.1/\(pathCanary)#\(fragmentCanary)")
            case "/drop/\(pathCanary)":
                return .drop
            default:
                return .html("missing", status: 404)
            }
        }
        let logger = CapturingLogger()
        DDLog.add(logger, with: .all)
        capturingLogger = logger

        let fetcher = makeFetcher(linkFetcher: makeLinkFetcher(allowing: server))
        // 成功（预览图 404）、404、跳到私网、网络层失败、tell.cc 不抓：每条都在路径和片段里带 canary
        let draft = try await fetcher.fetchLinkPreview(for: server.url("/ok/\(pathCanary)#\(fragmentCanary)"))
        XCTAssertEqual(draft.title, "ok")
        for path in ["/missing/\(pathCanary)", "/redirect/\(pathCanary)", "/drop/\(pathCanary)"] {
            do {
                _ = try await fetcher.fetchLinkPreview(for: server.url("\(path)#\(fragmentCanary)"))
                XCTFail("expected failure for \(path)")
            } catch {
                XCTAssertEqual(error as? LinkPreviewError, .fetchFailure)
            }
        }
        do {
            _ = try await fetcher.fetchLinkPreview(for: URL(string: "https://tell.cc/\(pathCanary.replacingOccurrences(of: "-", with: "_"))#\(fragmentCanary)")!)
            XCTFail("tell.cc must not be fetched")
        } catch {
            XCTAssertEqual(error as? LinkPreviewError, .noPreview)
        }

        Logger.flush()
        let messages = logger.messages
        // 失败确实记了日志（只有类别），不然这条测试证明不了什么
        XCTAssertTrue(messages.contains(where: { $0.contains("http-404") }), "\(messages)")
        XCTAssertTrue(messages.contains(where: { $0.contains("blocked-address") }), "\(messages)")
        let leaked = messages.filter { $0.contains(pathCanary) || $0.contains(fragmentCanary) || $0.contains("127.0.0.1") }
        XCTAssertEqual(leaked.count, 0, "\(leaked)")
    }

    // MARK: - tell.cc（§4.8：不放网页，认不出的不抓）

    func testTellCCUsernamesAndUnknownPathsAreNeverFetched() async throws {
        final class Recorder: @unchecked Sendable {
            let lock = NSLock()
            var urls = [URL]()
        }
        let recorder = Recorder()
        let urlGuard = TellomiLinkURLGuard(
            checkShape: { url in
                recorder.lock.lock()
                recorder.urls.append(url)
                recorder.lock.unlock()
                return .blockedAddress
            },
            checkAddress: { _ in .blockedAddress },
        )
        let fetcher = makeFetcher(linkFetcher: TellomiLinkFetcher(urlGuard: urlGuard, reachability: TellomiLinkReachability()))
        for rawUrl in [
            "https://tell.cc/kaixin",
            "https://tell.cc/kaixin.57",
            "https://tell.cc/u#u/kaixin",
            "https://tell.cc/u#p/+8613800000004",
            "https://tell.cc/app",
            "https://tell.cc/.well-known/apple-app-site-association",
            "https://tell.cc/",
        ] {
            do {
                _ = try await fetcher.fetchLinkPreview(for: URL(string: rawUrl)!)
                XCTFail("expected no preview for \(rawUrl)")
            } catch {
                XCTAssertEqual(error as? LinkPreviewError, .noPreview, rawUrl)
            }
        }
        XCTAssertEqual(recorder.urls, [])
    }

    // MARK: - 「展开短链接」开关（只存本机，默认开）

    func testShortLinkSwitchDefaultsOnAndOffSendsNothing() async throws {
        let server = try await startServer { _ in .redirect(to: "https://www.bilibili.com/video/BV1GJ411x7h7", status: 301) }
        let linkFetcher = makeLinkFetcher(allowing: server)
        let db = InMemoryDB()
        let fetcher = makeFetcher(linkFetcher: linkFetcher, db: db)

        XCTAssertTrue(db.read { TellomiLinkPreviewLocalSettings.isShortLinkExpansionEnabled(tx: $0) })
        let expanded = await fetcher.expandShortLinkIfEnabled(server.url("/b23"), budget: linkFetcher.makeBudget())
        XCTAssertEqual(expanded?.absoluteString, "https://www.bilibili.com/video/BV1GJ411x7h7")
        XCTAssertEqual(server.requests.count, 1)

        db.write { TellomiLinkPreviewLocalSettings.setShortLinkExpansionEnabled(false, tx: $0) }
        let budget = linkFetcher.makeBudget()
        let notExpanded = await fetcher.expandShortLinkIfEnabled(server.url("/b23"), budget: budget)
        XCTAssertNil(notExpanded)
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertEqual(budget.metadataRequestsUsed, 0)
    }
}
