//
// Copyright 2021 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

protocol GetStartedBannerViewControllerDelegate: AnyObject {
    func getStartedBannerDidTapInviteFriends(_ banner: GetStartedBannerViewController)
    func getStartedBannerDidTapCreateGroup(_ banner: GetStartedBannerViewController)
    func getStartedBannerDidTapAppearance(_ banner: GetStartedBannerViewController)
    func getStartedBannerDidDismissAllCards(_ banner: GetStartedBannerViewController, animated: Bool)
    func getStartedBannerDidTapAvatarBuilder(_ banner: GetStartedBannerViewController)
    // Tellomi（tellomi/tellomi#1218 F-02）：找朋友三条路里的前两条
    func getStartedBannerDidTapFindByUsername(_ banner: GetStartedBannerViewController)
    func getStartedBannerDidTapMyQRCode(_ banner: GetStartedBannerViewController)
}

// Tellomi：去掉 private，单测要读卡片顺序（TellomiGetStartedTest）
struct GetStartedCard: Hashable {
    var identifier: String // this is persisted to the db
    var title: String
    var image: UIImage?
    var tintColor: UIColor?

    private init(identifier: String, title: String, image: UIImage? = nil, tintColor: UIColor? = nil) {
        self.identifier = identifier
        self.title = title
        self.image = image
        self.tintColor = tintColor
    }

    static let newGroup = GetStartedCard(
        identifier: "newGroup",
        title: OWSLocalizedString(
            "GET_STARTED_CARD_NEW_GROUP",
            comment: "'Get Started' button directing users to create a group",
        ),
        image: UIImage(named: "group-resizable"),
        tintColor: UIColor(
            light: UIColor(rgbHex: 0xF6EDE0, alpha: 0.6),
            dark: UIColor(rgbHex: 0xD7BFA9, alpha: 0.4),
        ),
    )
    static let inviteFriends = GetStartedCard(
        identifier: "inviteFriends",
        title: OWSLocalizedString(
            "GET_STARTED_CARD_INVITE_FRIENDS",
            comment: "'Get Started' button directing users to invite friends",
        ),
        image: UIImage(named: "invite-resizable"),
        tintColor: UIColor(
            light: UIColor(rgbHex: 0xDEE5D6, alpha: 0.6),
            dark: UIColor(rgbHex: 0x95B373, alpha: 0.4),
        ),
    )
    static let avatarBuilder = GetStartedCard(
        identifier: "avatarBuilder",
        title: OWSLocalizedString(
            "GET_STARTED_CARD_AVATAR_BUILDER",
            comment: "'Get Started' button direction users to avatar builder",
        ),
        image: UIImage(named: "person-resizable"),
        tintColor: UIColor(
            light: UIColor(rgbHex: 0xE5DBE7, alpha: 0.6),
            dark: UIColor(rgbHex: 0xCE85DD, alpha: 0.4),
        ),
    )
    static let appearance = GetStartedCard(
        identifier: "appearance",
        title: OWSLocalizedString(
            "GET_STARTED_CARD_CHAT_COLOR",
            comment: "'Get Started' button directing users to Chat Color settings",
        ),
        image: UIImage(named: "color-resizable"),
        tintColor: UIColor(
            light: UIColor(rgbHex: 0xD6E5E5, alpha: 0.6),
            dark: UIColor(rgbHex: 0x8ACECE, alpha: 0.4),
        ),
    )

    // Tellomi（tellomi/tellomi#1218 F-02）：没有 CDSI，用户名、二维码、邀请是别人找到你的全部办法
    static let findByUsername = GetStartedCard(
        identifier: "tellomi.findByUsername",
        title: OWSLocalizedString(
            "GET_STARTED_CARD_FIND_BY_USERNAME_TELLOMI",
            comment: "'Get Started' button directing users to find someone by their username",
        ),
        image: UIImage(named: "search-resizable"),
        tintColor: UIColor(
            light: UIColor(rgbHex: 0xF6EDE0, alpha: 0.6),
            dark: UIColor(rgbHex: 0xD7BFA9, alpha: 0.4),
        ),
    )
    static let myQRCode = GetStartedCard(
        identifier: "tellomi.myQRCode",
        title: OWSLocalizedString(
            "GET_STARTED_CARD_MY_QR_CODE_TELLOMI",
            comment: "'Get Started' button directing users to their own username QR code",
        ),
        image: UIImage(named: "qr_code-resizable"),
        tintColor: UIColor(
            light: UIColor(rgbHex: 0xD6E5E5, alpha: 0.6),
            dark: UIColor(rgbHex: 0x8ACECE, alpha: 0.4),
        ),
    )

