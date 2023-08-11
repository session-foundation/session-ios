// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import GRDB
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

extension SessionCell {
    public enum Accessory: Hashable, Equatable {
        case icon(
            UIImage?,
            size: IconSize,
            customTint: ThemeValue?,
            shouldFill: Bool,
            accessibility: Accessibility?
        )
        case iconAsync(
            size: IconSize,
            customTint: ThemeValue?,
            shouldFill: Bool,
            accessibility: Accessibility?,
            setter: (UIImageView) -> Void
        )
        case toggle(
            DataSource,
            accessibility: Accessibility?
        )
        case dropDown(
            DataSource,
            accessibility: Accessibility?
        )
        case radio(
            size: RadioSize,
            isSelected: () -> Bool,
            storedSelection: Bool,
            accessibility: Accessibility?
        )
        
        case highlightingBackgroundLabel(
            title: String,
            accessibility: Accessibility?
        )
        case profile(
            id: String,
            size: ProfilePictureView.Size,
            threadVariant: SessionThread.Variant,
            customImageData: Data?,
            profile: Profile?,
            profileIcon: ProfilePictureView.ProfileIcon,
            additionalProfile: Profile?,
            additionalProfileIcon: ProfilePictureView.ProfileIcon,
            accessibility: Accessibility?
        )
        
        case search(
            placeholder: String,
            accessibility: Accessibility?,
            searchTermChanged: (String?) -> Void
        )
        case button(
            style: SessionButton.Style,
            title: String,
            accessibility: Accessibility?,
            run: (SessionButton?) -> Void
        )
        case customView(
            hashValue: AnyHashable,
            viewGenerator: () -> UIView
        )
        
        // MARK: - Convenience Vatiables
        
        var shouldFitToEdge: Bool {
            switch self {
                case .icon(_, _, _, let shouldFill, _), .iconAsync(_, _, let shouldFill, _, _):
                    return shouldFill
                default: return false
            }
        }
        
        var currentBoolValue: Bool {
            switch self {
                case .toggle(let dataSource, _), .dropDown(let dataSource, _): return dataSource.currentBoolValue
                case .radio(_, let isSelected, _, _): return isSelected()
                default: return false
            }
        }
        
        // MARK: - Conformance
        
        public func hash(into hasher: inout Hasher) {
            switch self {
                case .icon(let image, let size, let customTint, let shouldFill, let accessibility):
                    image.hash(into: &hasher)
                    size.hash(into: &hasher)
                    customTint.hash(into: &hasher)
                    shouldFill.hash(into: &hasher)
                    accessibility.hash(into: &hasher)
                    
                case .iconAsync(let size, let customTint, let shouldFill, let accessibility, _):
                    size.hash(into: &hasher)
                    customTint.hash(into: &hasher)
                    shouldFill.hash(into: &hasher)
                    accessibility.hash(into: &hasher)
                    
                case .toggle(let dataSource, let accessibility):
                    dataSource.hash(into: &hasher)
                    accessibility.hash(into: &hasher)
                
                case .dropDown(let dataSource, let accessibility):
                    dataSource.hash(into: &hasher)
                    accessibility.hash(into: &hasher)
                    
                case .radio(let size, let isSelected, let storedSelection, let accessibility):
                    size.hash(into: &hasher)
                    isSelected().hash(into: &hasher)
                    storedSelection.hash(into: &hasher)
                    accessibility.hash(into: &hasher)
                
                case .highlightingBackgroundLabel(let title, let accessibility):
                    title.hash(into: &hasher)
                    accessibility.hash(into: &hasher)
                    
                case .profile(
                    let profileId,
                    let size,
                    let threadVariant,
                    let customImageData,
                    let profile,
                    let profileIcon,
                    let additionalProfile,
                    let additionalProfileIcon,
                    let accessibility
                ):
                    profileId.hash(into: &hasher)
                    size.hash(into: &hasher)
                    threadVariant.hash(into: &hasher)
                    customImageData.hash(into: &hasher)
                    profile.hash(into: &hasher)
                    profileIcon.hash(into: &hasher)
                    additionalProfile.hash(into: &hasher)
                    additionalProfileIcon.hash(into: &hasher)
                    accessibility.hash(into: &hasher)
                    
                case .search(let placeholder, let accessibility, _):
                    placeholder.hash(into: &hasher)
                    accessibility.hash(into: &hasher)
                    
                case .button(let style, let title, let accessibility, _):
                    style.hash(into: &hasher)
                    title.hash(into: &hasher)
                    accessibility.hash(into: &hasher)
                    
                case .customView(let hashValue, _):
                    hashValue.hash(into: &hasher)
            }
        }
        
