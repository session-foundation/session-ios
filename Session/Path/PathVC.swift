// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Combine
import NVActivityIndicatorView
import SessionMessagingKit
import SessionUIKit
import SessionNetworkingKit
import SessionUtilitiesKit

final class PathVC: BaseVC {
    public static let dotSize: CGFloat = 8
    public static let expandedDotSize: CGFloat = 16
    private static let rowHeight: CGFloat = (isIPhone5OrSmaller ? 52 : 75)
    
    private let dependencies: Dependencies
    private var statusObservationTask: Task<Void, Never>?

    // MARK: - Components
    
    private lazy var pathStackView: UIStackView = {
        let result = UIStackView()
        result.axis = .vertical
        
        return result
    }()

    private let spinner: NVActivityIndicatorView = {
        let result: NVActivityIndicatorView = NVActivityIndicatorView(
            frame: CGRect.zero,
            type: .circleStrokeSpin,
            color: .black,
            padding: nil
        )
        result.set(.width, to: 64)
        result.set(.height, to: 64)
        
        ThemeManager.onThemeChange(observer: result) { [weak result] _, _, resolve in
            guard let textPrimary: UIColor = resolve(.textPrimary) else { return }
            
            result?.color = textPrimary
        }
        
        return result
    }()

    private lazy var learnMoreButton: SessionButton = {
        let result = SessionButton(style: .bordered, size: .large)
        result.setTitle("learnMore".localized(), for: UIControl.State.normal)
        result.addTarget(self, action: #selector(learnMore), for: UIControl.Event.touchUpInside)
        
        return result
    }()

    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        statusObservationTask?.cancel()
    }
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        setUpNavBar()
        setUpViewHierarchy()
        startObservingNetwork()
    }

    private func setUpNavBar() {
        setNavBarTitle("onionRoutingPath".localized())
    }

    private func setUpViewHierarchy() {
        // Set up explanation label
        let explanationLabel = UILabel()
        explanationLabel.font = .systemFont(ofSize: Values.smallFontSize)
        explanationLabel.text = "onionRoutingPathDescription"
            .put(key: "app_name", value: Constants.app_name)
            .localized()
        explanationLabel.themeTextColor = .textSecondary
        explanationLabel.textAlignment = .center
        explanationLabel.lineBreakMode = .byWordWrapping
        explanationLabel.numberOfLines = 0
        
        // Set up path stack view
        let pathStackViewContainer = UIView()
        pathStackViewContainer.addSubview(pathStackView)
        pathStackView.pin([ UIView.VerticalEdge.top, UIView.VerticalEdge.bottom ], to: pathStackViewContainer)
        pathStackView.center(in: pathStackViewContainer)
        pathStackView.leadingAnchor.constraint(greaterThanOrEqualTo: pathStackViewContainer.leadingAnchor).isActive = true
        pathStackViewContainer.trailingAnchor.constraint(greaterThanOrEqualTo: pathStackView.trailingAnchor).isActive = true
        pathStackViewContainer.addSubview(spinner)
        spinner.leadingAnchor.constraint(greaterThanOrEqualTo: pathStackViewContainer.leadingAnchor).isActive = true
        spinner.topAnchor.constraint(greaterThanOrEqualTo: pathStackViewContainer.topAnchor).isActive = true
        pathStackViewContainer.trailingAnchor.constraint(greaterThanOrEqualTo: spinner.trailingAnchor).isActive = true
        pathStackViewContainer.bottomAnchor.constraint(greaterThanOrEqualTo: spinner.bottomAnchor).isActive = true
        spinner.center(in: pathStackViewContainer)
        
        // Set up rebuild path button
        let inset: CGFloat = isIPhone5OrSmaller ? 64 : 80
        let learnMoreButtonContainer = UIView(wrapping: learnMoreButton, withInsets: UIEdgeInsets(top: 0, leading: inset, bottom: 0, trailing: inset), shouldAdaptForIPadWithWidth: Values.iPadButtonWidth)
        
        // Set up spacers
        let topSpacer = UIView.vStretchingSpacer()
        let bottomSpacer = UIView.vStretchingSpacer()
        
        // Set up main stack view
        let mainStackView = UIStackView(arrangedSubviews: [ explanationLabel, topSpacer, pathStackViewContainer, bottomSpacer, learnMoreButtonContainer ])
        mainStackView.axis = .vertical
        mainStackView.alignment = .fill
        mainStackView.layoutMargins = UIEdgeInsets(
            top: Values.largeSpacing,
            left: Values.largeSpacing,
            bottom: Values.smallSpacing,
            right: Values.largeSpacing
        )
        mainStackView.isLayoutMarginsRelativeArrangement = true
        view.addSubview(mainStackView)
        mainStackView.pin(to: view)
        
        // Set up spacer constraints
        topSpacer.heightAnchor.constraint(equalTo: bottomSpacer.heightAnchor).isActive = true
    }

    // MARK: - Updating
    
    private func startObservingNetwork() {
        statusObservationTask?.cancel()
        statusObservationTask = Task { [weak self, dependencies] in
            var specificNetworkObservationTask: Task<Void, Never>?
            
            for await network in dependencies.stream(singleton: .network) {
                specificNetworkObservationTask?.cancel()
                specificNetworkObservationTask = Task<Void, Never> {
                    for await _ in network.networkStatus {
                        await self?.loadPathsAsync()
                    }
                    
                    Log.info("PathVC networkStatus observation ended, restarting.")
                }
            }
        }
    }
    
    private func loadPathsAsync() async {
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        
        guard
            let currentUserSwarmPubkeys: Set<String> = try? await Set(dependencies[singleton: .network]
                .getSwarm(for: userSessionId.hexString)
                .map { $0.ed25519PubkeyHex }),
            let paths: [LibSession.Path] = try? await dependencies[singleton: .network].getActivePaths(),
            let targetPath: LibSession.Path = paths
                /// Sanity check to make sure the sorting doesn't crash
                .filter({ !$0.nodes.isEmpty })
                /// Deterministic ordering
                .sorted(by: { $0.nodes[0].ed25519PubkeyHex < $1.nodes[0].ed25519PubkeyHex })
                .first(where: { path in
                    switch path.category {
                        case .standard: return true
                        case .download, .upload: return false
                        case .none:
                            guard let pubkey: String = path.destinationPubkey else {
                                return false
                            }
                            
                            return currentUserSwarmPubkeys.contains(pubkey)
                    }
                })
        else {
            self.update(path: nil, force: true)
            return
        }
        
        self.update(path: targetPath, force: true)
    }
    
    @MainActor private func update(path: LibSession.Path?, force: Bool) {
        guard let pathToDisplay: LibSession.Path = path else {
            pathStackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
            spinner.startAnimating()
            
            UIView.animate(withDuration: 0.25) {
                self.spinner.alpha = 1
            }
            return
        }
        
        // Cache the path that was used to avoid recreating the UI if not needed
        pathStackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        
        let dotAnimationRepeatInterval = Double(pathToDisplay.nodes.count) + 2
        let snodeRows: [UIStackView] = pathToDisplay.nodes.enumerated().map { index, snode in
            let isGuardSnode = (snode == pathToDisplay.nodes.first)
            
            return getPathRow(
                title: (isGuardSnode ?
                    "onionRoutingPathEntryNode".localized() :
                    "onionRoutingPathServiceNode".localized()
                ),
                subtitleResolver: { [ip2Country = dependencies[singleton: .ip2Country]] in
                    try? await Task.sleep(for: .seconds(5), checkingEvery: .milliseconds(100)) {
                        await ip2Country.isLoaded
                    }
                    
                    return await ip2Country.country(for: snode.ip)
                },
                location: .middle,
                dotAnimationStartDelay: Double(index) + 2,
                dotAnimationRepeatInterval: dotAnimationRepeatInterval
            )
        }
        
        let youRow = getPathRow(
            title: "you".localized(),
            subtitleResolver: nil,
            location: .top,
            dotAnimationStartDelay: 1,
            dotAnimationRepeatInterval: dotAnimationRepeatInterval
        )
        let destinationRow = getPathRow(
            title: "onionRoutingPathDestination".localized(),
            subtitleResolver: nil,
            location: .bottom,
            dotAnimationStartDelay: Double(pathToDisplay.nodes.count) + 2,
            dotAnimationRepeatInterval: dotAnimationRepeatInterval
        )
        let rows = [ youRow ] + snodeRows + [ destinationRow ]
        rows.forEach { pathStackView.addArrangedSubview($0) }
        spinner.stopAnimating()
        
        UIView.animate(withDuration: 0.25) {
            self.spinner.alpha = 0
        }
    }

    // MARK: - General
    
    private func getPathRow(
        title: String,
        subtitleResolver: (() async -> String)?,
        location: LineView.Location,
        dotAnimationStartDelay: Double,
        dotAnimationRepeatInterval: Double
    ) -> UIStackView {
        let lineView = LineView(
            location: location,
            dotAnimationStartDelay: dotAnimationStartDelay,
            dotAnimationRepeatInterval: dotAnimationRepeatInterval,
            using: dependencies
        )
        lineView.set(.width, to: PathVC.expandedDotSize)
        lineView.set(.height, to: PathVC.rowHeight)
        
        let titleLabel: UILabel = UILabel()
        titleLabel.font = .systemFont(ofSize: Values.mediumFontSize)
        titleLabel.text = title
        titleLabel.themeTextColor = .textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        
        let titleStackView = UIStackView(arrangedSubviews: [ titleLabel ])
        titleStackView.axis = .vertical
        
        if let subtitleResolver: () async -> String = subtitleResolver {
            let subtitleLabel = UILabel()
            subtitleLabel.font = .systemFont(ofSize: Values.verySmallFontSize)
            subtitleLabel.text = "resolving".localized()
            subtitleLabel.themeTextColor = .textPrimary
            subtitleLabel.lineBreakMode = .byTruncatingTail
            titleStackView.addArrangedSubview(subtitleLabel)
            
            Task { [weak subtitleLabel] in
                subtitleLabel?.text = await subtitleResolver()
            }
        }
        
        let stackView = UIStackView(arrangedSubviews: [ lineView, titleStackView ])
        stackView.axis = .horizontal
        stackView.spacing = Values.largeSpacing
        stackView.alignment = .center
        
        return stackView
    }
    
    // MARK: - Interaction
    
    @objc private func learnMore() {
        let urlAsString = "https://getsession.org/faq/#onion-routing"
        let url = URL(string: urlAsString)!
        UIApplication.shared.open(url)
    }
}

