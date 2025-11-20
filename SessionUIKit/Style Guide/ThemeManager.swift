// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import UIKit
import SwiftUI

// MARK: - ThemeManager

public enum ThemeManager {
    private static var hasSetInitialSystemTrait: Bool = false
    
    /// **Note:** Using `weakToStrongObjects` means that the value types will continue to be maintained until the map table resizes
    /// itself (ie. until a new UI element is registered to the table)
    ///
    /// Unfortunately if we don't do this the `ThemeApplier` is immediately deallocated and we can't use it to update the theme
    private static var uiRegistry: NSMapTable<AnyObject, ThemeApplier> = NSMapTable.weakToStrongObjects()
    fileprivate static let syncState: ThemeManagerSyncState = ThemeManagerSyncState(
        theme: Theme.defaultTheme,
        primaryColor: Theme.PrimaryColor.defaultPrimaryColor,
        matchSystemNightModeSetting: false   // Default to `false`
    )
    
    public static var currentTheme: Theme { syncState.state.theme }
    internal static var primaryColor: Theme.PrimaryColor { syncState.state.primaryColor }
    
    // MARK: - Styling
    
    @MainActor public static func updateThemeState(
        theme: Theme? = nil,
        primaryColor: Theme.PrimaryColor? = nil,
        matchSystemNightModeSetting: Bool? = nil
    ) {
        let currentState: ThemeState = syncState.state
        let targetTheme: Theme = (theme ?? currentState.theme)
        let targetPrimaryColor: Theme.PrimaryColor = {
            switch (primaryColor, Theme.PrimaryColor(color: color(for: .defaultPrimary, in: currentState.theme, with: currentState.primaryColor))) {
                case (.some(let primaryColor), _): return primaryColor
                case (.none, .some(let defaultPrimaryColor)): return defaultPrimaryColor
                default: return currentState.primaryColor
            }
        }()
        let targetMatchSystemNightModeSetting: Bool = {
            switch matchSystemNightModeSetting {
                case .some(let value): return value
                case .none: return currentState.matchSystemNightModeSetting
            }
        }()
        let themeChanged: Bool = (currentState.theme != targetTheme || currentState.primaryColor != targetPrimaryColor)
        let matchSystemChanged: Bool = (currentState.matchSystemNightModeSetting != targetMatchSystemNightModeSetting)
        syncState.update(
            hasLoadedTheme: true,
            theme: targetTheme,
            primaryColor: targetPrimaryColor
        )
        
        if matchSystemChanged {
            syncState.update(matchSystemNightModeSetting: targetMatchSystemNightModeSetting)
            
            // Note: We need to set this to 'unspecified' to force the UI to properly update as the
            // 'TraitObservingWindow' won't actually trigger the trait change otherwise
            SNUIKit.mainWindow?.overrideUserInterfaceStyle = .unspecified
        }
        
        // If the theme was changed then trigger a UI update and the callback for the theme settings
        // change (so it gets persisted)
        guard themeChanged || matchSystemChanged else {
            if !hasSetInitialSystemTrait {
                updateAllUI()
            }
            
            return
        }
        
        if !hasSetInitialSystemTrait || themeChanged {
            updateAllUI()
        }
        
        SNUIKit.themeSettingsChanged(targetTheme, targetPrimaryColor, targetMatchSystemNightModeSetting)
    }
    
    @MainActor public static func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        let currentUserInterfaceStyle: UIUserInterfaceStyle = UITraitCollection.current.userInterfaceStyle
        let currentState: ThemeState = syncState.state
        
        // Only trigger updates if the style changed and the device is set to match the system style
        guard
            currentUserInterfaceStyle != currentState.theme.interfaceStyle,
            currentState.matchSystemNightModeSetting
        else { return }
        