        public static func == (lhs: Accessory, rhs: Accessory) -> Bool {
            switch (lhs, rhs) {
                case (.icon(let lhsImage, let lhsSize, let lhsCustomTint, let lhsShouldFill, let lhsAccessibility), .icon(let rhsImage, let rhsSize, let rhsCustomTint, let rhsShouldFill, let rhsAccessibility)):
                    return (
                        lhsImage == rhsImage &&
                        lhsSize == rhsSize &&
                        lhsCustomTint == rhsCustomTint &&
                        lhsShouldFill == rhsShouldFill &&
                        lhsAccessibility == rhsAccessibility
                    )
                    
                case (.iconAsync(let lhsSize, let lhsCustomTint, let lhsShouldFill, let lhsAccessibility, _), .iconAsync(let rhsSize, let rhsCustomTint, let rhsShouldFill, let rhsAccessibility, _)):
                    return (
                        lhsSize == rhsSize &&
                        lhsCustomTint == rhsCustomTint &&
                        lhsShouldFill == rhsShouldFill &&
                        lhsAccessibility == rhsAccessibility
                    )
                
                case (.toggle(let lhsDataSource, let lhsAccessibility), .toggle(let rhsDataSource, let rhsAccessibility)):
                    return (
                        lhsDataSource == rhsDataSource &&
                        lhsAccessibility == rhsAccessibility
                    )
                    
                case (.dropDown(let lhsDataSource, let lhsAccessibility), .dropDown(let rhsDataSource, let rhsAccessibility)):
                    return (
                        lhsDataSource == rhsDataSource &&
                        lhsAccessibility == rhsAccessibility
                    )
                    
                case (.radio(let lhsSize, let lhsIsSelected, let lhsStoredSelection, let lhsAccessibility), .radio(let rhsSize, let rhsIsSelected, let rhsStoredSelection, let rhsAccessibility)):
                    return (
                        lhsSize == rhsSize &&
                        lhsIsSelected() == rhsIsSelected() &&
                        lhsStoredSelection == rhsStoredSelection &&
                        lhsAccessibility == rhsAccessibility
                    )
                    
                case (.highlightingBackgroundLabel(let lhsTitle, let lhsAccessibility), .highlightingBackgroundLabel(let rhsTitle, let rhsAccessibility)):
                    return (
                        lhsTitle == rhsTitle &&
                        lhsAccessibility == rhsAccessibility
                    )
                    
                case (
                    .profile(
                        let lhsProfileId,
                        let lhsSize,
                        let lhsThreadVariant,
                        let lhsCustomImageData,
                        let lhsProfile,
                        let lhsProfileIcon,
                        let lhsAdditionalProfile,
                        let lhsAdditionalProfileIcon,
                        let lhsAccessibility
                    ),
                    .profile(
                        let rhsProfileId,
                        let rhsSize,
                        let rhsThreadVariant,
                        let rhsCustomImageData,
                        let rhsProfile,
                        let rhsProfileIcon,
                        let rhsAdditionalProfile,
                        let rhsAdditionalProfileIcon,
                        let rhsAccessibility
                    )
                ):
                    return (
                        lhsProfileId == rhsProfileId &&
                        lhsSize == rhsSize &&
                        lhsThreadVariant == rhsThreadVariant &&
                        lhsCustomImageData == rhsCustomImageData &&
                        lhsProfile == rhsProfile &&
                        lhsProfileIcon == rhsProfileIcon &&
                        lhsAdditionalProfile == rhsAdditionalProfile &&
                        lhsAdditionalProfileIcon == rhsAdditionalProfileIcon &&
                        lhsAccessibility == rhsAccessibility
                    )
                    
                case (.search(let lhsPlaceholder, let lhsAccessibility, _), .search(let rhsPlaceholder, let rhsAccessibility, _)):
                    return (
                        lhsPlaceholder == rhsPlaceholder &&
                        lhsAccessibility == rhsAccessibility
                    )
                    
                case (.button(let lhsStyle, let lhsTitle, let lhsAccessibility, _), .button(let rhsStyle, let rhsTitle, let rhsAccessibility, _)):
                    return (
                        lhsStyle == rhsStyle &&
                        lhsTitle == rhsTitle &&
                        lhsAccessibility == rhsAccessibility
                    )
                    
                case (.customView(let lhsHashValue, _), .customView(let rhsHashValue, _)):
                    return (
                        lhsHashValue.hashValue == rhsHashValue.hashValue
                    )
                
                default: return false
            }
        }
    }
}