// MARK: - Line View

private final class LineView: UIView {
    private let dependencies: Dependencies
    private let location: Location
    private let dotAnimationStartDelay: Double
    private let dotAnimationRepeatInterval: Double
    private var dotViewWidthConstraint: NSLayoutConstraint!
    private var dotViewHeightConstraint: NSLayoutConstraint!
    private var dotViewAnimationTimer: Timer!
    private var statusObservationTask: Task<Void, Never>?

    enum Location {
        case top, middle, bottom
    }
    
    // MARK: - Initialization
    
    init(location: Location, dotAnimationStartDelay: Double, dotAnimationRepeatInterval: Double, using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.location = location
        self.dotAnimationStartDelay = dotAnimationStartDelay
        self.dotAnimationRepeatInterval = dotAnimationRepeatInterval
        
        super.init(frame: CGRect.zero)
        
        setUpViewHierarchy()
        startObservingNetwork()
    }
    
    override init(frame: CGRect) {
        preconditionFailure("Use init(location:dotAnimationStartDelay:dotAnimationRepeatInterval:) instead.")
    }
    
    required init?(coder: NSCoder) {
        preconditionFailure("Use init(location:dotAnimationStartDelay:dotAnimationRepeatInterval:) instead.")
    }
    
    deinit {
        statusObservationTask?.cancel()
        dotViewAnimationTimer?.invalidate()
    }
    
