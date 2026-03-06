// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SwiftUI
import Combine
import SessionUIKit
import SessionNetworkingKit
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
    private var statusObservationTask: Task<Void, Never>?
    private var lastStatus: NetworkStatus?
    
    init(size: Size = .small, using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.size = size
        
        super.init(frame: .zero)
        
        setUpViewHierarchy()
        setStatus(to: .unknown) // Default to the unknown status
        startObservingNetwork()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        statusObservationTask?.cancel()
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
        
        ThemeManager.onThemeChange(observer: self) { [weak self] theme, _, _ in
            self?.layer.shadowOpacity = (theme.interfaceStyle == .light ? 0.4 : 1)
            self?.layer.shadowRadius = (self?.size.offset(for: theme.interfaceStyle) ?? 0)
            
            /// Re-apply the status just in case (will re-apply any styling which may be affected by the above)
            if let lastStatus: NetworkStatus = self?.lastStatus {
                self?.setStatus(to: lastStatus)
            }
        }
    }
    
    // MARK: - Functions

    private func startObservingNetwork() {
        statusObservationTask?.cancel()
        statusObservationTask = Task.detached(priority: .userInitiated) { [weak self, dependencies] in
            for await status in dependencies.networkStatusUpdates {
                await self?.setStatus(to: status)
            }
        }
    }

    @MainActor private func setStatus(to status: NetworkStatus) {
        lastStatus = status
        themeBackgroundColor = status.themeColor
        layer.themeShadowColor = status.themeColor
    }
}

struct PathStatusView_SwiftUI: View {
    enum Size {
        case small
        case large
        
        var pointSize: CGFloat {
            switch self {
            case .small: return 8
            case .large: return 16
            }
        }
        
        func offset(for colorScheme: ColorScheme) -> CGFloat {
            switch self {
            case .small: return (colorScheme == .light ? 6 : 8)
            case .large: return (colorScheme == .light ? 6 : 8)
            }
        }
    }
    
    // MARK: - Properties
    
    private let dependencies: Dependencies
    private let size: Size
    
    @State private var networkStatus: NetworkStatus = .unknown
    @Environment(\.colorScheme) private var colorScheme
    
    // MARK: - Initialization
    
    init(size: Size = .small, using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.size = size
    }
    
    // MARK: - Body
    
    var body: some View {
        Circle()
            .fill(themeColor: networkStatus.themeColor)
            .frame(width: size.pointSize, height: size.pointSize)
            .shadow(
                themeColor: .value(
                    networkStatus.themeColor,
                    alpha: (colorScheme == .light ? 0.4 : 1.0)
                ),
                radius: size.offset(for: colorScheme),
                x: 0,
                y: 0.8
            )
            .task {
                for await status in dependencies.networkStatusUpdates {
                    networkStatus = status
                }
            }
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
