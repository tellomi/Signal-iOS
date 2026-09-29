//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import XCTest
@testable import SignalServiceKit

/// ADR-0063 §5.1 第 4 条（tellomi/tellomi#1423）：接收端的判定——给 rust/links 的输入长什么样、缓存、失败时怎么办、日志不带 URL。
/// 用假的注册表，不依赖 libsignal 的原生库。与 Android `TellomiLinkRegistry.classify`、Desktop `classifyLinkPreview` 同一套约定。
final class TellomiLinkClassifierTest: XCTestCase {

    private final class FakeRegistry: TellomiLinkClassifying {
        var version: UInt64 = 1
        var classifyResult: Result<String, Error> = .success(#"{"level":"generic","domain":"bilibili.com"}"#)
        var openPlanResult: Result<String, Error> = .success(#"{"steps":[],"label":"x"}"#)
        private(set) var classifyCalls = [(preview: String, body: String, message: String)]()

        func classify(preview: String, body: String, message: String) throws -> String {
            classifyCalls.append((preview, body, message))
            return try classifyResult.get()
        }

        func openPlan(_ url: String) throws -> String {
            try openPlanResult.get()
        }
    }

    private struct Boom: Error {}

    private let url = "https://www.bilibili.com/video/BV1YDhJ6ZEL6"
    private var logged = [String]()

    private func makeClassifier(_ registry: FakeRegistry?) -> TellomiLinkClassifier {
        TellomiLinkClassifier(registry: registry, log: { _ in })
    }

    private func object(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    func testTheInputIsThePreviewsFieldsAndTheContext() throws {
        let registry = FakeRegistry()
        let classifier = makeClassifier(registry)
        let preview = TellomiLinkClassifier.PreviewInput(
            url: url,
            title: "Sender title",
            description: "Sender description",
            hasImage: true,
            date: Date(timeIntervalSince1970: 1_790_000_000.5),
            rich: Data([0x0a, 0xff, 0x00]),
        )

        let card = classifier.classify(preview, body: url, isStory: true, attachmentContentTypes: ["text/x-signal-plain"])

        XCTAssertEqual(card?.level, .generic)
        let call = try XCTUnwrap(registry.classifyCalls.first)
        XCTAssertEqual(call.body, url)
        let previewObject = try object(call.preview)
        XCTAssertEqual(previewObject["url"] as? String, url)
        XCTAssertEqual(previewObject["title"] as? String, "Sender title")
        XCTAssertEqual(previewObject["description"] as? String, "Sender description")
        XCTAssertEqual(previewObject["has_image"] as? Bool, true)
        XCTAssertEqual((previewObject["date"] as? NSNumber)?.uint64Value, 1_790_000_000_500)
        XCTAssertEqual(previewObject["rich"] as? String, "0aff00")
        let context = try object(call.message)
        XCTAssertEqual(context["is_story"] as? Bool, true)
        XCTAssertEqual(context["attachment_content_types"] as? [String], ["text/x-signal-plain"])
    }

    func testEmptyFieldsAreLeftOut() throws {
        let registry = FakeRegistry()
        _ = makeClassifier(registry).classify(
            TellomiLinkClassifier.PreviewInput(url: url, title: "", description: "", hasImage: false, date: Date(timeIntervalSince1970: 0), rich: nil),
            body: url,
            isStory: false,
            attachmentContentTypes: [],
        )
        let previewObject = try object(XCTUnwrap(registry.classifyCalls.first).preview)
        XCTAssertEqual(Set(previewObject.keys), ["url", "has_image"])
        XCTAssertEqual(previewObject["has_image"] as? Bool, false)
    }

    func testTheSameMessageIsDecidedOnceAndANewRegistryVersionDecidesAgain() {
        let registry = FakeRegistry()
        let classifier = makeClassifier(registry)
        let preview = TellomiLinkClassifier.PreviewInput(url: url, title: "T")

        _ = classifier.classify(preview, body: url, isStory: false, attachmentContentTypes: [])
        _ = classifier.classify(preview, body: url, isStory: false, attachmentContentTypes: [])
        XCTAssertEqual(registry.classifyCalls.count, 1)

        _ = classifier.classify(preview, body: url + " ", isStory: false, attachmentContentTypes: [])
        XCTAssertEqual(registry.classifyCalls.count, 2, "another body is another decision")

        registry.version = 2
        _ = classifier.classify(preview, body: url, isStory: false, attachmentContentTypes: [])
        XCTAssertEqual(registry.classifyCalls.count, 3, "a hot update applies to messages already stored")
    }

    func testNoRegistryDecidesNothing() {
        let classifier = makeClassifier(nil)
        XCTAssertFalse(classifier.isAvailable)
        XCTAssertNil(classifier.classify(.init(url: url), body: url, isStory: false, attachmentContentTypes: []))
        XCTAssertNil(classifier.lookalike(forUrl: url))
    }

    func testAFailureOrACardThisBuildDoesNotUnderstandDecidesNothing() {
        let registry = FakeRegistry()
        let classifier = makeClassifier(registry)

        registry.classifyResult = .failure(Boom())
        XCTAssertNil(classifier.classify(.init(url: url), body: url, isStory: false, attachmentContentTypes: []))

        registry.classifyResult = .success(#"{"level":"hologram"}"#)
        XCTAssertNil(classifier.classify(.init(url: url + "/2"), body: url, isStory: false, attachmentContentTypes: []))
    }

    func testTheLogNeverHasTheURL() {
        let registry = FakeRegistry()
        var lines = [String]()
        let lock = NSLock()
        let classifier = TellomiLinkClassifier(registry: registry, log: { line in lock.lock(); lines.append(line); lock.unlock() })

        registry.classifyResult = .success(#"{"level":"structured","provider":"bilibili","route":"video","kind":"video","reason":"structured"}"#)
        _ = classifier.classify(.init(url: url, title: "Secret title"), body: url, isStory: false, attachmentContentTypes: [])
        registry.classifyResult = .failure(Boom())
        _ = classifier.classify(.init(url: url + "#fragment"), body: url, isStory: false, attachmentContentTypes: [])
        registry.openPlanResult = .failure(Boom())
        _ = classifier.lookalike(forUrl: url + "#fragment")

        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("bilibili/video structured (structured)"))
        for line in lines {
            XCTAssertFalse(line.contains("bilibili.com"), line)
            XCTAssertFalse(line.contains("http"), line)
            XCTAssertFalse(line.contains("#"), line)
            XCTAssertFalse(line.contains("Secret"), line)
        }
    }

    func testTheLookalikeIsTheOpenPlansWarning() {
        let registry = FakeRegistry()
        let classifier = makeClassifier(registry)

        registry.openPlanResult = .success(#"{"steps":[],"label":"x","lookalike":"bilibili.com"}"#)
        XCTAssertEqual(classifier.lookalike(forUrl: "https://www.bi1ibili.com/v"), "bilibili.com")

        registry.openPlanResult = .success(#"{"steps":[],"label":"x"}"#)
        XCTAssertNil(classifier.lookalike(forUrl: url))

        registry.openPlanResult = .success("not json")
        XCTAssertNil(classifier.lookalike(forUrl: url))

        registry.openPlanResult = .failure(Boom())
        XCTAssertNil(classifier.lookalike(forUrl: url))
    }
}
