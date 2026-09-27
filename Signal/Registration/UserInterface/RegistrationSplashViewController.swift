//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
public import SignalUI

// MARK: - RegistrationSplashPresenter

public protocol RegistrationSplashPresenter: AnyObject {
    func continueFromSplash()
    func setHasOldDevice(_ hasOldDevice: Bool)

    func switchToDeviceLinkingMode()

    /// Tellomi（ADR-0072 §4.2 第 1 步）：点了欢迎页上的「上次登录」。
    func tellomiContinueWithLastLogin()
}

extension RegistrationSplashPresenter {
    public func tellomiContinueWithLastLogin() {}
}

// MARK: - RegistrationSplashViewController

public class RegistrationSplashViewController: OWSViewController, OWSNavigationChildController {

    public var prefersNavigationBarHidden: Bool {
        true
    }

    private weak var presenter: RegistrationSplashPresenter?

    /// Tellomi（ADR-0072 §4.1 第 4 步）：本机已退出登录时，上方显示「上次登录」（头像 + 打码的手机号）。
    private let tellomiLastLogin: TellomiLastLogin?

    public init(presenter: RegistrationSplashPresenter, tellomiLastLogin: TellomiLastLogin? = nil) {
        self.presenter = presenter
        self.tellomiLastLogin = tellomiLastLogin
        super.init()
    }

    override public func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .Signal.background