        // Swap to the appropriate light/dark mode
        switch (currentUserInterfaceStyle, currentState.theme) {
            case (.light, .classicDark): updateThemeState(theme: .classicLight, primaryColor: currentState.primaryColor)
            case (.light, .oceanDark): updateThemeState(theme: .oceanLight, primaryColor: currentState.primaryColor)
            case (.dark, .classicLight): updateThemeState(theme: .classicDark, primaryColor: currentState.primaryColor)
            case (.dark, .oceanLight): updateThemeState(theme: .oceanDark, primaryColor: currentState.primaryColor)
            default: break
        }
    }
    
    @MainActor public static func applyNavigationStyling() {
        let currentState: ThemeState = syncState.state
        let textPrimary: UIColor = (color(for: .textPrimary, in: currentState.theme, with: currentState.primaryColor) ?? .white)
        let backgroundColor: UIColor? = color(for: .backgroundPrimary, in: currentState.theme, with: currentState.primaryColor)
        
        // Set the `mainWindow.tintColor` for system screens to use the right color for text
        SNUIKit.mainWindow?.tintColor = textPrimary
        SNUIKit.mainWindow?.rootViewController?.setNeedsStatusBarAppearanceUpdate()
        
        // Update toolbars to use the right colours
        UIToolbar.appearance().barTintColor = color(for: .backgroundPrimary, in: currentState.theme, with: currentState.primaryColor)
        UIToolbar.appearance().isTranslucent = false
        UIToolbar.appearance().tintColor = textPrimary
        
        // Update the nav bars to use the right colours
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = backgroundColor
        appearance.shadowImage = backgroundColor?.toImage()
        appearance.titleTextAttributes = [
            NSAttributedString.Key.foregroundColor: textPrimary
        ]
        appearance.largeTitleTextAttributes = [
            NSAttributedString.Key.foregroundColor: textPrimary
        ]
        
        // Apply the button item appearance as well
        let barButtonItemAppearance = UIBarButtonItemAppearance(style: .plain)
        barButtonItemAppearance.normal.titleTextAttributes = [ .foregroundColor: textPrimary ]
        barButtonItemAppearance.disabled.titleTextAttributes = [ .foregroundColor: textPrimary ]
        barButtonItemAppearance.highlighted.titleTextAttributes = [ .foregroundColor: textPrimary ]
        barButtonItemAppearance.focused.titleTextAttributes = [ .foregroundColor: textPrimary ]
        appearance.buttonAppearance = barButtonItemAppearance
        appearance.backButtonAppearance = barButtonItemAppearance
        appearance.doneButtonAppearance = barButtonItemAppearance
        
        UINavigationBar.appearance().isTranslucent = false
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        
        // Note: 'UINavigationBar.appearance' only affects newly created nav bars so we need
        // to force-update any current navigation bar (unfortunately the only way to do this
        // is to remove the nav controller from the view hierarchy and then re-add it)
        func updateIfNeeded(viewController: UIViewController?) {
            guard let viewController: UIViewController = viewController else { return }
            guard
                let navController: UINavigationController = retrieveNavigationController(from: viewController),
                let superview: UIView = navController.view.superview,
                !navController.isNavigationBarHidden
            else {
                updateIfNeeded(viewController:
                    viewController.presentedViewController ??
                    viewController.navigationController?.presentedViewController
                )
                return
            }
            
            // Apply non-primary styling if needed
            applyNavigationStylingIfNeeded(to: viewController)
            
            // Re-attach to the UI
            let wasFirstResponder: Bool = (navController.topViewController?.isFirstResponder == true)
            
            switch navController.parent {
                case let topBannerController as TopBannerController:
                    navController.view.removeFromSuperview()
                    topBannerController.attachChild()
                    
                default:
                    navController.view.removeFromSuperview()
                    superview.addSubview(navController.view)
            }
            navController.topViewController?.setNeedsStatusBarAppearanceUpdate()
            if wasFirstResponder { navController.topViewController?.becomeFirstResponder() }
            
            // Recurse through the rest of the UI
            updateIfNeeded(viewController:
                viewController.presentedViewController ??
                viewController.navigationController?.presentedViewController
            )
        }
        
        updateIfNeeded(viewController: SNUIKit.mainWindow?.rootViewController)
    }
    
    @MainActor public static func applyNavigationStylingIfNeeded(to viewController: UIViewController) {
        // Will use the 'primary' style for all other cases
        guard
            let navController: UINavigationController = ((viewController as? UINavigationController) ?? viewController.navigationController),
            let navigationBackground: ThemeValue = (viewController as? ThemedNavigation)?.navigationBackground
        else { return }
        
        let currentState: ThemeState = syncState.state
        let navigationBackgroundColor: UIColor? = color(for: navigationBackground, in: currentState.theme, with: currentState.primaryColor)
        navController.navigationBar.barTintColor = navigationBackgroundColor
        navController.navigationBar.shadowImage = navigationBackgroundColor?.toImage()
        
        let textPrimary: UIColor = (color(for: .textPrimary, in: currentState.theme, with: currentState.primaryColor) ?? .white)
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = navigationBackgroundColor
        appearance.shadowImage = navigationBackgroundColor?.toImage()
        appearance.titleTextAttributes = [
            NSAttributedString.Key.foregroundColor: textPrimary
        ]
        appearance.largeTitleTextAttributes = [
            NSAttributedString.Key.foregroundColor: textPrimary
        ]
        
        navController.navigationBar.standardAppearance = appearance
        navController.navigationBar.scrollEdgeAppearance = appearance
    }
    
    @MainActor public static func applyWindowStyling() {
        let currentState: ThemeState = syncState.state
        SNUIKit.mainWindow?.overrideUserInterfaceStyle = {
            guard !currentState.matchSystemNightModeSetting else { return .unspecified }
            
            switch currentState.theme.interfaceStyle {
                case .light: return .light
                case .dark, .unspecified: return .dark
                @unknown default: return .dark
            }
        }()
        SNUIKit.mainWindow?.backgroundColor = color(for: .backgroundPrimary, in: currentState.theme, with: currentState.primaryColor)
    }
    
    @MainActor public static func onThemeChange(observer: AnyObject, callback: @escaping @MainActor (Theme, Theme.PrimaryColor, (ThemeValue) -> UIColor?) -> ()) {
        ThemeManager.uiRegistry.setObject(
            ThemeApplier(
                existingApplier: ThemeManager.get(for: observer),
                info: []
            ) { theme in
                callback(theme, syncState.state.primaryColor, { value -> UIColor? in
                    ThemeManager.color(for: value, in: theme, with: syncState.state.primaryColor)
                })
            },
            forKey: observer
        )
    }
    
    internal static func color<T: ColorType>(
        for value: ThemeValue,
        in theme: Theme,
        with primaryColor: Theme.PrimaryColor
    ) -> T? {
        switch value {
            case .value(let value, let alpha):
                let color: T? = color(for: value, in: theme, with: primaryColor)
                return color?.alpha(alpha) as? T
                
            case .primary: return T.resolve(primaryColor)
            case .explicitPrimary(let explicitPrimary): return T.resolve(explicitPrimary)
            
            case .highlighted(let value, let alwaysDarken):
                let color: T? = color(for: value, in: theme, with: primaryColor)!
                
                switch (syncState.state.theme.interfaceStyle, alwaysDarken) {
                    case (.light, _), (_, true): return color?.brighten(-0.06) as? T
                    default: return color?.brighten(0.08) as? T
                }
                
            case .dynamicForInterfaceStyle(let light, let dark):
                switch syncState.state.theme.interfaceStyle {
                    case .light: return color(for: light, in: theme, with: primaryColor)
                    default: return color(for: dark, in: theme, with: primaryColor)
                }
                
            case .dynamicForPrimary(let targetPrimaryColor, let colorIfPrimaryMatches, let fallbackColor):
                return color(
                    for: (primaryColor == targetPrimaryColor ?
                        colorIfPrimaryMatches :
                        fallbackColor
                    ),
                    in: theme,
                    with: primaryColor
                )
            
            default:
                let result: T? = T.resolve(value, for: theme)
                
                /// Since our `primary` colour is no longer based on a `dynamicProvider` we now need to custom handle
                /// when a `ThemeValue` tries to resolve to it
                if result?.isPrimary == true {
                    return T.resolve(primaryColor)
                }
                
                return result
        }
    }
    
    // MARK: -  Internal Functions
    
    @MainActor private static func updateAllUI() {
        let currentState: ThemeState = syncState.state
        ThemeManager.uiRegistry.objectEnumerator()?.forEach { applier in
            (applier as? ThemeApplier)?.apply(theme: currentState.theme)
        }
        
        applyNavigationStyling()
        applyWindowStyling()
        
        if !hasSetInitialSystemTrait {
            traitCollectionDidChange(nil)
            hasSetInitialSystemTrait = true
        }
    }
    
    private static func retrieveNavigationController(from viewController: UIViewController) -> UINavigationController? {
        switch viewController {
            case let navController as UINavigationController: return navController
            case let topBannerController as TopBannerController:
                return (topBannerController.children.first as? UINavigationController)
                
            default: return viewController.navigationController
        }
    }
    
    @MainActor internal static func set<T: AnyObject>(
        _ view: T,
        keyPath: ReferenceWritableKeyPath<T, UIColor?>,
        to value: ThemeValue?
    ) {
        ThemeManager.uiRegistry.setObject(
            ThemeApplier(
                existingApplier: ThemeManager.get(for: view),
                info: [ keyPath ]
            ) { [weak view] theme in
                guard let value: ThemeValue = value else {
                    view?[keyPath: keyPath] = nil
                    return
                }

                let currentState: ThemeState = syncState.state
                view?[keyPath: keyPath] = ThemeManager.resolvedColor(
                    ThemeManager.color(for: value, in: currentState.theme, with: currentState.primaryColor)
                )
            },
            forKey: view
        )
    }
    
    internal static func remove<T: AnyObject>(
        _ view: T,
        keyPath: ReferenceWritableKeyPath<T, UIColor?>
    ) {
        // Note: Need to explicitly remove (setting to 'nil' won't actually remove it)
        guard let updatedApplier: ThemeApplier = ThemeManager.get(for: view)?.removing(allWith: keyPath) else {
            ThemeManager.uiRegistry.removeObject(forKey: view)
            return
        }
        
        ThemeManager.uiRegistry.setObject(updatedApplier, forKey: view)
    }
    
    @MainActor internal static func set<T: AnyObject>(
        _ view: T,
        keyPath: ReferenceWritableKeyPath<T, CGColor?>,
        to value: ThemeValue?
    ) {
        ThemeManager.uiRegistry.setObject(
            ThemeApplier(
                existingApplier: ThemeManager.get(for: view),
                info: [ keyPath ]
            ) { [weak view] theme in
                guard let value: ThemeValue = value else {
                    view?[keyPath: keyPath] = nil
                    return
                }
                
                let currentState: ThemeState = syncState.state
                view?[keyPath: keyPath] = ThemeManager.resolvedColor(
                    ThemeManager.color(for: value, in: currentState.theme, with: currentState.primaryColor)
                )?.cgColor
            },
            forKey: view
        )
    }
    
    internal static func remove<T: AnyObject>(
        _ view: T,
        keyPath: ReferenceWritableKeyPath<T, CGColor?>
    ) {
        ThemeManager.uiRegistry.setObject(
            ThemeManager.get(for: view)?
                .removing(allWith: keyPath),
            forKey: view
        )
    }
    
    @MainActor internal static func set<T: AttributedTextAssignable>(
        _ view: T,
        keyPath: ReferenceWritableKeyPath<T, ThemedAttributedString?>,
        to value: ThemedAttributedString?
    ) {
        ThemeManager.uiRegistry.setObject(
            ThemeApplier(
                existingApplier: ThemeManager.get(for: view),
                info: [ keyPath ]
            ) { [weak view] theme in
                guard let originalThemedString: ThemedAttributedString = value else {
                    view?[keyPath: keyPath] = nil
                    return
                }
                
                let newAttrString: NSMutableAttributedString = NSMutableAttributedString()
                let fullRange: NSRange = NSRange(location: 0, length: originalThemedString.value.length)
                let currentState: ThemeState = syncState.state
                
                originalThemedString.value.enumerateAttributes(in: fullRange, options: []) { attributes, range, _ in
                    var newAttributes: [NSAttributedString.Key: Any] = attributes
                    
                    /// Convert any of our custom attributes to their normal ones
                    NSAttributedString.Key.themedKeys.forEach { key in
                        guard let themeValue: ThemeValue = newAttributes[key] as? ThemeValue else {
                            return
                        }
                        
                        newAttributes.removeValue(forKey: key)
                        
                        guard
                            let originalKey = key.originalKey,
                            let color = ThemeManager.color(for: themeValue, in: currentState.theme, with: currentState.primaryColor) as UIColor?
                        else { return }
                        
                        newAttributes[originalKey] = ThemeManager.resolvedColor(color)
                    }
                    
                    /// Add the themed substring to `newAttrString`
                    let substring: String = originalThemedString.value.attributedSubstring(from: range).string
                    newAttrString.append(NSAttributedString(string: substring, attributes: newAttributes))
                }
                
                view?[keyPath: keyPath] = ThemedAttributedString(attributedString: newAttrString)
            },
            forKey: view
        )
    }
    
    internal static func set<T: AnyObject>(
        _ view: T,
        to applier: ThemeApplier?
    ) {
        ThemeManager.uiRegistry.setObject(applier, forKey: view)
    }
    
    /// Using a `UIColor(dynamicProvider:)` unfortunately doesn't seem to work properly for some controls (eg. UISwitch) so
    /// since we are already explicitly updating all UI when changing colors & states we just force-resolve the primary color to avoid
    /// running into these glitches
    internal static func resolvedColor(_ color: UIColor?) -> UIColor? {
        return color?.resolvedColor(with: UITraitCollection())
    }
    
    internal static func get(for view: AnyObject) -> ThemeApplier? {
        return ThemeManager.uiRegistry.object(forKey: view)
    }
}

