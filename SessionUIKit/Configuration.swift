// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import AVFoundation
import UniformTypeIdentifiers

public typealias ThemeSettings = (theme: Theme?, primaryColor: Theme.PrimaryColor?, matchSystemNightModeSetting: Bool?)

public actor SNUIKit {
    public protocol ConfigType {
        var maxFileSize: UInt { get }
        var isStorageValid: Bool { get }
        var isRTL: Bool { get }
        var initialMainScreenScale: CGFloat { get }
        var initialMainScreenMaxDimension: CGFloat { get }
        
        func themeChanged(_ theme: Theme, _ primaryColor: Theme.PrimaryColor, _ matchSystemNightModeSetting: Bool)
        func navBarSessionIcon() -> NavBarSessionIcon
        func persistentTopBannerChanged(warningKey: String?)
        func cachedContextualActionInfo(tableViewHash: Int, sideKey: String) -> [Int: Any]?
        func cacheContextualActionInfo(tableViewHash: Int, sideKey: String, actionIndex: Int, actionInfo: Any)
        func removeCachedContextualActionInfo(tableViewHash: Int, keys: [String])
        func shouldShowStringKeys() -> Bool
        func assetInfo(for path: String, utType: UTType, sourceFilename: String?) -> (asset: AVURLAsset, isValidVideo: Bool, cleanup: () -> Void)?
        
        func mediaDecoderDefaultImageOptions() -> CFDictionary
        func mediaDecoderDefaultThumbnailOptions(maxDimension: CGFloat) -> CFDictionary
        func mediaDecoderSource(for url: URL) -> CGImageSource?
        func mediaDecoderSource(for data: Data) -> CGImageSource?
        
        @MainActor func numberOfCharactersLeft(for text: String) -> Int
        
        func urlStringProvider() -> StringProvider.Url
        func buildVariantStringProvider() -> StringProvider.BuildVariant
        func proClientPlatformStringProvider(for platform: SessionProUI.ClientPlatform) -> StringProvider.ClientPlatform
        func proVisiblePlatformStores() -> [String]
    }
    
    @MainActor public static var mainWindow: UIWindow? = nil
    public static let imageCache: NSCache<NSString, UIImage> = NSCache()
    internal static var config: ConfigType? = nil
    private static let configLock = NSLock()
    
    /// The current config, read under the lock and returned so the caller can invoke it **unlocked**
    ///
    /// **Note:** `configLock` is not recursive, so calling into `config` while holding it deadlocks the moment the
    /// callback re-enters `SNUIKit` - which it can, since the app's config reaches back through lazily-initialised
    /// statics (`Constants.buildVariants` → `providerString` → `localized()` → `shouldShowStringKeys()`). The lock
    /// only protects the reference, so copy it out and drop the lock before calling anything on it.
    private static func currentConfig() -> ConfigType? {
        configLock.lock()
        defer { configLock.unlock() }
        
        return config
    }
    
    @MainActor public static func setMainWindow(_ mainWindow: UIWindow) {
        self.mainWindow = mainWindow
    }
    
    @MainActor public static func configure(with config: ConfigType, themeSettings: ThemeSettings?) {
        /// Apply the theme settings before storing the config so we don't needlessly update the settings in the database
        ThemeManager.updateThemeState(
            theme: themeSettings?.theme,
            primaryColor: themeSettings?.primaryColor,
            matchSystemNightModeSetting: themeSettings?.matchSystemNightModeSetting
        )
        configLock.lock()
        self.config = config
        configLock.unlock()
    }
    
    public static var isRTL: Bool {
        return currentConfig()?.isRTL == true
    }
    
    public static var initialMainScreenScale: CGFloat? {
        return currentConfig()?.initialMainScreenScale
    }
    
    public static var initialMainScreenMaxDimension: CGFloat? {
        return currentConfig()?.initialMainScreenMaxDimension
    }
    
    internal static func themeSettingsChanged(
        _ theme: Theme,
        _ primaryColor: Theme.PrimaryColor,
        _ matchSystemNightModeSetting: Bool
    ) {
        currentConfig()?.themeChanged(theme, primaryColor, matchSystemNightModeSetting)
    }
    
    @MainActor internal static func navBarSessionIcon() -> NavBarSessionIcon {
        return (currentConfig()?.navBarSessionIcon() ?? navBarSessionIcon())
    }
    
    internal static func topBannerChanged(to warning: TopBannerController.Warning?) {
        guard let warning: TopBannerController.Warning = warning else {
            currentConfig()?.persistentTopBannerChanged(warningKey: nil)
            return
        }
        guard warning.shouldAppearOnResume else { return }
        
        currentConfig()?.persistentTopBannerChanged(warningKey: warning.rawValue)
    }
    
    public static func shouldShowStringKeys() -> Bool {
        return (currentConfig()?.shouldShowStringKeys() == true)
    }
    
    internal static func assetInfo(for path: String, utType: UTType, sourceFilename: String?) -> (asset: AVURLAsset, isValidVideo: Bool, cleanup: () -> Void)? {
        return currentConfig()?.assetInfo(for: path, utType: utType, sourceFilename: sourceFilename)
    }
    
    internal static func mediaDecoderDefaultImageOptions() -> CFDictionary? {
        return currentConfig()?.mediaDecoderDefaultImageOptions()
    }
    
    internal static func mediaDecoderDefaultThumbnailOptions(maxDimension: CGFloat) -> CFDictionary? {
        return currentConfig()?.mediaDecoderDefaultThumbnailOptions(maxDimension: maxDimension)
    }
    
    internal static func mediaDecoderSource(for url: URL) -> CGImageSource? {
        return currentConfig()?.mediaDecoderSource(for: url)
    }
    
    internal static func mediaDecoderSource(for data: Data) -> CGImageSource? {
        return currentConfig()?.mediaDecoderSource(for: data)
    }
    
    @MainActor internal static func numberOfCharactersLeft(for text: String) -> Int {
        return (currentConfig()?.numberOfCharactersLeft(for: text) ?? 0)
    }
    
    internal static func urlStringProvider() -> StringProvider.Url {
        return (
            currentConfig()?.urlStringProvider() ??
            StringProvider.FallbackUrlStringProvider()
        )
    }
    
    internal static func buildVariantStringProvider() -> StringProvider.BuildVariant {
        return (
            currentConfig()?.buildVariantStringProvider() ??
            StringProvider.FallbackBuildVariantStringProvider()
        )
    }
    
    internal static func proClientPlatformStringProvider(for platform: SessionProUI.ClientPlatform) -> StringProvider.ClientPlatform {
        return (
            currentConfig()?.proClientPlatformStringProvider(for: platform) ??
            StringProvider.FallbackClientPlatformStringProvider()
        )
    }

    internal static func proVisiblePlatformStores() -> [String] {
        return (currentConfig()?.proVisiblePlatformStores() ?? [])
    }
}