        // Tellomi（ADR-0072）：本机已退出登录时不给「切换成关联设备」——这台设备上还放着那个账号的数据。
        if UIDevice.current.isIPad, tellomiLastLogin == nil {
            let modeSwitchButton = UIButton(
                configuration: .plain(),
                primaryAction: UIAction { [weak self] _ in
                    self?.didTapModeSwitch()
                },
            )
            modeSwitchButton.configuration?.image = .link
            modeSwitchButton.tintColor = .ows_gray25

            view.addSubview(modeSwitchButton)
            modeSwitchButton.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                modeSwitchButton.widthAnchor.constraint(equalToConstant: 40),
                modeSwitchButton.heightAnchor.constraint(equalToConstant: 40),
                modeSwitchButton.trailingAnchor.constraint(equalTo: contentLayoutGuide.trailingAnchor),
                modeSwitchButton.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor),
            ])
        }

        // Tellomi（owner 2026-09-27，docs/brand/README.md「插画」「开屏轮播」）：上面是四张 Open Doodles（黑白）的轮播，
        // 取代上游的插画。见文件末尾的 TellomiSplashCarouselView。
        let carousel = TellomiSplashCarouselView()
        carousel.setCompressionResistanceLow()
        carousel.setContentHuggingVerticalLow()

        // Tellomi（owner 2026-09-27，docs/product/BRAND.md「开屏」）：轮播下面只放字标 Tellomi，不放任何句子（App 内不显示标语）。
        // 字标是 docs/brand/wordmark/tellomi-wordmark-{light,dark}.svg 原样拷入（owner 2026-09-27 定稿的 Tell@mi）；只约束高度，宽高比取图本身，
        // 换字标只换这个 imageset 里的两个 SVG。
        // 上游这里是标题「Take privacy with you…」（更早还按是否生产服务显示调试串，tellomi/tellomi#1209）。
        let wordmarkView = UIImageView(image: UIImage(named: "tellomi_wordmark"))
        wordmarkView.contentMode = .scaleAspectFit
        wordmarkView.isAccessibilityElement = true
        wordmarkView.accessibilityLabel = "Tellomi"
        wordmarkView.accessibilityTraits = .header
        wordmarkView.accessibilityIdentifier = "tellomi.splash.wordmark"
        wordmarkView.translatesAutoresizingMaskIntoConstraints = false
        wordmarkView.heightAnchor.constraint(equalToConstant: 40).isActive = true

        // Tellomi：上游这里是「Signal 是一个非营利组织」。整行去掉，不做替换——
        // Tellomi 不是非营利组织，换成「Tellomi 是一个非营利组织」是假陈述；
        // 留着原文又是在我们自己的登录页上写别人的名字。捐赠 / 非营利那一整类文案同理，
        // 都在 build/brand-strings-todo.txt 里等 owner 定，不由脚本自动替换。

        // Tellomi（owner 2026-09-27，docs/product/BRAND.md「开屏」）：上游这里的「协议与隐私政策」链接去掉——
        // 首次打开的隐私提示和号码页的勾选里都能打开《隐私政策》。

        // Large buttons enclosed in a container with some extra horizontal padding.
        let continueButton = UIButton(
            configuration: .largePrimary(title: CommonStrings.continueButton),
            primaryAction: UIAction { [weak self] _ in
                self?.continuePressed()
            },
        )
        // Tellomi（owner 2026-09-27）：开屏的「继续」保持苹果原生蓝，不用 Signal 的 ultramarine（.Signal.accent）；只改这一个按钮，不动全局 tint。
        continueButton.configuration?.baseBackgroundColor = .systemBlue

        // Tellomi：上游「恢复或转移账户」和「继续」一样大，而 Tellomi 能走通的只有一条路（iPhone 到 iPhone 直连传输），
        // 大多数人是第一次注册。降成主按钮下面一行文字链（tellomi/tellomi#1216）。以后有了云备份，入口还在这里，只是里面多几条路。
        // Telegram 两端都把次要动作做成主按钮旁边的一行文字：iOS（RMIntroViewController 的 _alternativeLanguageButton）在按钮下方，
        // Android（IntroActivity 的 switchLanguageTextView）在按钮上方 30dp。Tellomi 两端都取下方。
        let restoreOrTransferButton = UIButton(
            configuration: .mediumBorderless(title: OWSLocalizedString(
                "ONBOARDING_SPLASH_NEW_PHONE_LINK_TITLE",
                comment: "Tellomi: One-line text link under the 'Continue' button in the 'onboarding splash' view, for people moving to a new phone.",
            )),
            primaryAction: UIAction { [weak self] _ in
                self?.didTapRestoreOrTransfer()
            },
        )
        restoreOrTransferButton.enableMultilineLabel()

        // Tellomi（ADR-0072）：本机已退出登录时不给「换了新手机？」——那条路是把别的手机上的账号搬过来，
        // 会覆盖这台手机上还留着的那个账号；要换账号走「继续」输别的号码（先确认清空本机）。
        let largeButtonsContainer = UIStackView.verticalButtonStack(
            buttons: tellomiLastLogin == nil ? [continueButton, restoreOrTransferButton] : [continueButton],
        )

        // Tellomi（ADR-0072 §4.1 第 4 步，需求 §3.2）：欢迎页上方的「上次登录」，点一下直接进验证码页。
        // 轮播照旧，只是被往下挤一点（它的压缩阻力本来就低）。
        let lastLoginView = tellomiLastLogin.map { lastLogin in
            TellomiLastLoginView(lastLogin: lastLogin) { [weak self] in
                self?.didTapTellomiLastLogin()
            }
        }

        // Main content view.
        let arrangedSubviews: [UIView?] = [
            lastLoginView,
            carousel,
            wordmarkView,
            largeButtonsContainer,
        ]
        let stackView = addStaticContentStackView(arrangedSubviews: arrangedSubviews.compactMap { $0 })
        if let lastLoginView {
            stackView.setCustomSpacing(16, after: lastLoginView)
        }
        stackView.setCustomSpacing(24, after: carousel)
        stackView.setCustomSpacing(80, after: wordmarkView)

        view.sendSubviewToBack(stackView)
    }

    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        // Tellomi：第一次打开先弹一次隐私提示（2019《认定方法》：首次运行要用弹窗等明显方式提示隐私政策；
        // tellomi/tellomi#1211）。同意之前这一页的按钮都被挡在提示后面。
        if !TellomiLegalConsent.hasAcceptedFirstLaunchNotice, presentedViewController == nil {
            presentTellomiFirstLaunchNotice()
        }
    }

    // MARK: - Events

    private func didTapModeSwitch() {
        Logger.info("")
        // Tellomi：关联设备要连服务端，同意跨境之前网络是关着的（tellomi/tellomi#1133）。
        // Tellomi（tellomi/tellomi#1338）：iPad「切换到关联」出只读版，点「知道了」记下告知版本、放开网络。
        guard TellomiCrossBorderConsent.hasAgreed else {
            presentTellomiCrossBorderNotice(mode: .linkedDevice) { [weak self] in
                self?.didTapModeSwitch()
            }
            return
        }
        presenter?.switchToDeviceLinkingMode()
    }

    private func continuePressed() {
        Logger.info("")
        presenter?.continueFromSplash()
    }

    /// Tellomi（ADR-0072 §4.2 第 1 步）：跳过号码页，直接给本机账号的号码发验证码。
    /// 发验证码要连服务端：协议、跨境同意这两道闸和号码页一样要过（一般注册时都已同意过，不会再弹）。
    private func didTapTellomiLastLogin() {
        Logger.info("")
        guard TellomiLegalConsent.hasAgreedToTerms else {
            presentTellomiTermsConsentDialog { [weak self] in
                TellomiLegalConsent.setAgreedToTerms(true)
                self?.didTapTellomiLastLogin()
            }
            return
        }
        guard TellomiCrossBorderConsent.hasGivenSeparateConsent else {
            presentTellomiCrossBorderNotice { [weak self] in
                self?.didTapTellomiLastLogin()
            }
            return
        }
        presenter?.tellomiContinueWithLastLogin()
    }

    private func didTapRestoreOrTransfer() {
        Logger.info("")
        // Tellomi：恢复 / 转移都要连服务端（扫码恢复、备份），同意跨境之前网络是关着的（tellomi/tellomi#1133）。
        // Tellomi（tellomi/tellomi#1338）：这是主设备，要完整同意；关联设备只读版的「知道了」不算。
        guard TellomiCrossBorderConsent.hasGivenSeparateConsent else {
            presentTellomiCrossBorderNotice { [weak self] in
                self?.didTapRestoreOrTransfer()
            }
            return
        }
        let sheet = RestoreOrTransferPickerController(
            setHasOldDeviceBlock: { [weak self] hasOldDevice in
                self?.dismiss(animated: true) {
                    self?.presenter?.setHasOldDevice(hasOldDevice)
                }
            },
            registerDirectlyBlock: { [weak self] in
                self?.dismiss(animated: true) {
                    self?.presenter?.continueFromSplash()
                }
            },
        )
        self.present(sheet, animated: true)
    }
}