// MARK: - SyncState

private struct ThemeState {
    let theme: Theme
    let primaryColor: Theme.PrimaryColor
    let matchSystemNightModeSetting: Bool
}

private final class ThemeManagerSyncState {
    private let lock: NSLock = NSLock()
    private var _hasLoadedTheme: Bool = false
    private var _theme: Theme
    private var _primaryColor: Theme.PrimaryColor
    private var _matchSystemNightModeSetting: Bool
    
    fileprivate var hasLoadedTheme: Bool { lock.withLock { _hasLoadedTheme } }
    fileprivate var state: ThemeState {
        lock.withLock {
            ThemeState(
                theme: _theme,
                primaryColor: _primaryColor,
                matchSystemNightModeSetting: _matchSystemNightModeSetting
            )
        }
    }
    
    fileprivate init(
        theme: Theme,
        primaryColor: Theme.PrimaryColor,
        matchSystemNightModeSetting: Bool
    ) {
        self._theme = theme
        self._primaryColor = primaryColor
        self._matchSystemNightModeSetting = matchSystemNightModeSetting
    }
    
    fileprivate func update(
        hasLoadedTheme: Bool? = nil,
        theme: Theme? = nil,
        primaryColor: Theme.PrimaryColor? = nil,
        matchSystemNightModeSetting: Bool? = nil
    ) {
        lock.withLock {
            self._hasLoadedTheme = (hasLoadedTheme ?? self._hasLoadedTheme)
            self._theme = (theme ?? self._theme)
            self._primaryColor = (primaryColor ?? self._primaryColor)
            self._matchSystemNightModeSetting = (matchSystemNightModeSetting ?? self._matchSystemNightModeSetting)
        }
    }
}