    // Tellomi（tellomi/tellomi#1218 F-02、第 5 条）：搜索用户名 / 我的二维码 / 邀请朋友 + 设头像。
    // 上游的「新建群组」「聊天颜色」不出：新用户还没有可以拉进群的人，聊天颜色不是上手必需。
    static let all: [GetStartedCard] = [
        findByUsername,
        myQRCode,
        inviteFriends,
        avatarBuilder,
    ]

    /// 找朋友三条路：出现第一个真人会话后一起收起，设头像留着。
    static let findFriends: [GetStartedCard] = [
        findByUsername,
        myQRCode,
        inviteFriends,
    ]

    func hash(into hasher: inout Hasher) {
        hasher.combine(identifier)
    }
}

private enum Section: Hashable {
    case main
}

private struct GetStartedCardCellContentConfiguration: UIContentConfiguration {

    var card: GetStartedCard

    func makeContentView() -> UIView & UIContentView {
        return GetStartedCardCellContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> Self {
        return self
    }
}

private class GetStartedCardCellContentView: UIView, UIContentView {

    var configuration: any UIContentConfiguration {
        didSet {
            apply(configuration: configuration)
        }
    }

    var closeAction: (() -> Void)?

    private var imageView: UIImageView = {
        let imageView = UIImageView()
        imageView.tintColor = .Signal.label
        imageView.contentMode = .scaleAspectFit
        return imageView
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.numberOfLines = 3
        label.textAlignment = .center
        label.textColor = .Signal.label
        return label
    }()

    private lazy var closeButton: UIButton = {
        let button = UIButton(
            configuration: .plain(),
            primaryAction: UIAction { [weak self] _ in
                self?.closeButtonTapped()
            },
        )
        button.configuration?.image = UIImage(named: "x-20-bold")
        button.configuration?.contentInsets = .init(margin: 12)
        button.tintColor = .Signal.secondaryLabel
        return button
    }()

    // UIView on pre-iOS 26
    // UIVisualEffectView on iOS 26+
    private var backgroundView: UIView?

    private static let cornerRadius: CGFloat = if #available(iOS 26, *) { 26 } else { 12 }

    private static let closeAccessibilityLabel = OWSLocalizedString(
        "GET_STARTED_CARD_CLOSE_A11YLABEL",
        comment: "Accessibility label for the close button in each Get Started card.",
    )

    init(configuration: GetStartedCardCellContentConfiguration) {
        self.configuration = configuration

        super.init(frame: .zero)

        // Colored background
        let contentView: UIView
        if #available(iOS 26, *) {
            let glassEffect = UIGlassEffect(style: .regular)
            glassEffect.tintColor = configuration.card.tintColor
            let glassEffectView = UIVisualEffectView(effect: glassEffect)
            glassEffectView.clipsToBounds = true
            glassEffectView.cornerConfiguration = .uniformCorners(radius: .fixed(Self.cornerRadius))

            contentView = glassEffectView.contentView
            backgroundView = glassEffectView
        } else {
            // Outer shadow
            layer.shadowOffset = CGSize(width: 0, height: 2)
            layer.shadowRadius = 4
            layer.shadowOpacity = 0.12
            updateOuterShadowColor()

            let backgroundView = UIView()
            backgroundView.layer.masksToBounds = true
            backgroundView.layer.cornerRadius = Self.cornerRadius
            updateBackgroundColor(using: configuration.card)

            contentView = backgroundView
            self.backgroundView = backgroundView
        }
        addSubview(backgroundView!)