// MARK: - Convenience Types

/// These are here because XCode doesn't realy like default values within enums so auto-complete and syntax
/// highlighting don't work properly
extension SessionCell.Accessory {
    // MARK: - .icon Variants
    
    public static func icon(_ image: UIImage?) -> SessionCell.Accessory {
        return .icon(image, size: .medium, customTint: nil, shouldFill: false, accessibility: nil)
    }
    
    public static func icon(_ image: UIImage?, customTint: ThemeValue) -> SessionCell.Accessory {
        return .icon(image, size: .medium, customTint: customTint, shouldFill: false, accessibility: nil)
    }
    
    public static func icon(_ image: UIImage?, size: IconSize) -> SessionCell.Accessory {
        return .icon(image, size: size, customTint: nil, shouldFill: false, accessibility: nil)
    }
    
    public static func icon(_ image: UIImage?, size: IconSize, customTint: ThemeValue) -> SessionCell.Accessory {
        return .icon(image, size: size, customTint: customTint, shouldFill: false, accessibility: nil)
    }
    
    public static func icon(_ image: UIImage?, shouldFill: Bool) -> SessionCell.Accessory {
        return .icon(image, size: .medium, customTint: nil, shouldFill: shouldFill, accessibility: nil)
    }
    
    public static func icon(_ image: UIImage?, accessibility: Accessibility) -> SessionCell.Accessory {
        return .icon(image, size: .medium, customTint: nil, shouldFill: false, accessibility: accessibility)
    }
    
    // MARK: - .iconAsync Variants
    
    public static func iconAsync(_ setter: @escaping (UIImageView) -> Void) -> SessionCell.Accessory {
        return .iconAsync(size: .medium, customTint: nil, shouldFill: false, accessibility: nil, setter: setter)
    }
    
    public static func iconAsync(customTint: ThemeValue, _ setter: @escaping (UIImageView) -> Void) -> SessionCell.Accessory {
        return .iconAsync(size: .medium, customTint: customTint, shouldFill: false, accessibility: nil, setter: setter)
    }
    
    public static func iconAsync(size: IconSize, setter: @escaping (UIImageView) -> Void) -> SessionCell.Accessory {
        return .iconAsync(size: size, customTint: nil, shouldFill: false, accessibility: nil, setter: setter)
    }
    
    public static func iconAsync(shouldFill: Bool, setter: @escaping (UIImageView) -> Void) -> SessionCell.Accessory {
        return .iconAsync(size: .medium, customTint: nil, shouldFill: shouldFill, accessibility: nil, setter: setter)
    }
    
    public static func iconAsync(size: IconSize, customTint: ThemeValue, setter: @escaping (UIImageView) -> Void) -> SessionCell.Accessory {
        return .iconAsync(size: size, customTint: customTint, shouldFill: false, accessibility: nil, setter: setter)
    }
    
    public static func iconAsync(size: IconSize, shouldFill: Bool, setter: @escaping (UIImageView) -> Void) -> SessionCell.Accessory {
        return .iconAsync(size: size, customTint: nil, shouldFill: shouldFill, accessibility: nil, setter: setter)
    }
    
    // MARK: - .toggle Variants
    
    public static func toggle(_ dataSource: DataSource) -> SessionCell.Accessory {
        return .toggle(dataSource, accessibility: nil)
    }
    
    // MARK: - .dropDown Variants
    
    public static func dropDown(_ dataSource: DataSource) -> SessionCell.Accessory {
        return .dropDown(dataSource, accessibility: nil)
    }
    
    // MARK: - .radio Variants
    
    public static func radio(isSelected: @escaping () -> Bool) -> SessionCell.Accessory {
        return .radio(size: .medium, isSelected: isSelected, storedSelection: false, accessibility: nil)
    }
    