private class RestoreOrTransferPickerController: StackSheetViewController {

    override var placeOnGlassIfAvailable: Bool { false }

    private let setHasOldDeviceBlock: (Bool) -> Void
    private let registerDirectlyBlock: () -> Void
    init(setHasOldDeviceBlock: @escaping (Bool) -> Void, registerDirectlyBlock: @escaping () -> Void) {
        self.setHasOldDeviceBlock = setHasOldDeviceBlock
        self.registerDirectlyBlock = registerDirectlyBlock
        super.init()
    }

    override open var sheetBackgroundColor: UIColor { .Signal.secondaryBackground }

    override func viewDidLoad() {
        super.viewDidLoad()
        stackView.spacing = 16

        if !TSConstants.backupServiceAvailable {
            addTellomiChoices()
            return
        }

        let hasDeviceButton = UIButton.registrationChoiceButton(
            title: OWSLocalizedString(
                "ONBOARDING_SPLASH_HAVE_OLD_DEVICE_TITLE",
                comment: "Title for the 'have my old device' choice of the 'Restore or Transfer' prompt",
            ),
            subtitle: OWSLocalizedString(
                "ONBOARDING_SPLASH_HAVE_OLD_DEVICE_BODY",
                comment: "Explanation of 'have old device' flow for the 'Restore or Transfer' prompt",
            ),
            iconName: "qr-code-48",
            primaryAction: UIAction { [weak self] _ in
                self?.setHasOldDeviceBlock(true)
            },
        )
        stackView.addArrangedSubview(hasDeviceButton)

        let noDeviceButton = UIButton.registrationChoiceButton(
            title: OWSLocalizedString(
                "ONBOARDING_SPLASH_DO_NOT_HAVE_OLD_DEVICE_TITLE",
                comment: "Title for the 'do not have my old device' choice of the 'Restore or Transfer' prompt",
            ),
            subtitle: OWSLocalizedString(
                "ONBOARDING_SPLASH_DO_NOT_HAVE_OLD_DEVICE_BODY",
                comment: "Explanation of 'do not have old device' flow for the 'Restore or Transfer' prompt",
            ),
            iconName: "no-phone-48",
            primaryAction: UIAction { [weak self] _ in
                self?.setHasOldDeviceBlock(false)
            },
        )
        stackView.addArrangedSubview(noDeviceButton)
    }