// MARK: - ThemeApplier

internal class ThemeApplier {
    enum InfoKey: String {
        case keyPath
        case controlState
    }
    
    private let applyTheme: @MainActor (Theme) -> ()
    private let info: [AnyHashable]
    private var otherAppliers: [ThemeApplier]?
    
    @MainActor init(
        existingApplier: ThemeApplier?,
        info: [AnyHashable],
        applyTheme: @escaping @MainActor (Theme) -> ()
    ) {
        self.applyTheme = applyTheme
        self.info = info
        
        // Store any existing "appliers" (removing their 'otherApplier' references to prevent
        // loops and excluding any which match the current "info" as they should be replaced
        // by this applier)
        self.otherAppliers = [existingApplier]
            .appending(contentsOf: existingApplier?.otherAppliers)
            .compactMap { $0?.clearingOtherAppliers() }
            .filter { $0.info != info }
        
        // Automatically apply the theme immediately (if the database has been setup)
        if SNUIKit.config?.isStorageValid == true || ThemeManager.syncState.hasLoadedTheme {
            apply(theme: ThemeManager.syncState.state.theme, isInitialApplication: true)
        }
    }
    
    // MARK: - Functions
    
    public func removing(allWith info: AnyHashable) -> ThemeApplier? {
        let remainingAppliers: [ThemeApplier] = [self]
            .appending(contentsOf: self.otherAppliers)
            .filter { applier in !applier.info.contains(info) }
        
        guard !remainingAppliers.isEmpty else { return nil }
        guard remainingAppliers.count != ((self.otherAppliers ?? []).count + 1) else { return self }
        
        // Remove the 'otherAppliers' references on self
        self.otherAppliers = nil
        
        // Attach the 'otherAppliers' to the new first remaining applier (just in case self
        // was removed)
        let firstApplier: ThemeApplier? = remainingAppliers.first
        firstApplier?.otherAppliers = Array(remainingAppliers.suffix(from: 1))
        
        return firstApplier
    }
    
