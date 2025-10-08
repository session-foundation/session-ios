// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import AVFoundation
import UniformTypeIdentifiers

public typealias ThemeSettings = (theme: Theme?, primaryColor: Theme.PrimaryColor?, matchSystemNightModeSetting: Bool?)

public actor SNUIKit {
    public protocol ConfigType {
        var maxFileSize: UInt { get }
        var isStorageValid: Bool { get }
        
        func themeChanged(_ theme: Theme, _ primaryColor: Theme.PrimaryColor, _ matchSystemNightModeSetting: Bool)
        func navBarSessionIcon() -> NavBarSessionIcon
        func persistentTopBannerChanged(warningKey: String?)
        func cachedContextualActionInfo(tableViewHash: Int, sideKey: String) -> [Int: Any]?
        func cacheContextualActionInfo(tableViewHash: Int, sideKey: String, actionIndex: Int, actionInfo: Any)
        func removeCachedContextualActionInfo(tableViewHash: Int, keys: [String])
        func shouldShowStringKeys() -> Bool
        func assetInfo(for path: String, utType: UTType, sourceFilename: String?) -> (asset: AVURLAsset, isValidVideo: Bool, cleanup: () -> Void)?
    }
    
    @MainActor public static var mainWindow: UIWindow? = nil
    internal static var config: ConfigType? = nil
    
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
        self.config = config
    }
    
    internal static func themeSettingsChanged(
        _ theme: Theme,
        _ primaryColor: Theme.PrimaryColor,
        _ matchSystemNightModeSetting: Bool
    ) {
        config?.themeChanged(theme, primaryColor, matchSystemNightModeSetting)
    }
    
    @MainActor internal static func navBarSessionIcon() -> NavBarSessionIcon {
        guard let config: ConfigType = self.config else { return NavBarSessionIcon() }
        
        return config.navBarSessionIcon()
    }
    
    internal static func topBannerChanged(to warning: TopBannerController.Warning?) {
        guard let warning: TopBannerController.Warning = warning else {
            config?.persistentTopBannerChanged(warningKey: nil)
            return
        }
        guard warning.shouldAppearOnResume else { return }
        
        config?.persistentTopBannerChanged(warningKey: warning.rawValue)
    }
    
    public static func shouldShowStringKeys() -> Bool {
        guard let config: ConfigType = self.config else { return false }
        
        return config.shouldShowStringKeys()
    }
    
    internal static func assetInfo(for path: String, utType: UTType, sourceFilename: String?) -> (asset: AVURLAsset, isValidVideo: Bool, cleanup: () -> Void)? {
        guard let config: ConfigType = self.config else { return nil }
        
        return config.assetInfo(for: path, utType: utType, sourceFilename: sourceFilename)
    }
}