        // Content
        let vStack = UIStackView(arrangedSubviews: [imageView, titleLabel])
        vStack.axis = .vertical
        vStack.alignment = .center
        vStack.spacing = 4
        vStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(vStack)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(closeButton)

        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 28),
            imageView.heightAnchor.constraint(equalToConstant: 28),

            vStack.topAnchor.constraint(greaterThanOrEqualTo: layoutMarginsGuide.topAnchor),
            vStack.centerYAnchor.constraint(equalTo: layoutMarginsGuide.centerYAnchor),
            vStack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            vStack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),

            closeButton.topAnchor.constraint(equalTo: topAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        titleLabel.font = .dynamicTypeFootnote.semibold()
        if #available(iOS 17, *) {
            titleLabel.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (label: UILabel, _) in
                label.font = .dynamicTypeFootnote.semibold()
            }
        }

        isAccessibilityElement = true
        accessibilityTraits.insert(.button)
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: Self.closeAccessibilityLabel, actionHandler: { [weak self] _ in
            self?.closeButtonTapped()
            return true
        })]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        // Full-size views
        if let backgroundView {
            backgroundView.frame = bounds
        }

        // Outer shadow
        if #unavailable(iOS 26) {
            let shadowPath = UIBezierPath(
                roundedRect: layer.bounds,
                cornerRadius: Self.cornerRadius,
            ).cgPath
            layer.shadowPath = shadowPath
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if #unavailable(iOS 26), previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            if let config = configuration as? GetStartedCardCellContentConfiguration {
                updateBackgroundColor(using: config.card)
            }
            updateOuterShadowColor()
        }
    }

    @available(iOS, deprecated: 26)
    private func updateBackgroundColor(using card: GetStartedCard) {
        guard let backgroundView else { return }
        // `tintColors` are not opaque and would cause this view's shadow to be visible along the top edge.
        // The workaround is to resolve this semi-opaque tint color as an overlay over opaque background color.
        let baseBackgroundColor = UIColor.Signal.background.resolvedColor(with: traitCollection)
        let overlayColor = card.tintColor?.resolvedColor(with: traitCollection)
        backgroundView.backgroundColor = overlayColor?.overlaidOpaque(on: baseBackgroundColor)
    }

    @available(iOS, deprecated: 26)
    private func updateOuterShadowColor() {
        if traitCollection.userInterfaceStyle == .dark {
            layer.shadowColor = UIColor.white.cgColor
        } else {
            layer.shadowColor = UIColor.black.cgColor
        }
    }

    func apply(configuration: UIContentConfiguration) {
        guard let config = configuration as? GetStartedCardCellContentConfiguration else { return }
        imageView.image = config.card.image
        titleLabel.text = config.card.title
        if
            #available(iOS 26, *),
            let visualEffectView = backgroundView as? UIVisualEffectView,
            let glassEffect = visualEffectView.effect as? UIGlassEffect
        {
            glassEffect.tintColor = config.card.tintColor
        } else {
            updateBackgroundColor(using: config.card)
        }

        accessibilityLabel = config.card.title
    }

    private func closeButtonTapped() {
        closeAction?()
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }
}

class GetStartedBannerViewController: OWSViewController {

    // MARK: - Views

    private let header: UILabel = {
        let label = UILabel()
        label.textColor = .Signal.label
        label.font = UIFont.dynamicTypeHeadlineClamped
        label.adjustsFontForContentSizeCategory = true
        label.text = OWSLocalizedString(
            "GET_STARTED_BANNER_TITLE",
            comment: "Title for the 'Get Started' banner",
        )
        label.accessibilityTraits.insert(.header)
        return label
    }()

    private lazy var collectionView: UICollectionView = {
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .absolute(156),
            heightDimension: .absolute(98),
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)