    private func clearingOtherAppliers() -> ThemeApplier {
        self.otherAppliers = nil
        
        return self
    }
    
    @MainActor fileprivate func apply(theme: Theme, isInitialApplication: Bool = false) {
        self.applyTheme(theme)
        
        // For the initial application of a ThemeApplier we don't want to apply the other
        // appliers (they should have already been applied so doing so is redundant
        guard !isInitialApplication else { return }
        
        // If there are otherAppliers stored against this one then trigger those as well
        self.otherAppliers?.forEach { applier in
            applier.applyTheme(theme)
        }
    }
}

// MARK: - Convenience Extensions

extension Array {
    fileprivate func appending(contentsOf other: [Element]?) -> [Element] {
        guard let other: [Element] = other else { return self }
        
        var updatedArray: [Element] = self
        updatedArray.append(contentsOf: other)
        return updatedArray
    }
}

// MARK: - ColorType

internal protocol ColorType {
    /// Apple have done some odd schenanigans with `UIColor` where some types aren't _actually_ `UIColor` but a special
    /// type (eg. `UIColor.black` and `UIColor.white` are `UICachedDeviceWhiteColor`), due to this casting to
    /// `Self` in an extension on `UIColor` ends up failing (because calling `alpha(_)` on a `UICachedDeviceWhiteColor`
    /// expects you to return a `UICachedDeviceWhiteColor`, but the alpha-applied output is a standard `UIColor` which can't
    /// convert to `Self`), by defining an explicit `BaseColorType` we return an explicit type and avoid weird private types
    associatedtype BaseColorType
    
