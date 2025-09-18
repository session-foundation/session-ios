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
    
    private static var _hasLoadedTheme: Bool = false
    private static var _theme: Theme = Theme.defaultTheme
    private static var _primaryColor: Theme.PrimaryColor = Theme.PrimaryColor.defaultPrimaryColor
    private static var _matchSystemNightModeSetting: Bool = false   // Default to `false`
    
    public static var hasLoadedTheme: Bool { _hasLoadedTheme }
    public static var currentTheme: Theme { _theme }
    public static var primaryColor: Theme.PrimaryColor { _primaryColor }
    public static var matchSystemNightModeSetting: Bool { _matchSystemNightModeSetting }
    
    // MARK: - Styling
    
    @MainActor public static func updateThemeState(
        theme: Theme? = nil,
        primaryColor: Theme.PrimaryColor? = nil,
        matchSystemNightModeSetting: Bool? = nil
    ) {
        let targetTheme: Theme = (theme ?? _theme)
        let targetPrimaryColor: Theme.PrimaryColor = {
            switch (primaryColor, Theme.PrimaryColor(color: color(for: .defaultPrimary, in: targetTheme, with: _primaryColor))) {
                case (.some(let primaryColor), _): return primaryColor
                case (.none, .some(let defaultPrimaryColor)): return defaultPrimaryColor
                default: return _primaryColor
            }
        }()
        let targetMatchSystemNightModeSetting: Bool = {
            switch matchSystemNightModeSetting {
                case .some(let value): return value
                case .none: return _matchSystemNightModeSetting
            }
        }()
        let themeChanged: Bool = (_theme != targetTheme || _primaryColor != targetPrimaryColor)
        let matchSystemChanged: Bool = (_matchSystemNightModeSetting != targetMatchSystemNightModeSetting)
        _theme = targetTheme
        _primaryColor = targetPrimaryColor
        _hasLoadedTheme = true
        
        if matchSystemChanged {
            _matchSystemNightModeSetting = targetMatchSystemNightModeSetting
            
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
        
        // Only trigger updates if the style changed and the device is set to match the system style
        guard
            currentUserInterfaceStyle != ThemeManager.currentTheme.interfaceStyle,
            _matchSystemNightModeSetting
        else { return }
        
        // Swap to the appropriate light/dark mode
        switch (currentUserInterfaceStyle, ThemeManager.currentTheme) {
            case (.light, .classicDark): updateThemeState(theme: .classicLight, primaryColor: _primaryColor)
            case (.light, .oceanDark): updateThemeState(theme: .oceanLight, primaryColor: _primaryColor)
            case (.dark, .classicLight): updateThemeState(theme: .classicDark, primaryColor: _primaryColor)
            case (.dark, .oceanLight): updateThemeState(theme: .oceanDark, primaryColor: _primaryColor)
            default: break
        }
    }
    
    @MainActor public static func applyNavigationStyling() {
        let textPrimary: UIColor = (color(for: .textPrimary, in: currentTheme, with: primaryColor) ?? .white)
        let backgroundColor: UIColor? = color(for: .backgroundPrimary, in: currentTheme, with: primaryColor)
        
        // Set the `mainWindow.tintColor` for system screens to use the right color for text
        SNUIKit.mainWindow?.tintColor = textPrimary
        SNUIKit.mainWindow?.rootViewController?.setNeedsStatusBarAppearanceUpdate()
        
        // Update toolbars to use the right colours
        UIToolbar.appearance().barTintColor = color(for: .backgroundPrimary, in: currentTheme, with: primaryColor)
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
            let navigationBackground: ThemeValue = (navController.viewControllers.first as? ThemedNavigation)?.navigationBackground
        else { return }
        
        let navigationBackgroundColor: UIColor? = color(for: navigationBackground, in: currentTheme, with: primaryColor)
        navController.navigationBar.barTintColor = navigationBackgroundColor
        navController.navigationBar.shadowImage = navigationBackgroundColor?.toImage()
        
        let textPrimary: UIColor = (color(for: .textPrimary, in: currentTheme, with: primaryColor) ?? .white)
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
        SNUIKit.mainWindow?.overrideUserInterfaceStyle = {
            guard !ThemeManager.matchSystemNightModeSetting else { return .unspecified }
            
            switch ThemeManager.currentTheme.interfaceStyle {
                case .light: return .light
                case .dark, .unspecified: return .dark
                @unknown default: return .dark
            }
        }()
        SNUIKit.mainWindow?.backgroundColor = color(for: .backgroundPrimary, in: currentTheme, with: primaryColor)
    }
    
    public static func onThemeChange(observer: AnyObject, callback: @escaping (Theme, Theme.PrimaryColor, (ThemeValue) -> UIColor?) -> ()) {
        ThemeManager.uiRegistry.setObject(
            ThemeApplier(
                existingApplier: ThemeManager.get(for: observer),
                info: []
            ) { theme in
                callback(theme, ThemeManager.primaryColor, { value -> UIColor? in
                    ThemeManager.color(for: value, in: theme, with: ThemeManager.primaryColor)
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
                return color?.alpha(alpha)
                
            case .primary: return T.resolve(primaryColor)
            case .explicitPrimary(let explicitPrimary): return T.resolve(explicitPrimary)
            
            case .highlighted(let value, let alwaysDarken):
                let color: T? = color(for: value, in: theme, with: primaryColor)!
                
                switch (currentTheme.interfaceStyle, alwaysDarken) {
                    case (.light, _), (_, true): return color?.brighten(-0.06)
                    default: return color?.brighten(0.08)
                }
                
            case .dynamicForInterfaceStyle(let light, let dark):
                switch currentTheme.interfaceStyle {
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
        ThemeManager.uiRegistry.objectEnumerator()?.forEach { applier in
            (applier as? ThemeApplier)?.apply(theme: currentTheme)
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
    
    internal static func set<T: AnyObject>(
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

                view?[keyPath: keyPath] = ThemeManager.resolvedColor(
                    ThemeManager.color(for: value, in: currentTheme, with: primaryColor)
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
    
    internal static func set<T: AnyObject>(
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
                
                view?[keyPath: keyPath] = ThemeManager.resolvedColor(
                    ThemeManager.color(for: value, in: currentTheme, with: primaryColor)
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
    
    internal static func set<T: AttributedTextAssignable>(
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
                            let color = ThemeManager.color(for: themeValue, in: currentTheme, with: primaryColor) as UIColor?
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

// MARK: - ThemeApplier

internal class ThemeApplier {
    enum InfoKey: String {
        case keyPath
        case controlState
    }
    
    private let applyTheme: (Theme) -> ()
    private let info: [AnyHashable]
    private var otherAppliers: [ThemeApplier]?
    
    init(
        existingApplier: ThemeApplier?,
        info: [AnyHashable],
        applyTheme: @escaping (Theme) -> ()
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
        if SNUIKit.config?.isStorageValid == true || ThemeManager.hasLoadedTheme {
            self.apply(theme: ThemeManager.currentTheme, isInitialApplication: true)
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
    
    fileprivate func apply(theme: Theme, isInitialApplication: Bool = false) {
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
    var isPrimary: Bool { get }
    
    func alpha(_ alpha: Double) -> Self?
    func brighten(_ amount: Double) -> Self?
}

extension UIColor: ColorType {
    internal var isPrimary: Bool { self == UIColor.primary() }
    
    internal func alpha(_ alpha: Double) -> Self? {
        return self.withAlphaComponent(CGFloat(alpha)) as? Self
    }
    
    internal func brighten(_ amount: Double) -> Self? {
        return self.brighten(by: amount) as? Self
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