        let groupSize = itemSize
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])

        let section = NSCollectionLayoutSection(group: group)
        section.orthogonalScrollingBehavior = .continuous
        section.interGroupSpacing = 12
        section.contentInsets = .zero

        let layout = UICollectionViewCompositionalLayout(section: section)
        layout.configuration.contentInsetsReference = .layoutMargins

        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.delegate = self
        collectionView.backgroundColor = .clear
        collectionView.clipsToBounds = false
        collectionView.alwaysBounceHorizontal = true
        collectionView.alwaysBounceVertical = false
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.preservesSuperviewLayoutMargins = true
        return collectionView
    }()

    private lazy var gradientBackground: GradientView = {
        let gradient = GradientView(colors: [])
        gradient.isUserInteractionEnabled = false
        return gradient
    }()

    private lazy var opaqueBackground: UIView = {
        let view = UIView()
        view.backgroundColor = .Signal.background
        return view
    }()

    private static let collectionViewCellSize = CGSize(width: 156, height: 98)

    private var dataSource: UICollectionViewDiffableDataSource<Section, GetStartedCard>!

    var opaqueHeight: CGFloat {
        view.height - view.layoutMargins.bottom - gradientBackground.height / 2
    }

    // MARK: - Data

    var hasIncompleteCards: Bool { bannerContent.count > 0 }

    private weak var delegate: GetStartedBannerViewControllerDelegate?
    private let threadFinder = ThreadFinder()
    private(set) var bannerContent: [GetStartedCard] = []

    // MARK: - Lifecycle

    init(delegate: GetStartedBannerViewControllerDelegate) {
        self.delegate = delegate

        super.init()

        bannerContent = fetchContent()

        DependenciesBridge.shared.databaseChangeObserver.appendDatabaseChangeDelegate(self)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = PassthroughView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Layout.
        view.layoutMargins = UIEdgeInsets(top: 0, leading: 8, bottom: 20, trailing: 8)

        view.addSubview(gradientBackground)
        gradientBackground.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(opaqueBackground)
        opaqueBackground.translatesAutoresizingMaskIntoConstraints = false

        if #available(iOS 26, *) {
            let glassContainerView = UIVisualEffectView(effect: UIGlassContainerEffect())
            view.addSubview(glassContainerView)
            glassContainerView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                glassContainerView.topAnchor.constraint(equalTo: view.topAnchor),
                glassContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                glassContainerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                glassContainerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])

            glassContainerView.contentView.addSubview(header)
            glassContainerView.contentView.addSubview(collectionView)
        } else {
            view.addSubview(header)
            view.addSubview(collectionView)
        }

        header.translatesAutoresizingMaskIntoConstraints = false
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            gradientBackground.topAnchor.constraint(equalTo: view.topAnchor),
            gradientBackground.heightAnchor.constraint(equalToConstant: 40),
            gradientBackground.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            gradientBackground.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            opaqueBackground.topAnchor.constraint(equalTo: gradientBackground.bottomAnchor),
            opaqueBackground.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            opaqueBackground.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            opaqueBackground.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            header.topAnchor.constraint(equalTo: opaqueBackground.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            header.trailingAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor),

            collectionView.heightAnchor.constraint(equalToConstant: 98),
            collectionView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            collectionView.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.layoutMarginsGuide.bottomAnchor),
        ])

        // Configure collection view.
        let cellRegistration = UICollectionView.CellRegistration<UICollectionViewCell, GetStartedCard> { cell, indexPath, card in
            cell.contentConfiguration = GetStartedCardCellContentConfiguration(card: card)
        }
        dataSource = UICollectionViewDiffableDataSource<Section, GetStartedCard>(collectionView: collectionView) { [self] collectionView, indexPath, card in
            let cell = collectionView.dequeueConfiguredReusableCell(
                using: cellRegistration,
                for: indexPath,
                item: card,
            )
            if let contentView = cell.contentView as? GetStartedCardCellContentView {
                contentView.closeAction = { [weak self] in
                    self?.didTapClose(card)
                }
            }
            return cell
        }

        // Apply initial cards.
        var snapshot = NSDiffableDataSourceSnapshot<Section, GetStartedCard>()
        snapshot.appendSections([.main])
        snapshot.appendItems(bannerContent, toSection: .main)
        dataSource.apply(snapshot, animatingDifferences: false)

        // Register for notifications.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(activeCardsDidChange),
            name: Self.activeCardsDidChange,
            object: nil,
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(localProfileDidChange),
            name: UserProfileNotifications.localProfileDidChange,
            object: nil,
        )

        updateGradientColors()
    }

    private func fetchContent() -> [GetStartedCard] {
        SSKEnvironment.shared.databaseStorageRef.read { readTx -> [GetStartedCard] in
            var activeCards = Self.getActiveCards(readTx: readTx)

            if activeCards.isEmpty {
                return []
            }

            let unarchivedThreadCount = self.threadFinder.visibleThreadCount(isArchived: false, transaction: readTx)
            let archivedThreadCount = self.threadFinder.visibleThreadCount(isArchived: true, transaction: readTx)
            let visibleThreadCount = unarchivedThreadCount + archivedThreadCount

            // If we have five or more threads, dismiss all cards
            if visibleThreadCount >= 5 {
                Logger.info("User has more than five threads. Dismissing Get Started banner.")
                SSKEnvironment.shared.databaseStorageRef.asyncWrite { writeTx in
                    Self.dismissAllCards(writeTx: writeTx)
                }
                return []
            }

            // Tellomi（tellomi/tellomi#1218 F-02）：有了第一个真人会话，找朋友三条路一起收起，设头像留着。
            // 横幅订阅了线程变化（databaseChangesDidUpdate），所以正看着列表时来了第一个真人消息，卡片当场收起。
            if
                activeCards.contains(where: GetStartedCard.findFriends.contains),
                TellomiGetStarted.hasRealConversation(threadFinder: self.threadFinder, tx: readTx)
            {
                SSKEnvironment.shared.databaseStorageRef.asyncWrite { writeTx in
                    GetStartedCard.findFriends.forEach { Self.completeCard($0, writeTx: writeTx) }
                }
                activeCards.removeAll(where: GetStartedCard.findFriends.contains)
            }

            // Once you have an avatar, don't show the avatar builder card.
            if
                activeCards.contains(.avatarBuilder),
                SSKEnvironment.shared.profileManagerRef.localUserProfile(tx: readTx)?.loadAvatarData() != nil
            {
                SSKEnvironment.shared.databaseStorageRef.asyncWrite { writeTx in
                    Self.completeCard(.avatarBuilder, writeTx: writeTx)
                }
                activeCards.removeAll(where: { $0 == .avatarBuilder })
            }

            return activeCards
        }
    }

    private func updateContent() {
        let newContent = fetchContent()
        guard isViewLoaded else {
            bannerContent = newContent
            return
        }

        var snapshot = NSDiffableDataSourceSnapshot<Section, GetStartedCard>()
        snapshot.appendSections([.main])
        snapshot.appendItems(newContent, toSection: .main)
        dataSource.apply(snapshot, animatingDifferences: true)

        bannerContent = newContent

        if bannerContent.isEmpty {
            delegate?.getStartedBannerDidDismissAllCards(self, animated: true)
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            updateGradientColors()
        }
    }

    private func updateGradientColors() {
        let backgroundColor = UIColor.Signal.background.resolvedColor(with: traitCollection)
        gradientBackground.colors = [backgroundColor.withAlphaComponent(0), backgroundColor]
    }
}

