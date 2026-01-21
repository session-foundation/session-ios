// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionUIKit

struct VersionFooterView: View {
    private static let footerHeight: CGFloat = 75
    private static let logoHeight: CGFloat = 24
    
    let numVersionTapsRequired: Int
    let logoTapCallback: () -> Void
    let versionTapCallback: () -> Void
    
    @State private var versionTapCount = 0
    @State private var lastTapTime = Date()
    
    private var versionText: String {
        let infoDict = Bundle.main.infoDictionary
        let version = (infoDict?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
        let buildNumber = infoDict?["CFBundleVersion"] as? String
        let commitInfo = infoDict?["GitCommitHash"] as? String
        
        let buildInfo = [buildNumber, commitInfo]
            .compactMap { $0 }
            .joined(separator: " - ")
        
        var components = ["Version \(version)"]
        if !buildInfo.isEmpty {
            components.append("(\(buildInfo))")
        }
        
        return components.joined(separator: " ")
    }
    
    init(
        numVersionTapsRequired: Int = 0,
        logoTapCallback: @escaping () -> Void = {},
        versionTapCallback: @escaping () -> Void = {}
    ) {
        self.numVersionTapsRequired = numVersionTapsRequired
        self.logoTapCallback = logoTapCallback
        self.versionTapCallback = versionTapCallback
    }
    
    var body: some View {
        VStack(spacing: Values.mediumSpacing) {
            Image("token_logo")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: Self.logoHeight)
                .foregroundColor(themeColor: .textSecondary)
                .offset(x: -2)
                .onTapGesture {
                    logoTapCallback()
                }
            
            Text(versionText)
                .font(.Body.extraSmallRegular)
                .foregroundColor(themeColor: .textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .contentShape(Rectangle())
                .onTapGesture {
                    handleVersionTap()
                }
        }
        .frame(height: Self.footerHeight)
    }
    
    private func handleVersionTap() {
        guard numVersionTapsRequired > 0 else { return }
        
        let now = Date()
        let timeSinceLastTap = now.timeIntervalSince(lastTapTime)
        
        // Reset count if more than 0.5 seconds between taps
        if timeSinceLastTap > 0.5 {
            versionTapCount = 1
        } else {
            versionTapCount += 1
        }
        
        lastTapTime = now
        
        if versionTapCount >= numVersionTapsRequired {
            versionTapCallback()
            versionTapCount = 0
        }
    }
}
