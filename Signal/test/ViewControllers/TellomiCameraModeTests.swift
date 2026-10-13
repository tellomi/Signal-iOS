//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import AVFoundation
import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// Tellomi（tellomi/tellomi#1520 C-1，同 Tellomi 安卓 `MediaCaptureModeBar` / `CaptureButtonState`）：会话里的相机有「视频 | 照片」；
/// 录像模式里快门是红的，点一下开始录（不用按住），再点一下停；拍照模式点一下拍照。
@MainActor
final class TellomiCameraModeTests: SignalBaseTest {

    func testTheBarOffersVideoThenPhoto() {
        let bar = ComposerTypeSelectionControl(segmentTitles: [CommonStrings.attachmentTypeVideo, CommonStrings.attachmentTypePhoto])
        XCTAssertEqual(bar.numberOfSegments, 2)
        XCTAssertEqual(bar.titleForSegment(at: 0), CommonStrings.attachmentTypeVideo.uppercased())
        XCTAssertEqual(bar.titleForSegment(at: 1), CommonStrings.attachmentTypePhoto.uppercased())
    }

    func testTheStoryBarIsUnchanged() {
        let bar = ComposerTypeSelectionControl()
        XCTAssertEqual(bar.numberOfSegments, 2)
        XCTAssertEqual(
            bar.titleForSegment(at: 0),
            OWSLocalizedString("STORY_COMPOSER_CAMERA", comment: "").uppercased(),
        )
    }

    func testInPhotoModeATapTakesAPhoto() {
        let (control, delegate) = makeControl()
        control.tapForTesting()
        XCTAssertEqual(delegate.calls, ["photo"])
        XCTAssertEqual(control.recordingState, .notRecording)
        XCTAssertEqual(resolved(control.shutterInnerColorForTesting), resolved(.white))
    }

    func testInVideoModeATapStartsRecordingAndASecondTapStopsIt() {
        let (control, delegate) = makeControl()
        control.isVideoMode = true
        XCTAssertEqual(resolved(control.shutterInnerColorForTesting), resolved(UIColor.Signal.red), "录像模式快门是红的")

        control.tapForTesting()
        XCTAssertEqual(delegate.calls, ["start"])
        XCTAssertEqual(control.recordingState, .recordingUsingVoiceOver, "点着在录：显示停止键，不用按住")

        control.tapForTesting()
        XCTAssertEqual(delegate.calls, ["start", "finish"])
    }

    func testVideoFlashIsOnOrOff() {
        var mode = AVCaptureDevice.FlashMode.off
        var seen = [mode]
        for _ in 0..<2 {
            mode = CameraCaptureSession.nextFlashMode(after: mode, isVideoMode: true)
            seen.append(mode)
        }
        XCTAssertEqual(seen, [.off, .on, .off])
        XCTAssertEqual(CameraCaptureSession.nextFlashMode(after: .auto, isVideoMode: true), .off)
    }

    /// 截图（TELLOMI_SHOTS=1）：会话里的相机，拍照模式和录像模式（模拟器没有相机，取景框是黑的）。
    func testScreenshots() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TELLOMI_SHOTS"] == "1", "只在 TELLOMI_SHOTS=1 时截图")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        let camera = PhotoCaptureViewController(attachmentLimits: .currentLimits())
        let delegate = CameraDelegate()
        camera.delegate = delegate
        camera.dataSource = delegate
        window.rootViewController = camera
        window.isHidden = false
        defer { window.isHidden = true }
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(camera.cameraModeTitlesForTesting, [CommonStrings.attachmentTypeVideo.uppercased(), CommonStrings.attachmentTypePhoto.uppercased()])
        try save(render(window), name: "camera-photo-mode.png", width: window.bounds.width)
        camera.setVideoModeForTesting(true)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(camera.isVideoModeForTesting)
        try save(render(window), name: "camera-video-mode.png", width: window.bounds.width)
    }

    private func render(_ window: UIWindow) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    private func save(_ image: UIImage, name: String, width: CGFloat) throws {
        let root = ProcessInfo.processInfo.environment["TELLOMI_SHOTS_DIR"] ?? NSTemporaryDirectory()
        let directory = URL(fileURLWithPath: root).appendingPathComponent("\(Int(width))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent(name))
    }

    /// `.Signal.red` 是跟着深浅色变的颜色，每次取都是新对象：比较取出来的实际颜色。
    private func resolved(_ color: UIColor?) -> UIColor? {
        color?.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
    }

    private func makeControl() -> (CameraCaptureControl, RecordingDelegate) {
        let control = CameraCaptureControl(axis: .horizontal)
        let delegate = RecordingDelegate()
        control.delegate = delegate
        return (control, delegate)
    }
}

private final class RecordingDelegate: CameraCaptureControlDelegate {
    var calls = [String]()

    func cameraCaptureControlDidRequestCapturePhoto(_ control: CameraCaptureControl) { calls.append("photo") }
    func cameraCaptureControlDidRequestStartVideoRecording(_ control: CameraCaptureControl) { calls.append("start") }
    func cameraCaptureControlDidRequestFinishVideoRecording(_ control: CameraCaptureControl) { calls.append("finish") }
    func cameraCaptureControlDidRequestCancelVideoRecording(_ control: CameraCaptureControl) { calls.append("cancel") }
    var zoomScaleReferenceDistance: CGFloat? { 100 }
    func cameraCaptureControl(_ control: CameraCaptureControl, didUpdateZoomLevel zoomLevel: CGFloat) {}
}

private final class CameraDelegate: PhotoCaptureViewControllerDelegate, PhotoCaptureViewControllerDataSource {
    func photoCaptureViewControllerDidFinish(_ photoCaptureViewController: PhotoCaptureViewController) {}
    func photoCaptureViewController(_ photoCaptureViewController: PhotoCaptureViewController, didFinishWithTextAttachment textAttachment: UnsentTextAttachment) {}
    func photoCaptureViewControllerDidCancel(_ photoCaptureViewController: PhotoCaptureViewController) {}
    func photoCaptureViewControllerDidTryToCaptureTooMany(_ photoCaptureViewController: PhotoCaptureViewController) {}
    func photoCaptureViewControllerViewWillAppear(_ photoCaptureViewController: PhotoCaptureViewController) {}
    func photoCaptureViewControllerCanCaptureMoreItems(_ photoCaptureViewController: PhotoCaptureViewController) -> Bool { true }
    func photoCaptureViewControllerDidRequestPresentPhotoLibrary(_ photoCaptureViewController: PhotoCaptureViewController) {}
    func photoCaptureViewController(
        _ photoCaptureViewController: PhotoCaptureViewController,
        didRequestSwitchCaptureModeTo captureMode: PhotoCaptureViewController.CaptureMode,
        completion: @escaping (Bool) -> Void,
    ) {
        completion(true)
    }
    func photoCaptureViewControllerCanShowTextEditor(_ photoCaptureViewController: PhotoCaptureViewController) -> Bool { false }
    func photoCaptureViewController(_ photoCaptureViewController: PhotoCaptureViewController, didTapCapturedItem item: AttachmentApprovalItem) {}

    var numberOfMediaItems: Int { 0 }
    func addMedia(attachment: PreviewableAttachment) {}
    var cameraCaptureItems: [AttachmentApprovalItem] { [] }
}
