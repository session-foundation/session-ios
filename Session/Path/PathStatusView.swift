// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Combine
import SessionUIKit
import SessionSnodeKit
import SessionMessagingKit
import SessionUtilitiesKit

final class PathStatusView: UIView {
    enum Size {
        case small
        case large
        
        var pointSize: CGFloat {
            switch self {
                case .small: return 8
                case .large: return 16
            }
        }
        
        func offset(for interfaceStyle: UIUserInterfaceStyle) -> CGFloat {
            switch self {
                case .small: return (interfaceStyle == .light ? 6 : 8)
                case .large: return (interfaceStyle == .light ? 6 : 8)
            }
        }
    }
    
    // MARK: - Initialization
    
    private let dependencies: Dependencies
    private let size: Size
    private var disposables: Set<AnyCancellable> = Set()
    
    init(size: Size = .small, using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.size = size
        
        super.init(frame: .zero)
        
        setUpViewHierarchy()
        setStatus(to: .unknown) // Default to the unknown status
        registerObservers()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Layout
    
    private func setUpViewHierarchy() {
        self.set(.width, to: self.size.pointSize)
        self.set(.height, to: self.size.pointSize)
        
        layer.cornerRadius = (self.size.pointSize / 2)
        layer.masksToBounds = false
        layer.shadowOffset = CGSize(width: 0, height: 0.8)
        layer.shadowPath = UIBezierPath(
            ovalIn: CGRect(
                origin: CGPoint.zero,
                size: CGSize(width: self.size.pointSize, height: self.size.pointSize)
            )
        ).cgPath
        
        ThemeManager.onThemeChange(observer: self) { [weak self] theme, _ in
            self?.layer.shadowOpacity = (theme.interfaceStyle == .light ? 0.4 : 1)
            self?.layer.shadowRadius = (self?.size.offset(for: theme.interfaceStyle) ?? 0)
        }
    }
    
    // MARK: - Functions

    private func registerObservers() {
        /// Register for status updates (will be called immediately with current status)
        dependencies[cache: .libSessionNetwork].networkStatus
            .receive(on: DispatchQueue.main, using: dependencies)
            .sink(
                receiveCompletion: { [weak self] _ in
                    /// If the stream completes it means the network cache was reset in which case we want to
                    /// re-register for updates in the next run loop (as the new cache should be created by then)
                    DispatchQueue.global(qos: .background).async {
                        self?.registerObservers()
                    }
                },
                receiveValue: { [weak self] status in self?.setStatus(to: status) }
            )
            .store(in: &disposables)
    }

    private func setStatus(to status: NetworkStatus) {
        themeBackgroundColor = status.themeColor
        layer.themeShadowColor = status.themeColor
    }
}

public extension NetworkStatus {
    var themeColor: ThemeValue {
        switch self {
            case .unknown: return .path_unknown
            case .connecting: return .path_connecting
            case .connected: return .path_connected
            case .disconnected: return .path_error
        }
    }
}

// MARK: - Info

final class PathStatusViewAccessory: UIView, SessionCell.Accessory.CustomView {
    struct Info: Equatable, SessionCell.Accessory.CustomViewInfo {
        typealias View = PathStatusViewAccessory
    }
    
    /// We want the path status to have the same sizing as other list item icons so it needs to be wrapped in
    /// this contains view
    public static let size: SessionCell.Accessory.Size = .fixed(
        width: IconSize.medium.size,
        height: IconSize.medium.size
    )
    
    static func create(maxContentWidth: CGFloat, using dependencies: Dependencies) -> PathStatusViewAccessory {
        return PathStatusViewAccessory(using: dependencies)
    }
    
    private let dependencies: Dependencies
    
    // MARK: - Components
    
    lazy var pathStatusView: PathStatusView = PathStatusView(size: .large, using: dependencies)
    
    // MARK: Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        
        super.init(frame: .zero)
        
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("Use init(theme:) instead")
    }
    
    // MARK: - Layout
    
    private func setupUI() {
        isUserInteractionEnabled = false
        addSubview(pathStatusView)
        
        setupLayout()
    }
    
    private func setupLayout() {
        pathStatusView.center(in: self)
    }
    
    // MARK: - Content
    
    // No need to do anything (theme with auto-update)
    func update(with info: Info) {}
}