    /// Tellomi：没有备份服务时，上游「旧手机不在身边」后面只剩走不通的路——「恢复 Tellomi 安全备份」要输恢复密钥，
    /// 而这套部署根本没有备份服务；本地文件备份恢复只在 Debug 包里有（`BuildFlags.LocalFileBackups.restore`）。
    /// 所以这里只列两条真能走通的：旧 iPhone 在身边就扫码直连传输；否则直接注册，并说清以前的聊天记录不会跟过来、
    /// 旧手机上的 Tellomi 也会退出登录（注册时服务端 reclaimAccount 会把旧设备登出；旧机是 Android 时不会有 409 提醒，
    /// 这里不说就没人说了——taishi 审查 b5）（tellomi/tellomi#1216）。
    private func addTellomiChoices() {
        stackView.addArrangedSubview(UIButton.registrationChoiceButton(
            title: OWSLocalizedString(
                "ONBOARDING_SPLASH_TELLOMI_HAVE_OLD_IPHONE_TITLE",
                comment: "Tellomi: Title for the 'my old iPhone is here' choice after tapping 'New phone?' in the 'onboarding splash' view.",
            ),
            subtitle: OWSLocalizedString(
                "ONBOARDING_SPLASH_TELLOMI_HAVE_OLD_IPHONE_BODY",
                comment: "Tellomi: Explanation of the 'my old iPhone is here' choice: scan a QR code with the old iPhone to transfer the account and messages directly.",
            ),
            iconName: "qr-code-48",
            primaryAction: UIAction { [weak self] _ in
                self?.setHasOldDeviceBlock(true)
            },
        ))
        stackView.addArrangedSubview(UIButton.registrationChoiceButton(
            title: OWSLocalizedString(
                "ONBOARDING_SPLASH_TELLOMI_REGISTER_DIRECTLY_TITLE",
                comment: "Tellomi: Title for the choice to register directly (old phone is not at hand, or is an Android phone) after tapping 'New phone?' in the 'onboarding splash' view.",
            ),
            subtitle: OWSLocalizedString(
                "ONBOARDING_SPLASH_TELLOMI_REGISTER_DIRECTLY_BODY",
                comment: "Tellomi: Explanation of the 'register directly' choice: registering works, but earlier messages won't come to this phone and Tellomi on the old phone will be logged out.",
            ),
            iconName: "continue-48",
            primaryAction: UIAction { [weak self] _ in
                self?.registerDirectlyBlock()
            },
        ))
    }
}

// MARK: -

#if DEBUG
private class PreviewRegistrationSplashPresenter: RegistrationSplashPresenter {
    func continueFromSplash() {
        print("continueFromSplash")
    }

    func setHasOldDevice(_ hasOldDevice: Bool) {
        print("setHasOldDevice: \(hasOldDevice)")
    }

    func switchToDeviceLinkingMode() {
        print("switchToDeviceLinkingMode")
    }

    func transferDevice() {
        print("transferDevice")
    }
}

@available(iOS 17, *)
#Preview {
    let presenter = PreviewRegistrationSplashPresenter()
    return RegistrationSplashViewController(presenter: presenter)
}
#endif

// MARK: - Tellomi：开屏轮播