    var isPrimary: Bool { get }
    
    func alpha(_ alpha: Double) -> BaseColorType?
    func brighten(_ amount: Double) -> BaseColorType?
}

extension UIColor: ColorType {
    internal var isPrimary: Bool { self == UIColor.primary() }
    
    internal func alpha(_ alpha: Double) -> UIColor? {
        return self.withAlphaComponent(CGFloat(alpha))
    }
    
    internal func brighten(_ amount: Double) -> UIColor? {
        return self.brighten(by: amount)
    }
}

extension Color: ColorType {
    internal var isPrimary: Bool { self == Color.primary() }
    
    internal func alpha(_ alpha: Double) -> Color? {
        return self.opacity(alpha)
    }
    
    internal func brighten(_ amount: Double) -> Color? {
        guard amount > 0 else {
            return (self.grayscale(amount) as? Color)
        }
        
        return (self.brightness(amount) as? Color)
    }
}

// MARK: - Previews

private struct PreviewThemeKey: EnvironmentKey {
    static let defaultValue: (Theme, Theme.PrimaryColor)? = nil
}

extension EnvironmentValues {
    var previewTheme: (Theme, Theme.PrimaryColor)? {
        get { self[PreviewThemeKey.self] }
        set { self[PreviewThemeKey.self] = newValue }
    }
}

public struct PreviewThemeWrapper<Content: View>: View {
    let theme: Theme
    let primaryColor: Theme.PrimaryColor
    let content: Content
    
    public init(theme: Theme, primaryColor: Theme.PrimaryColor? = nil, @ViewBuilder content: () -> Content) {
        self.theme = theme
        self.primaryColor = (primaryColor ?? theme.defaultPrimary)
        self.content = content()
    }
    
    public var body: some View {
        content
            .environment(\.previewTheme, (theme, primaryColor))
    }
}