    // MARK: - Components
    
    private lazy var dotView: UIView = {
        let result = UIView()
        result.themeBackgroundColor = .path_connected
        result.layer.themeShadowColor = .path_connected
        result.layer.shadowOffset = .zero
        result.layer.shadowPath = UIBezierPath(
            ovalIn: CGRect(
                origin: CGPoint.zero,
                size: CGSize(width: PathVC.dotSize, height: PathVC.dotSize)
            )
        ).cgPath
        result.layer.cornerRadius = (PathVC.dotSize / 2)
        
        ThemeManager.onThemeChange(observer: result) { [weak result] theme, _, _ in
            result?.layer.shadowOpacity = (theme.interfaceStyle == .light ? 0.4 : 1)
            result?.layer.shadowRadius = (theme.interfaceStyle == .light ? 1 : 2)
        }
        
        return result
    }()
    
    // MARK: - Layout
    
    private func setUpViewHierarchy() {
        let lineView = UIView()
        lineView.set(.width, to: Values.separatorThickness)
        lineView.themeBackgroundColor = .textPrimary
        addSubview(lineView)
        
        lineView.center(.horizontal, in: self)
        
        switch location {
            case .top: lineView.topAnchor.constraint(equalTo: centerYAnchor).isActive = true
            case .middle, .bottom: lineView.pin(.top, to: .top, of: self)
        }
        
        switch location {
            case .top, .middle: lineView.pin(.bottom, to: .bottom, of: self)
            case .bottom: lineView.bottomAnchor.constraint(equalTo: centerYAnchor).isActive = true
        }
        
        let dotSize = PathVC.dotSize
        dotViewWidthConstraint = dotView.set(.width, to: dotSize)
        dotViewHeightConstraint = dotView.set(.height, to: dotSize)
        addSubview(dotView)
        
        dotView.center(in: self)
        
        let repeatInterval: TimeInterval = self.dotAnimationRepeatInterval
        Timer.scheduledTimer(withTimeInterval: dotAnimationStartDelay, repeats: false) { [weak self] _ in
            self?.animate()
            self?.dotViewAnimationTimer = Timer.scheduledTimer(withTimeInterval: repeatInterval, repeats: true) { _ in
                self?.animate()
            }
        }
    }
    