/// Tellomi（owner 2026-09-27，docs/brand/README.md「开屏轮播」）：四张 Open Doodles（Pablo Stanley，CC0）按顺序横向轮播——
/// 荡秋千 → 自拍 → 捧心 → 悬浮。每张停 3 秒后滑到下一张（约 0.35 秒），第 4 张后面接第 1 张；左右可以滑；
/// 手指按住（或拖动）时暂停，松手 3 秒后继续；系统开了「减弱动态效果」就不自动播，只能手动滑。
/// 下面一排小圆点（墨 / 灰，不用 Signal 蓝）。插画是装饰，读屏整块跳过——下面的字标读作「Tellomi」。
///
/// 做法：一个开了分页的 UIScrollView，前后各多放一张（第 4 张、第 1 张的副本），滑过头时无动画地跳回对应的真实页，左右都能无缝接上。
/// Telegram 的开屏（RMIntroViewController）也是分页的 UIScrollView + 不可点的 UIPageControl，但它不自动播、不循环；
/// 自动播、循环、按住暂停是 owner 的要求，这里是独立实现（Telegram 是 GPLv2，一行没搬）。
final class TellomiSplashCarouselView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    static let illustrationNames = [
        "tellomi_splash_swinging",
        "tellomi_splash_selfie",
        "tellomi_splash_loving",
        "tellomi_splash_float",
    ]
    static let autoAdvanceInterval: TimeInterval = 3
    static let slideDuration: TimeInterval = 0.35

    let scrollView = UIScrollView()
    let pageControl = UIPageControl()

    /// 四张真实的页（按顺序）。滚动视图里一共六格：[第 4 张副本, 1, 2, 3, 4, 第 1 张副本]。
    private(set) var pageImageViews: [UIImageView] = []
    private var slotImageViews: [UIImageView] = []
    private(set) var currentPage = 0

    private let isReduceMotionEnabled: () -> Bool
    private var autoAdvanceTimer: Timer?
    private var isTouching = false
    private var isSliding = false
    private var laidOutPageWidth: CGFloat = 0

    /// 下一次自动翻页的时间；nil = 现在不会自动翻（不在屏幕上、手指按着、或开了「减弱动态效果」）。
    var autoAdvanceFireDate: Date? { autoAdvanceTimer?.fireDate }

    /// 滚动视图眼下停在哪张图上（按实际偏移算，不是按 currentPage 推）。
    var visiblePageImage: UIImage? {
        guard laidOutPageWidth > 0 else { return nil }
        let slot = Int((scrollView.contentOffset.x / laidOutPageWidth).rounded())
        return slotImageViews.indices.contains(slot) ? slotImageViews[slot].image : nil
    }

    init(isReduceMotionEnabled: @escaping () -> Bool = { UIAccessibility.isReduceMotionEnabled }) {
        self.isReduceMotionEnabled = isReduceMotionEnabled
        super.init(frame: .zero)

        let names = Self.illustrationNames
        for name in [names[names.count - 1]] + names + [names[0]] {
            let imageView = UIImageView(image: UIImage(named: name))
            imageView.contentMode = .scaleAspectFit
            scrollView.addSubview(imageView)
            slotImageViews.append(imageView)
        }
        pageImageViews = Array(slotImageViews[1...names.count])

        scrollView.isPagingEnabled = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.scrollsToTop = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delegate = self

        // 手指一按下就暂停（不必等到拖动），和滚动视图自己的拖动手势同时识别。
        let touchRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(didTouch(_:)))
        touchRecognizer.minimumPressDuration = 0
        touchRecognizer.allowableMovement = .greatestFiniteMagnitude
        touchRecognizer.cancelsTouchesInView = false
        touchRecognizer.delegate = self
        scrollView.addGestureRecognizer(touchRecognizer)

        pageControl.numberOfPages = names.count
        pageControl.currentPage = 0
        pageControl.hidesForSinglePage = true
        pageControl.isUserInteractionEnabled = false
        pageControl.currentPageIndicatorTintColor = .Signal.label
        pageControl.pageIndicatorTintColor = .Signal.tertiaryLabel

        addSubview(scrollView)
        addSubview(pageControl)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        pageControl.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            pageControl.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 8),
            pageControl.centerXAnchor.constraint(equalTo: centerXAnchor),
            pageControl.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // 插画和圆点都是装饰；页面读字标「Tellomi」。
        accessibilityElementsHidden = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reduceMotionStatusDidChange),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil,
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        owsFail("Not implemented")
    }

    deinit {
        autoAdvanceTimer?.invalidate()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let pageSize = scrollView.bounds.size
        guard pageSize.width > 0 else { return }
        for (slot, imageView) in slotImageViews.enumerated() {
            imageView.frame = CGRect(x: CGFloat(slot) * pageSize.width, y: 0, width: pageSize.width, height: pageSize.height)
        }
        scrollView.contentSize = CGSize(width: CGFloat(slotImageViews.count) * pageSize.width, height: pageSize.height)
        // 尺寸变了（第一次排版、转屏）才把偏移对回当前页；滑动 / 拖动中不碰。
        if pageSize.width != laidOutPageWidth, !isSliding, !scrollView.isDragging, !scrollView.isDecelerating {
            laidOutPageWidth = pageSize.width
            scrollView.contentOffset = CGPoint(x: CGFloat(currentPage + 1) * pageSize.width, y: 0)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // 只在屏幕上时自动播（推到号码页后开屏离开窗口，计时器跟着停）。
        scheduleAutoAdvance()
    }

    // MARK: 翻页

    func showNextPage(animated: Bool) {
        let pageWidth = scrollView.bounds.width
        let targetSlot = currentPage + 2
        currentPage = (currentPage + 1) % Self.illustrationNames.count
        pageControl.currentPage = currentPage
        guard animated, pageWidth > 0 else {
            scrollView.contentOffset = CGPoint(x: CGFloat(currentPage + 1) * pageWidth, y: 0)
            return
        }
        isSliding = true
        UIView.animate(
            withDuration: Self.slideDuration,
            delay: 0,
            options: [.curveEaseInOut, .allowUserInteraction],
            animations: {
                self.scrollView.contentOffset = CGPoint(x: CGFloat(targetSlot) * pageWidth, y: 0)
            },
            completion: { _ in
                self.isSliding = false
                self.settleOnCurrentPage()
                self.scheduleAutoAdvance()
            },
        )
    }

    /// 停在副本格上时无动画地跳回对应的真实页。
    private func settleOnCurrentPage() {
        let pageWidth = scrollView.bounds.width
        guard pageWidth > 0 else { return }
        scrollView.contentOffset = CGPoint(x: CGFloat(currentPage + 1) * pageWidth, y: 0)
        pageControl.currentPage = currentPage
    }

    // MARK: 自动播

    private func scheduleAutoAdvance() {
        autoAdvanceTimer?.invalidate()
        autoAdvanceTimer = nil
        guard window != nil, !isTouching, !isReduceMotionEnabled() else { return }
        autoAdvanceTimer = Timer.scheduledTimer(withTimeInterval: Self.autoAdvanceInterval, repeats: false) { [weak self] _ in
            self?.autoAdvanceTimerDidFire()
        }
    }

    private func autoAdvanceTimerDidFire() {
        autoAdvanceTimer = nil
        guard !isTouching, !scrollView.isDragging, !scrollView.isDecelerating, !isSliding else {
            scheduleAutoAdvance()
            return
        }
        showNextPage(animated: true)
    }

    func userInteractionBegan() {
        isTouching = true
        autoAdvanceTimer?.invalidate()
        autoAdvanceTimer = nil
    }

    func userInteractionEnded() {
        isTouching = false
        scheduleAutoAdvance()
    }

    @objc
    private func didTouch(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            userInteractionBegan()
        case .ended, .cancelled, .failed:
            userInteractionEnded()
        default:
            break
        }
    }

    @objc
    private func reduceMotionStatusDidChange() {
        scheduleAutoAdvance()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    // MARK: UIScrollViewDelegate

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        userInteractionBegan()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            updateCurrentPageFromOffset()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        updateCurrentPageFromOffset()
    }

    /// 用户滑完以后按停下的格子算出第几张（副本格对应第 4 / 第 1 张），再对回真实页。
    private func updateCurrentPageFromOffset() {
        let pageWidth = scrollView.bounds.width
        guard pageWidth > 0 else { return }
        let slot = Int((scrollView.contentOffset.x / pageWidth).rounded())
        let count = Self.illustrationNames.count
        currentPage = ((slot - 1) % count + count) % count
        settleOnCurrentPage()
    }
}