    public static func radio(isSelected: @escaping () -> Bool, storedSelection: Bool) -> SessionCell.Accessory {
        return .radio(size: .medium, isSelected: isSelected, storedSelection: storedSelection, accessibility: nil)
    }
    
    // MARK: - .highlightingBackgroundLabel Variants
    
    public static func highlightingBackgroundLabel(title: String) -> SessionCell.Accessory {
        return .highlightingBackgroundLabel(title: title, accessibility: nil)
    }
    
    // MARK: - .profile Variants
    
    public static func profile(id: String, profile: Profile?) -> SessionCell.Accessory {
        return .profile(
            id: id,
            size: .list,
            threadVariant: .contact,
            customImageData: nil,
            profile: profile,
            profileIcon: .none,
            additionalProfile: nil,
            additionalProfileIcon: .none,
            accessibility: nil
        )
    }
    
    public static func profile(id: String, size: ProfilePictureView.Size, profile: Profile?) -> SessionCell.Accessory {
        return .profile(
            id: id,
            size: size,
            threadVariant: .contact,
            customImageData: nil,
            profile: profile,
            profileIcon: .none,
            additionalProfile: nil,
            additionalProfileIcon: .none,
            accessibility: nil
        )
    }
    
    // MARK: - .search Variants
    
    public static func search(placeholder: String, searchTermChanged: @escaping (String?) -> Void) -> SessionCell.Accessory {
        return .search(placeholder: placeholder, accessibility: nil, searchTermChanged: searchTermChanged)
    }
    
    // MARK: - .button Variants
    
    public static func button(style: SessionButton.Style, title: String, run: @escaping (SessionButton?) -> Void) -> SessionCell.Accessory {
        return .button(style: style, title: title, accessibility: nil, run: run)
    }
}

// MARK: - SessionCell.Accessory.DataSource

extension SessionCell.Accessory {
    public enum DataSource: Hashable, Equatable {
        case boolValue(key: String, value: Bool, oldValue: Bool)
        case dynamicString(() -> String?)
        
        static func boolValue(_ value: Bool, oldValue: Bool) -> DataSource {
            return .boolValue(key: "", value: value, oldValue: oldValue)
        }
        
        static func boolValue(key: Setting.BoolKey, value: Bool, oldValue: Bool) -> DataSource {
            return .boolValue(key: key.rawValue, value: value, oldValue: oldValue)
        }
        
        // MARK: - Convenience
        
        public var currentBoolValue: Bool {
            switch self {
                case .boolValue(_, let value, _): return value
                case .dynamicString: return false
            }
        }
        
        public var oldBoolValue: Bool {
            switch self {
                case .boolValue(_, _, let oldValue): return oldValue
                default: return false
            }
        }
        
        public var currentStringValue: String? {
            switch self {
                case .dynamicString(let value): return value()
                default: return nil
            }
        }
        
        // MARK: - Conformance
        
        public func hash(into hasher: inout Hasher) {
            switch self {
                case .boolValue(let key, let value, let oldValue):
                    key.hash(into: &hasher)
                    value.hash(into: &hasher)
                    oldValue.hash(into: &hasher)
                    
                case .dynamicString(let generator): generator().hash(into: &hasher)
            }
        }
        
        public static func == (lhs: DataSource, rhs: DataSource) -> Bool {
            switch (lhs, rhs) {
                case (.boolValue(let lhsKey, let lhsValue, let lhsOldValue), .boolValue(let rhsKey, let rhsValue, let rhsOldValue)):
                    return (
                        lhsKey == rhsKey &&
                        lhsValue == rhsValue &&
                        lhsOldValue == rhsOldValue
                    )
                    
                case (.dynamicString(let lhsGenerator), .dynamicString(let rhsGenerator)):
                    return (lhsGenerator() == rhsGenerator())
                    
                default: return false
            }
        }
    }
}

// MARK: - SessionCell.Accessory.RadioSize

extension SessionCell.Accessory {
    public enum RadioSize {
        case small
        case medium
        
        var borderSize: CGFloat {
            switch self {
                case .small: return 20
                case .medium: return 26
            }
        }
        
        var selectionSize: CGFloat {
            switch self {
                case .small: return 15
                case .medium: return 20
            }
        }
    }
}