// MARK: - Actions

extension GetStartedBannerViewController: UICollectionViewDelegate {

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let card = dataSource.itemIdentifier(for: indexPath) else { return }

        switch card {
        case .inviteFriends:
            delegate?.getStartedBannerDidTapInviteFriends(self)
        case .newGroup:
            delegate?.getStartedBannerDidTapCreateGroup(self)
        case .appearance:
            delegate?.getStartedBannerDidTapAppearance(self)
        case .avatarBuilder:
            delegate?.getStartedBannerDidTapAvatarBuilder(self)
        case .findByUsername:
            delegate?.getStartedBannerDidTapFindByUsername(self)
        case .myQRCode:
            delegate?.getStartedBannerDidTapMyQRCode(self)
        default:
            break
        }
    }

    fileprivate func didTapClose(_ card: GetStartedCard) {
        SSKEnvironment.shared.databaseStorageRef.asyncWrite { writeTx in
            Self.completeCard(card, writeTx: writeTx)
        }
    }
}

// MARK: - Storage

extension GetStartedBannerViewController {

    private static let activeCardsDidChange = NSNotification.Name("ActiveBannerCardsDidChange")
    private static let keyValueStore = NewKeyValueStore(collection: "GetStartedBannerViewController")
    private static let completePrefix = "ActiveCard."

