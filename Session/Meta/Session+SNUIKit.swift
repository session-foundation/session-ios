// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionSnodeKit
import SessionUtilitiesKit

// MARK: - SessionSNUIKitConfig

internal struct SessionSNUIKitConfig: SNUIKit.ConfigType {
    private let dependencies: Dependencies
    
    var maxFileSize: UInt { Network.maxFileSize }
    var isStorageValid: Bool { dependencies[singleton: .storage].isValid }
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
    }
    
    // MARK: - Functions
    
    func themeChanged(_ theme: Theme, _ primaryColor: Theme.PrimaryColor, _ matchSystemNightModeSetting: Bool) {
        dependencies[singleton: .storage].write { db in
            db[.theme] = theme
            db[.themePrimaryColor] = primaryColor
            db[.themeMatchSystemDayNightCycle] = matchSystemNightModeSetting
        }
    }
    
    func navBarSessionIcon() -> NavBarSessionIcon {
        switch (dependencies[feature: .serviceNetwork], dependencies[feature: .forceOffline]) {
            case (.mainnet, false): return NavBarSessionIcon()
            case (.testnet, _), (.mainnet, true):
                return NavBarSessionIcon(
                    showDebugUI: true,
                    serviceNetworkTitle: dependencies[feature: .serviceNetwork].title,
                    isMainnet: (dependencies[feature: .serviceNetwork] != .mainnet)
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
    
    func placeholderIconCacher(cacheKey: String, generator: @escaping () -> UIImage) -> UIImage {
        let semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)
        var cachedIcon: UIImage?
        
        Task {
            switch await dependencies[singleton: .imageDataManager].cachedImage(identifier: cacheKey)?.type {
                case .staticImage(let image): cachedIcon = image
                case .animatedImage(let frames, _): cachedIcon = frames.first // Shouldn't be possible
                case .none: break
            }
            
            semaphore.signal()
        }
        semaphore.wait()
        
        switch cachedIcon {
            case .some(let image): return image
            case .none:
                let generatedImage: UIImage = generator()
                Task {
                    await dependencies[singleton: .imageDataManager].cacheImage(
                        generatedImage,
                        for: cacheKey
                    )
                }
                return generatedImage
        }
    }
    
    func shouldShowStringKeys() -> Bool {
        return dependencies[feature: .showStringKeys]
    }
}