    private func startObservingNetwork() {
        statusObservationTask?.cancel()
        statusObservationTask = Task.detached(priority: .userInitiated) { [weak self, dependencies] in
            var specificNetworkObservationTask: Task<Void, Never>?
            
            for await network in dependencies.stream(singleton: .network) {
                specificNetworkObservationTask?.cancel()
                specificNetworkObservationTask = Task<Void, Never> {
                    for await status in network.networkStatus {
                        await self?.setStatus(to: status)
                    }
                    
                    Log.info("LineView networkStatus observation ended, restarting.")
                }
            }
            
            specificNetworkObservationTask?.cancel()
        }
    }

    private func animate() {
        expandDot()
        
        Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            self?.collapseDot()
        }
    }

    private func expandDot() {
        UIView.animate(withDuration: 0.5) { [weak self] in
            self?.dotView.transform = CGAffineTransform(
                scaleX: PathVC.expandedDotSize / PathVC.dotSize,
                y: PathVC.expandedDotSize / PathVC.dotSize
            )
        }
    }

    private func collapseDot() {
        UIView.animate(withDuration: 0.5) { [weak self] in
            self?.dotView.transform = CGAffineTransform(scaleX: 1, y: 1)
        }
    }
    
    @MainActor private func setStatus(to status: NetworkStatus) {
        dotView.themeBackgroundColor = status.themeColor
        dotView.layer.themeShadowColor = status.themeColor
    }
}
