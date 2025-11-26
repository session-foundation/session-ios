// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import AVFoundation
import UniformTypeIdentifiers
import SessionUIKit
import SessionNetworkingKit
import SessionMessagingKit
import SessionUtilitiesKit

// MARK: - SessionSNUIKitConfig

internal struct SessionSNUIKitConfig: SNUIKit.ConfigType {
    private let dependencies: Dependencies
    
    var maxFileSize: UInt { Network.maxFileSize }
    var isStorageValid: Bool { dependencies[singleton: .storage].isValid }
    var isRTL: Bool { Dependencies.isRTL }
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
    }
    
    // MARK: - Functions
    
    func themeChanged(_ theme: Theme, _ primaryColor: Theme.PrimaryColor, _ matchSystemNightModeSetting: Bool) {
        let mutation: LibSession.Mutation? = try? dependencies.mutate(cache: .libSession) { cache in
            try cache.perform(for: .local) {
                cache.set(.theme, theme)
                cache.set(.themePrimaryColor, primaryColor)
                cache.set(.themeMatchSystemDayNightCycle, matchSystemNightModeSetting)
            }
        }
        
        dependencies[singleton: .storage].writeAsync { db in
            try mutation?.upsert(db)
        }
    }
    
    func navBarSessionIcon() -> NavBarSessionIcon {
        switch (dependencies[feature: .serviceNetwork], dependencies[feature: .forceOffline]) {
            case (.mainnet, false): return NavBarSessionIcon()
            case (.testnet, _), (.mainnet, true):
                return NavBarSessionIcon(
                    showDebugUI: true,
                    serviceNetworkTitle: dependencies[feature: .serviceNetwork].title,
                    isMainnet: (dependencies[feature: .serviceNetwork] == .mainnet),
                    isOffline: dependencies[feature: .forceOffline]
                )
        }
    }
    
    func persistentTopBannerChanged(warningKey: String?) {
        dependencies[defaults: .appGroup, key: .topBannerWarningToShow] = warningKey
    }
    
    func cachedContextualActionInfo(tableViewHash: Int, sideKey: String) -> [Int: Any]? {
        dependencies[cache: .general].contextualActionLookupMap
            .getting(tableViewHash)?
            .getting(sideKey)
    }
    
    func cacheContextualActionInfo(tableViewHash: Int, sideKey: String, actionIndex: Int, actionInfo: Any) {
        dependencies.mutate(cache: .general) { cache in
            let updatedLookup = (cache.contextualActionLookupMap[tableViewHash] ?? [:])
                .setting(
                    sideKey,
                    ((cache.contextualActionLookupMap[tableViewHash] ?? [:]).getting(sideKey) ?? [:])
                        .setting(actionIndex, actionInfo)
                )
            
            cache.contextualActionLookupMap[tableViewHash] = updatedLookup
        }
    }
    
    func removeCachedContextualActionInfo(tableViewHash: Int, keys: [String]) {
        dependencies.mutate(cache: .general) { cache in
            keys.forEach { key in
                cache.contextualActionLookupMap[tableViewHash]?[key] = nil
            }
            
            if cache.contextualActionLookupMap[tableViewHash]?.isEmpty == true {
                cache.contextualActionLookupMap[tableViewHash] = nil
            }
        }
    }
    
    func shouldShowStringKeys() -> Bool {
        return dependencies[feature: .showStringKeys]
    }
    
    func assetInfo(for path: String, utType: UTType, sourceFilename: String?) -> (asset: AVURLAsset, isValidVideo: Bool, cleanup: () -> Void)? {
        guard
            let result: (asset: AVURLAsset, utType: UTType, cleanup: () -> Void) = AVURLAsset.asset(
                for: path,
                utType: utType,
                sourceFilename: sourceFilename,
                using: dependencies
            )
        else { return nil }
        
        return (result.asset, MediaUtils.isValidVideo(asset: result.asset, utType: result.utType), result.cleanup)
    }
    
    func mediaDecoderDefaultImageOptions() -> CFDictionary {
        return dependencies[singleton: .mediaDecoder].defaultImageOptions
    }
    
    func mediaDecoderDefaultThumbnailOptions(maxDimension: CGFloat) -> CFDictionary {
        return dependencies[singleton: .mediaDecoder].defaultThumbnailOptions(maxDimension: maxDimension)
    }
    
    func mediaDecoderSource(for url: URL) -> CGImageSource? {
        return dependencies[singleton: .mediaDecoder].source(for: url)
    }
    
    func mediaDecoderSource(for data: Data) -> CGImageSource? {
        return dependencies[singleton: .mediaDecoder].source(for: data)
    }
    
    @MainActor func numberOfCharactersLeft(for text: String) -> Int {
        return dependencies[singleton: .sessionProManager].numberOfCharactersLeft(for: text)
    }
    
    func proUrlStringProvider() -> SessionProUI.UrlStringProvider {
        return SessionPro.Metadata.urls
    }
    
    func proClientPlatformStringProvider(for platform: SessionProUI.ClientPlatform) -> SessionProUI.ClientPlatformStringProvider {
        switch platform {
            case .iOS: return SessionPro.Metadata.appStore
            case .android: return SessionPro.Metadata.playStore
        }
    }
}
