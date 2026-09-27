//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

class ConversationViewControllerTest: SignalBaseTest {

    func testCVCBottomViewType() {
        XCTAssertEqual(CVCBottomViewType.none, CVCBottomViewType.none)
        XCTAssertNotEqual(CVCBottomViewType.none, CVCBottomViewType.inputToolbar)
        XCTAssertEqual(CVCBottomViewType.inputToolbar, CVCBottomViewType.inputToolbar)
        XCTAssertNotEqual(CVCBottomViewType.none, CVCBottomViewType.memberRequestView)
        XCTAssertNotEqual(
            CVCBottomViewType.memberRequestView,
            CVCBottomViewType.messageRequestView(
                messageRequestType: MessageRequestType(
                    isGroupV1Thread: true,
                    isGroupV2Thread: true,
                    isThreadBlocked: true,
                    hasSentMessages: true,
                    isThreadFromHiddenRecipient: false,
                    hasReportedSpam: false,
                    isLocalUserInvitedMember: false,
                    showReviewRequestsCarefullyWarning: false,
                ),
            ),
        )
        XCTAssertEqual(
            CVCBottomViewType.messageRequestView(
                messageRequestType: MessageRequestType(
                    isGroupV1Thread: true,
                    isGroupV2Thread: true,
                    isThreadBlocked: true,
                    hasSentMessages: true,
                    isThreadFromHiddenRecipient: false,
                    hasReportedSpam: false,
                    isLocalUserInvitedMember: false,
                    showReviewRequestsCarefullyWarning: false,
                ),
            ),
            CVCBottomViewType.messageRequestView(
                messageRequestType: MessageRequestType(
                    isGroupV1Thread: true,
                    isGroupV2Thread: true,
                    isThreadBlocked: true,
                    hasSentMessages: true,
                    isThreadFromHiddenRecipient: false,
                    hasReportedSpam: false,
                    isLocalUserInvitedMember: false,
                    showReviewRequestsCarefullyWarning: false,
                ),
            ),
        )
        XCTAssertNotEqual(
            CVCBottomViewType.messageRequestView(
                messageRequestType: MessageRequestType(
                    isGroupV1Thread: true,
                    isGroupV2Thread: true,
                    isThreadBlocked: true,
                    hasSentMessages: true,
                    isThreadFromHiddenRecipient: false,
                    hasReportedSpam: false,
                    isLocalUserInvitedMember: false,
                    showReviewRequestsCarefullyWarning: false,
                ),
            ),
            CVCBottomViewType.messageRequestView(
                messageRequestType: MessageRequestType(
                    isGroupV1Thread: true,
                    isGroupV2Thread: false,
                    isThreadBlocked: true,
                    hasSentMessages: true,
                    isThreadFromHiddenRecipient: false,
                    hasReportedSpam: false,
                    isLocalUserInvitedMember: false,
                    showReviewRequestsCarefullyWarning: false,
                ),
            ),
        )
        XCTAssertEqual(
            CVCBottomViewType.messageRequestView(
                messageRequestType: MessageRequestType(
                    isGroupV1Thread: true,
                    isGroupV2Thread: false,
                    isThreadBlocked: true,
                    hasSentMessages: true,
                    isThreadFromHiddenRecipient: false,
                    hasReportedSpam: false,
                    isLocalUserInvitedMember: false,
                    showReviewRequestsCarefullyWarning: false,
                ),
            ),
            CVCBottomViewType.messageRequestView(
                messageRequestType: MessageRequestType(
                    isGroupV1Thread: true,
                    isGroupV2Thread: false,
                    isThreadBlocked: true,
                    hasSentMessages: true,
                    isThreadFromHiddenRecipient: false,
                    hasReportedSpam: false,
                    isLocalUserInvitedMember: false,
                    showReviewRequestsCarefullyWarning: false,
                ),
            ),
        )
        XCTAssertNotEqual(
            CVCBottomViewType.messageRequestView(
                messageRequestType: MessageRequestType(
                    isGroupV1Thread: true,
                    isGroupV2Thread: true,
                    isThreadBlocked: true,
                    hasSentMessages: false,
                    isThreadFromHiddenRecipient: false,
                    hasReportedSpam: false,
                    isLocalUserInvitedMember: false,
                    showReviewRequestsCarefullyWarning: false,
                ),
            ),
            CVCBottomViewType.messageRequestView(
                messageRequestType: MessageRequestType(
                    isGroupV1Thread: true,
                    isGroupV2Thread: false,
                    isThreadBlocked: true,
                    hasSentMessages: true,
                    isThreadFromHiddenRecipient: false,
                    hasReportedSpam: false,
                    isLocalUserInvitedMember: false,
                    showReviewRequestsCarefullyWarning: false,
                ),
            ),
        )
    }
}

