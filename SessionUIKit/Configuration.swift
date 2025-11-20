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
    }
    
    @MainActor public static var mainWindow: UIWindow? = nil
    internal static var config: ConfigType? = nil
    private static let configLock = NSLock()
    
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
        configLock.lock()
        defer { configLock.unlock() }
        
        return config?.isRTL == true
    }
    
    internal static func themeSettingsChanged(
        _ theme: Theme,
        _ primaryColor: Theme.PrimaryColor,
        _ matchSystemNightModeSetting: Bool
    ) {
        configLock.lock()
        defer { configLock.unlock() }
        
        config?.themeChanged(theme, primaryColor, matchSystemNightModeSetting)
    }
    
    @MainActor internal static func navBarSessionIcon() -> NavBarSessionIcon {
        configLock.lock()
        defer { configLock.unlock() }
        
        return (config?.navBarSessionIcon() ?? navBarSessionIcon())
    }
    
    internal static func topBannerChanged(to warning: TopBannerController.Warning?) {
        guard let warning: TopBannerController.Warning = warning else {
            configLock.lock()
            defer { configLock.unlock() }
            
            config?.persistentTopBannerChanged(warningKey: nil)
            return
        }
        guard warning.shouldAppearOnResume else { return }
        
        configLock.lock()
        defer { configLock.unlock() }
        
        config?.persistentTopBannerChanged(warningKey: warning.rawValue)
    }
    
    public static func shouldShowStringKeys() -> Bool {
        configLock.lock()
        defer { configLock.unlock() }
        
        return (config?.shouldShowStringKeys() == true)
    }
    
    internal static func assetInfo(for path: String, utType: UTType, sourceFilename: String?) -> (asset: AVURLAsset, isValidVideo: Bool, cleanup: () -> Void)? {
        configLock.lock()
        defer { configLock.unlock() }
        
        return config?.assetInfo(for: path, utType: utType, sourceFilename: sourceFilename)
    }
    
    internal static func mediaDecoderDefaultImageOptions() -> CFDictionary? {
        configLock.lock()
        defer { configLock.unlock() }
        
        return config?.mediaDecoderDefaultImageOptions()
    }
    
    internal static func mediaDecoderDefaultThumbnailOptions(maxDimension: CGFloat) -> CFDictionary? {
        configLock.lock()
        defer { configLock.unlock() }
        
        return config?.mediaDecoderDefaultThumbnailOptions(maxDimension: maxDimension)
    }
    
    internal static func mediaDecoderSource(for url: URL) -> CGImageSource? {
        configLock.lock()
        defer { configLock.unlock() }
        
        return config?.mediaDecoderSource(for: url)
    }
    
    internal static func mediaDecoderSource(for data: Data) -> CGImageSource? {
        configLock.lock()
        defer { configLock.unlock() }
        
        return config?.mediaDecoderSource(for: data)
    }
    
    @MainActor internal static func numberOfCharactersLeft(for text: String) -> Int {
        configLock.lock()
        defer { configLock.unlock() }
        
        return (config?.numberOfCharactersLeft(for: text) ?? 0)
    }
}
