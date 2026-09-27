//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import AVFoundation
import SignalServiceKit
import SignalUI

/// Tellomi（tellomi/tellomi#1261 P-8）：「最近」第一格的相机实时取景要的相机。
enum TellomiPhotoPickerCameraAccess {
    /// 已授权：实时取景。
    case authorized
    /// 没问过：这一格只放相机图标，点了由上游相机流程去问（选图面板自己不弹授权，权限引导以 #1115 为准）。
    case notDetermined
    /// 没有相机、被拒或受限制：不挖这一格。
    case unavailable
}

protocol TellomiPhotoPickerCamera: AnyObject {
    var access: TellomiPhotoPickerCameraAccess { get }
    /// 实时取景的视图（只在已授权时要）；铺满相机格，等比填满、居中裁切。
    func makePreviewView() -> UIView
    func startPreview()
    func stopPreview()
}

/// 后置广角相机的实时取景：只取景不拍，低分辨率就够；会话在自己的串行队列上起停。
final class TellomiSystemPickerCamera: NSObject, TellomiPhotoPickerCamera {

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "org.signal.tellomi.photo-picker-camera")
    private var isConfigured = false

    var access: TellomiPhotoPickerCameraAccess {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            return .unavailable
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return .authorized
        case .notDetermined:
            return .notDetermined
        case .denied, .restricted:
            return .unavailable
        @unknown default:
            return .unavailable
        }
    }

    func makePreviewView() -> UIView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func startPreview() {
        guard access == .authorized else { return }
        sessionQueue.async {
            if !self.isConfigured {
                self.configure()
            }
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    func stopPreview() {
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    private func configure() {
        isConfigured = true
        session.beginConfiguration()
        session.sessionPreset = .medium
        if
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        {
            session.addInput(input)
        } else {
            Logger.warn("Photo picker camera preview unavailable")
        }
        session.commitConfiguration()
    }

    private final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var previewLayer: AVCaptureVideoPreviewLayer {
            // swiftlint:disable:next force_cast
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}

/// 网格里的相机格：已授权是实时取景、右上角一个小相机图标（照 Telegram TGAttachmentCameraView，离上、右各 3）；
/// 没问过是居中的相机图标。点了由选图页处理（打开相机）。
final class TellomiPhotoPickerCameraCell: UICollectionReusableView {

    static let kind = "TellomiPhotoPickerCamera"
    static let reuseIdentifier = "TellomiPhotoPickerCameraCell"

    var onTap: (() -> Void)?

    private var previewView: UIView?
    private let placeholder = UIImageView(image: Theme.iconImage(.buttonCamera))
    private let cornerIcon = UIImageView(image: Theme.iconImage(.buttonCamera))
    /// 铺满整格的透明按钮接点按（测试走它的 sendActions，接线错了会红）。
    private let tapButton = UIButton(type: .custom)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.1, alpha: 1)
        clipsToBounds = true

        placeholder.tintColor = .white
        placeholder.contentMode = .center
        addSubview(placeholder)

        // 取景可能很亮：小图标垫一个半透明深色圆底。
        cornerIcon.tintColor = .white
        cornerIcon.contentMode = .center
        cornerIcon.backgroundColor = UIColor.black.withAlphaComponent(0.3)
        cornerIcon.clipsToBounds = true
        addSubview(cornerIcon)

        tapButton.accessibilityLabel = OWSLocalizedString("IMAGE_PICKER_TELLOMI_CAMERA", comment: "Accessibility label of the live camera cell at the start of the photo picker grid.")
        tapButton.addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)
        addSubview(tapButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(camera: TellomiPhotoPickerCamera) {
        let isLive = camera.access == .authorized
        if isLive, previewView == nil {
            let view = camera.makePreviewView()
            insertSubview(view, belowSubview: placeholder)
            previewView = view
        }
        previewView?.isHidden = !isLive
        placeholder.isHidden = isLive
        cornerIcon.isHidden = !isLive
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewView?.frame = bounds
        placeholder.frame = bounds
        let iconSide: CGFloat = 28
        cornerIcon.frame = CGRect(x: bounds.width - iconSide - 3, y: 3, width: iconSide, height: iconSide)
        cornerIcon.layer.cornerRadius = iconSide / 2
        tapButton.frame = bounds
    }

    var isShowingLivePreviewForTesting: Bool { previewView?.isHidden == false }
    var isShowingPlaceholderForTesting: Bool { !placeholder.isHidden }
    var isShowingCornerIconForTesting: Bool { !cornerIcon.isHidden }

    func tapForTesting() {
        tapButton.sendActions(for: .touchUpInside)
    }
}