/// Tellomi（tellomi/tellomi#1109，ADR-0058 §2）：滑动回复改成手指从右往左滑。
class TellomiSwipeToReplyTest: XCTestCase {

    func testThresholdIs45ForIncomingAnd60ForOutgoingAsInTelegram() {
        XCTAssertEqual(CVComponentMessage.tellomiSwipeToReplyThreshold(isIncoming: true), 45)
        XCTAssertEqual(CVComponentMessage.tellomiSwipeToReplyThreshold(isIncoming: false), 60)
    }

    func testBubbleFollowsTheFingerUpToTheThresholdThenRubberBands() {
        XCTAssertEqual(CVComponentMessage.tellomiSwipeToReplyBubbleOffset(fingerOffset: 0, threshold: 45), 0)
        XCTAssertEqual(CVComponentMessage.tellomiSwipeToReplyBubbleOffset(fingerOffset: -12, threshold: 45), 0)
        XCTAssertEqual(CVComponentMessage.tellomiSwipeToReplyBubbleOffset(fingerOffset: 30, threshold: 45), 30)
        XCTAssertEqual(CVComponentMessage.tellomiSwipeToReplyBubbleOffset(fingerOffset: 45, threshold: 45), 45)
        // 过阈值 100：(1 - 1 / (100 × 0.4 / 100 + 1)) × 100 ≈ 28.57
        XCTAssertEqual(CVComponentMessage.tellomiSwipeToReplyBubbleOffset(fingerOffset: 145, threshold: 45), 73.571, accuracy: 0.01)
        let far = CVComponentMessage.tellomiSwipeToReplyBubbleOffset(fingerOffset: 10_000, threshold: 60)
        XCTAssertGreaterThan(far, 155)
        XCTAssertLessThanOrEqual(far, 180)
    }

    func testOnlyRightToLeftHorizontalPansBeginOnMessagesExceptAudioScrubbing() {
        // 从右往左：回复
        XCTAssertTrue(ConversationViewController.tellomiShouldBeginMessagePan(translation: CGPoint(x: -10, y: 2), isRTL: false, isScrubbingAudio: false))
        // 从左往右：不接，留给系统返回
        XCTAssertFalse(ConversationViewController.tellomiShouldBeginMessagePan(translation: CGPoint(x: 10, y: 2), isRTL: false, isScrubbingAudio: false))
        // 拖语音进度两个方向都要
        XCTAssertTrue(ConversationViewController.tellomiShouldBeginMessagePan(translation: CGPoint(x: 10, y: 2), isRTL: false, isScrubbingAudio: true))
        // 纵向让给滚动
        XCTAssertFalse(ConversationViewController.tellomiShouldBeginMessagePan(translation: CGPoint(x: -3, y: 8), isRTL: false, isScrubbingAudio: false))
        // RTL 镜像
        XCTAssertTrue(ConversationViewController.tellomiShouldBeginMessagePan(translation: CGPoint(x: 10, y: 2), isRTL: true, isScrubbingAudio: false))
        XCTAssertFalse(ConversationViewController.tellomiShouldBeginMessagePan(translation: CGPoint(x: -10, y: 2), isRTL: true, isScrubbingAudio: false))
    }
}