    static func enableAllCards(writeTx: DBWriteTransaction) {
        var didChange = false

        GetStartedCard.all.forEach { card in
            let key = completePrefix + card.identifier

            let isActive = keyValueStore.fetchValue(Bool.self, forKey: key, tx: writeTx) ?? false
            guard !isActive else {
                // Card already active.
                return
            }

            Self.keyValueStore.writeValue(true, forKey: key, tx: writeTx)
            didChange = true
        }

        guard didChange else {
            return
        }

        writeTx.addSyncCompletion {
            NotificationCenter.default.postOnMainThread(name: activeCardsDidChange, object: nil)
        }
    }

    private static func getActiveCards(readTx: DBReadTransaction) -> [GetStartedCard] {
        GetStartedCard.all.filter { entry in
            let key = completePrefix + entry.identifier
            let isActive = keyValueStore.fetchValue(Bool.self, forKey: key, tx: readTx) ?? false
            return isActive
        }
    }

    static func dismissAllCards(writeTx: DBWriteTransaction) {
        var didChange = false

        GetStartedCard.all.forEach { card in
            let key = completePrefix + card.identifier

            let isActive = keyValueStore.fetchValue(Bool.self, forKey: key, tx: writeTx) ?? false
            guard isActive else {
                // Card not active.
                return
            }

            Self.keyValueStore.removeValue(forKey: key, tx: writeTx)
            didChange = true
        }

        guard didChange else {
            return
        }

        writeTx.addSyncCompletion {
            NotificationCenter.default.postOnMainThread(name: activeCardsDidChange, object: nil)
        }
    }

    private static func completeCard(_ model: GetStartedCard, writeTx: DBWriteTransaction) {
        let key = Self.completePrefix + model.identifier

        let isActive = keyValueStore.fetchValue(Bool.self, forKey: key, tx: writeTx) ?? false
        guard isActive else {
            // Card not active.
            return
        }

        Self.keyValueStore.removeValue(forKey: key, tx: writeTx)

        writeTx.addSyncCompletion {
            NotificationCenter.default.postOnMainThread(name: activeCardsDidChange, object: nil)
        }
    }
}

// MARK: - Database Observation

extension GetStartedBannerViewController: DatabaseChangeDelegate {

    func databaseChangesDidUpdate(databaseChanges: DatabaseChanges) {
        if databaseChanges.didUpdateThreads {
            updateContent()
        }
    }

    func databaseChangesDidUpdateExternally() {
        updateContent()
    }

    func databaseChangesDidReset() {
        updateContent()
    }

    @objc
    private func activeCardsDidChange() {
        AssertIsOnMainThread()
        updateContent()
    }

    @objc
    private func localProfileDidChange() {
        AssertIsOnMainThread()
        updateContent()
    }
}

// MARK: - Tellomi

/// Tellomi（tellomi/tellomi#1218 F-02）：首屏「开始使用」里的找朋友三条路，在出现第一个真人会话后收起。
enum TellomiGetStarted {
    /// 真人会话 = 不是「笔记」（自己）、也不是官方账号（release notes）的会话；消息请求也算——对方是个真人。
    static func isRealConversation(_ thread: TSThread) -> Bool {
        return !thread.isNoteToSelf && !(thread is TSReleaseNotesThread)
    }

    /// 只在找朋友的卡还在时才会被调用；上游在可见会话到 5 个时就收起整个横幅，所以这里最多扫几个会话。
    static func hasRealConversation(threadFinder: ThreadFinder, tx: DBReadTransaction) -> Bool {
        var found = false
        for isArchived in [false, true] where !found {
            threadFinder.enumerateVisibleThreads(isArchived: isArchived, transaction: tx) { thread in
                if !found, isRealConversation(thread) {
                    found = true
                }
            }
        }
        return found
    }
}

// Wrapper view for a collection of interactable subviews
// Will not return a positive hit test result for itself
class PassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let result = super.hitTest(point, with: event)
        return result != self ? result : nil
    }
}
