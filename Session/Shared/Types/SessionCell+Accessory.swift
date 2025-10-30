// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import GRDB
import Lucide
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

public extension SessionCell {
    enum AccessoryConfig {}
    
    class Accessory: Hashable, Equatable {
        open var viewIdentifier: String {
            fatalError("Subclasses of Accessory must provide a viewIdentifier.")
        }
        
        public let accessibility: Accessibility?
        public var shouldFitToEdge: Bool { false }
        public var boolValue: Bool { false }
        
        fileprivate init(accessibility: Accessibility?) {
            self.accessibility = accessibility
        }
        
        public func hash(into hasher: inout Hasher) {}
        fileprivate func isEqual(to other: SessionCell.Accessory) -> Bool { return false }
        
        public static func == (lhs: SessionCell.Accessory, rhs: SessionCell.Accessory) -> Bool {
            return lhs.isEqual(to: rhs)
        }
    }
}

// MARK: - DSL

public extension SessionCell.Accessory {
    static func icon(
        _ icon: Lucide.Icon,
        size: IconSize = .medium,
        customTint: ThemeValue? = nil,
        shouldFill: Bool = false,
        pinEdges: [UIView.HorizontalEdge] = [.leading, .trailing],
        accessibility: Accessibility? = nil
    ) -> SessionCell.Accessory {
        return SessionCell.AccessoryConfig.Icon(
            icon: icon,
            image: nil,
            iconSize: size,
            customTint: customTint,
            shouldFill: shouldFill,
            pinEdges: pinEdges,
            accessibility: accessibility
        )
    }
    
    static func icon(
        _ image: UIImage?,
        size: IconSize = .medium,
        customTint: ThemeValue? = nil,
        shouldFill: Bool = false,
        pinEdges: [UIView.HorizontalEdge] = [.leading, .trailing],
        accessibility: Accessibility? = nil
    ) -> SessionCell.Accessory {
        return SessionCell.AccessoryConfig.Icon(
            icon: nil,
            image: image,
            iconSize: size,
            customTint: customTint,
            shouldFill: shouldFill,
            pinEdges: pinEdges,
            accessibility: accessibility
        )
    }
    
    static func iconAsync(
        size: IconSize = .medium,
        source: ImageDataManager.DataSource?,
        customTint: ThemeValue? = nil,
        shouldFill: Bool = false,
        pinEdges: [UIView.HorizontalEdge] = [.leading, .trailing],
        accessibility: Accessibility? = nil
    ) -> SessionCell.Accessory {
        return SessionCell.AccessoryConfig.IconAsync(
            iconSize: size,
            source: source,
            customTint: customTint,
            shouldFill: shouldFill,
            pinEdges: pinEdges,
            accessibility: accessibility
        )
    }
    
    static func toggle(
        _ value: Bool,
        oldValue: Bool?,
        accessibility: Accessibility = Accessibility(identifier: "Switch")
    ) -> SessionCell.Accessory {
        return SessionCell.AccessoryConfig.Toggle(
            value: value,
            oldValue: (oldValue ?? value),
            accessibility: accessibility
        )
    }
    
    static func dropDown(
        _ dynamicString: @escaping () -> String?,
        accessibility: Accessibility? = nil
    ) -> SessionCell.Accessory {
        return SessionCell.AccessoryConfig.DropDown(
            dynamicString: dynamicString,
            accessibility: accessibility
        )
    }
    
    static func radio(
        _ size: SessionCell.AccessoryConfig.Radio.Size = .medium,
        isSelected: Bool,
        wasSavedSelection: Bool = false,
        accessibility: Accessibility = Accessibility(identifier: "Radio")
    ) -> SessionCell.Accessory {
        return SessionCell.AccessoryConfig.Radio(
            size: size,
            isSelected: isSelected,
            wasSavedSelection: wasSavedSelection,
            accessibility: accessibility
        )
    }
    
    static func highlightingBackgroundLabel(
        title: String,
        accessibility: Accessibility? = nil
    ) -> SessionCell.Accessory {
        return SessionCell.AccessoryConfig.HighlightingBackgroundLabel(
            title: title,
            accessibility: accessibility
        )
    }
    
    static func highlightingBackgroundLabelAndRadio(
        title: String,
        radioSize: SessionCell.AccessoryConfig.HighlightingBackgroundLabelAndRadio.Size = .medium,
        isSelected: Bool,
        wasSavedSelection: Bool = false,
        labelAccessibility: Accessibility? = nil,
        radioAccessibility: Accessibility? = nil
    ) -> SessionCell.Accessory {
        return SessionCell.AccessoryConfig.HighlightingBackgroundLabelAndRadio(
            title: title,
            radioSize: radioSize,
            isSelected: isSelected,
            wasSavedSelection: wasSavedSelection,
            labelAccessibility: labelAccessibility,
            radioAccessibility: radioAccessibility
        )
    }
    
    static func profile(
        id: String,
        size: ProfilePictureView.Info.Size = .list,
        threadVariant: SessionThread.Variant = .contact,
        displayPictureUrl: String? = nil,
        profile: Profile? = nil,
        profileIcon: ProfilePictureView.Info.ProfileIcon = .none,
        additionalProfile: Profile? = nil,
        additionalProfileIcon: ProfilePictureView.Info.ProfileIcon = .none,
        accessibility: Accessibility? = nil
    ) -> SessionCell.Accessory {
        return SessionCell.AccessoryConfig.DisplayPicture(
            id: id,
            size: size,
            threadVariant: threadVariant,
            displayPictureUrl: displayPictureUrl,
            profile: profile,
            profileIcon: profileIcon,
            additionalProfile: additionalProfile,
            additionalProfileIcon: additionalProfileIcon,
            accessibility: accessibility
        )
    }
    
    static func search(
        placeholder: String,
        accessibility: Accessibility? = nil,
        searchTermChanged: @escaping (String?) -> Void
    ) -> SessionCell.Accessory {
        return SessionCell.AccessoryConfig.Search(
            placeholder: placeholder,
            searchTermChanged: searchTermChanged,
            accessibility: accessibility
        )
    }
    
    static func button(
        style: SessionButton.Style,
        title: String,
        accessibility: Accessibility? = nil,
        run: @escaping (SessionButton?) -> Void
    ) -> SessionCell.Accessory {
        return SessionCell.AccessoryConfig.Button(
            style: style,
            title: title,
            run: run,
            accessibility: accessibility
        )
    }
    
    static func custom<T: SessionCell.Accessory.CustomViewInfo>(
        info: T,
        accessibility: Accessibility? = nil
    ) -> SessionCell.Accessory {
        return SessionCell.AccessoryConfig.Custom(
            info: info,
            accessibility: accessibility
        )
    }
}

// MARK: Structs

// stringlint:ignore_contents
public extension SessionCell.AccessoryConfig {
    // MARK: - Icon
    
    class Icon: SessionCell.Accessory {
        override public var viewIdentifier: String {
            "icon-\(iconSize.size)\(shouldFill ? "-fill" : "")"
        }
        
        public let icon: Lucide.Icon?
        public let image: UIImage?
        public let iconSize: IconSize
        public let customTint: ThemeValue?
        public let shouldFill: Bool
        public let pinEdges: [UIView.HorizontalEdge]
        
        fileprivate init(
            icon: Lucide.Icon?,
            image: UIImage?,
            iconSize: IconSize,
            customTint: ThemeValue?,
            shouldFill: Bool,
            pinEdges: [UIView.HorizontalEdge],
            accessibility: Accessibility?
        ) {
            self.icon = icon
            self.image = image
            self.iconSize = iconSize
            self.customTint = customTint
            self.shouldFill = shouldFill
            self.pinEdges = pinEdges
            
            super.init(accessibility: accessibility)
        }
        
        // MARK: - Conformance
        
        override public func hash(into hasher: inout Hasher) {
            icon.hash(into: &hasher)
            image.hash(into: &hasher)
            iconSize.hash(into: &hasher)
            customTint.hash(into: &hasher)
            shouldFill.hash(into: &hasher)
            pinEdges.hash(into: &hasher)
            accessibility.hash(into: &hasher)
        }
        
        override fileprivate func isEqual(to other: SessionCell.Accessory) -> Bool {
            guard let rhs: Icon = other as? Icon else { return false }
            
            return (
                icon == rhs.icon &&
                image == rhs.image &&
                iconSize == rhs.iconSize &&
                customTint == rhs.customTint &&
                shouldFill == rhs.shouldFill &&
                pinEdges == rhs.pinEdges &&
                accessibility == rhs.accessibility
                
            )
        }
    }
    
    // MARK: - IconAsync
    
    class IconAsync: SessionCell.Accessory {
        override public var viewIdentifier: String { "iconAsync" }
        
        public let iconSize: IconSize
        public let source: ImageDataManager.DataSource?
        public let customTint: ThemeValue?
        public let shouldFill: Bool
        public let pinEdges: [UIView.HorizontalEdge]
        
        fileprivate init(
            iconSize: IconSize,
            source: ImageDataManager.DataSource?,
            customTint: ThemeValue?,
            shouldFill: Bool,
            pinEdges: [UIView.HorizontalEdge],
            accessibility: Accessibility?
        ) {
            self.iconSize = iconSize
            self.source = source
            self.customTint = customTint
            self.shouldFill = shouldFill
            self.pinEdges = pinEdges
            
            super.init(accessibility: accessibility)
        }
        
        // MARK: - Conformance
        
        override public func hash(into hasher: inout Hasher) {
            iconSize.hash(into: &hasher)
            source?.hash(into: &hasher)
            customTint.hash(into: &hasher)
            shouldFill.hash(into: &hasher)
            pinEdges.hash(into: &hasher)
            accessibility.hash(into: &hasher)
        }
        
        override fileprivate func isEqual(to other: SessionCell.Accessory) -> Bool {
            guard let rhs: IconAsync = other as? IconAsync else { return false }
            
            return (
                iconSize == rhs.iconSize &&
                source == rhs.source &&
                customTint == rhs.customTint &&
                shouldFill == rhs.shouldFill &&
                pinEdges == rhs.pinEdges &&
                accessibility == rhs.accessibility
            )
        }
    }
    
    // MARK: - Toggle
    
    class Toggle: SessionCell.Accessory {
        override public var viewIdentifier: String { "toggle" }
        
        public let value: Bool
        public let oldValue: Bool
        
        override public var boolValue: Bool { value }
        
        fileprivate init(
            value: Bool,
            oldValue: Bool,
            accessibility: Accessibility?
        ) {
            self.value = value
            self.oldValue = oldValue
            
            super.init(accessibility: accessibility)
        }
        
        // MARK: - Conformance
        
        override public func hash(into hasher: inout Hasher) {
            value.hash(into: &hasher)
            oldValue.hash(into: &hasher)
            accessibility.hash(into: &hasher)
        }
        
        override fileprivate func isEqual(to other: SessionCell.Accessory) -> Bool {
            guard let rhs: Toggle = other as? Toggle else { return false }
            
            return (
                value == rhs.value &&
                oldValue == rhs.oldValue &&
                accessibility == rhs.accessibility
            )
        }
    }
    
    // MARK: - DropDown
    
    class DropDown: SessionCell.Accessory {
        override public var viewIdentifier: String { "dropDown" }
        
        public let dynamicString: () -> String?
        
        fileprivate init(
            dynamicString: @escaping () -> String?,
            accessibility: Accessibility?
        ) {
            self.dynamicString = dynamicString
            
            super.init(accessibility: accessibility)
        }
        
        // MARK: - Conformance
        
        override public func hash(into hasher: inout Hasher) {
            dynamicString().hash(into: &hasher)
            accessibility.hash(into: &hasher)
        }
        
        override fileprivate func isEqual(to other: SessionCell.Accessory) -> Bool {
            guard let rhs: DropDown = other as? DropDown else { return false }
            
            return (
                dynamicString() == rhs.dynamicString() &&
                accessibility == rhs.accessibility
            )
        }
    }
    
    // MARK: - Radio
    
    class Radio: SessionCell.Accessory {
        override public var viewIdentifier: String { "radio-\(size.selectionSize)" }
        
        public enum Size: Hashable, Equatable {
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
        
        public let size: Size
        public let isSelected: Bool
        public let wasSavedSelection: Bool
        
        override public var boolValue: Bool { isSelected }
        
        fileprivate init(
            size: Size,
            isSelected: Bool,
            wasSavedSelection: Bool,
            accessibility: Accessibility?
        ) {
            self.size = size
            self.isSelected = isSelected
            self.wasSavedSelection = wasSavedSelection
            
            super.init(accessibility: accessibility)
        }
        
        // MARK: - Conformance
        
        override fileprivate func isEqual(to other: SessionCell.Accessory) -> Bool {
            guard let rhs: Radio = other as? Radio else { return false }
            
            return (
                size == rhs.size &&
                isSelected == rhs.isSelected &&
                wasSavedSelection == rhs.wasSavedSelection &&
                accessibility == rhs.accessibility
            )
        }
    }
    
    // MARK: - HighlightingBackgroundLabel
    
    class HighlightingBackgroundLabel: SessionCell.Accessory {
        override public var viewIdentifier: String { "highlightingBackgroundLabel" }
        
        public let title: String
        
        init(
            title: String,
            accessibility: Accessibility?
        ) {
            self.title = title
            
            super.init(accessibility: accessibility)
        }
        
        // MARK: - Conformance
        
        override public func hash(into hasher: inout Hasher) {
            title.hash(into: &hasher)
            accessibility.hash(into: &hasher)
        }
        
        override fileprivate func isEqual(to other: SessionCell.Accessory) -> Bool {
            guard let rhs: HighlightingBackgroundLabel = other as? HighlightingBackgroundLabel else {
                return false
            }
            
            return (
                title == rhs.title &&
                accessibility == rhs.accessibility
            )
        }
    }
    
    // MARK: - HighlightingBackgroundLabelAndRadio
    
    class HighlightingBackgroundLabelAndRadio: SessionCell.Accessory {
        override public var viewIdentifier: String {
            "highlightingBackgroundLabelAndRadio-\(size.selectionSize)"
        }
        
        public enum Size: Hashable, Equatable {
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
        
        public let title: String
        public let size: Size
        public let isSelected: Bool
        public let wasSavedSelection: Bool
        public let labelAccessibility: Accessibility?
        
        override public var boolValue: Bool { isSelected }
        
        fileprivate init(
            title: String,
            radioSize: Size,
            isSelected: Bool,
            wasSavedSelection: Bool,
            labelAccessibility: Accessibility?,
            radioAccessibility: Accessibility?
        ) {
            self.title = title
            self.size = radioSize
            self.isSelected = isSelected
            self.wasSavedSelection = wasSavedSelection
            self.labelAccessibility = labelAccessibility
            
            super.init(accessibility: radioAccessibility)
        }
        
        // MARK: - Conformance
        
        override fileprivate func isEqual(to other: SessionCell.Accessory) -> Bool {
            guard let rhs: HighlightingBackgroundLabelAndRadio = other as? HighlightingBackgroundLabelAndRadio else { return false }
            
            return (
                title == rhs.title &&
                size == rhs.size &&
                isSelected == rhs.isSelected &&
                wasSavedSelection == rhs.wasSavedSelection &&
                accessibility == rhs.accessibility &&
                labelAccessibility == rhs.labelAccessibility
            )
        }
    }
    
    // MARK: - DisplayPicture
    
    class DisplayPicture: SessionCell.Accessory {
        override public var viewIdentifier: String { "displayPicture-\(size.viewSize)" }
        
        public let id: String
        public let size: ProfilePictureView.Info.Size
        public let threadVariant: SessionThread.Variant
        public let displayPictureUrl: String?
        public let profile: Profile?
        public let profileIcon: ProfilePictureView.Info.ProfileIcon
        public let additionalProfile: Profile?
        public let additionalProfileIcon: ProfilePictureView.Info.ProfileIcon
        
        fileprivate init(
            id: String,
            size: ProfilePictureView.Info.Size,
            threadVariant: SessionThread.Variant,
            displayPictureUrl: String?,
            profile: Profile?,
            profileIcon: ProfilePictureView.Info.ProfileIcon,
            additionalProfile: Profile?,
            additionalProfileIcon: ProfilePictureView.Info.ProfileIcon,
            accessibility: Accessibility?
        ) {
            self.id = id
            self.size = size
            self.threadVariant = threadVariant
            self.displayPictureUrl = displayPictureUrl
            self.profile = profile
            self.profileIcon = profileIcon
            self.additionalProfile = additionalProfile
            self.additionalProfileIcon = additionalProfileIcon
            
            super.init(accessibility: accessibility)
        }
        
        // MARK: - Conformance
        
        override public func hash(into hasher: inout Hasher) {
            id.hash(into: &hasher)
            size.hash(into: &hasher)
            threadVariant.hash(into: &hasher)
            displayPictureUrl.hash(into: &hasher)
            profile.hash(into: &hasher)
            profileIcon.hash(into: &hasher)
            additionalProfile.hash(into: &hasher)
            additionalProfileIcon.hash(into: &hasher)
            accessibility.hash(into: &hasher)
        }
        
        override fileprivate func isEqual(to other: SessionCell.Accessory) -> Bool {
            guard let rhs: DisplayPicture = other as? DisplayPicture else { return false }
            
            return (
                id == rhs.id &&
                size == rhs.size &&
                threadVariant == rhs.threadVariant &&
                displayPictureUrl == rhs.displayPictureUrl &&
                profile == rhs.profile &&
                profileIcon == rhs.profileIcon &&
                additionalProfile == rhs.additionalProfile &&
                additionalProfileIcon == rhs.additionalProfileIcon &&
                accessibility == rhs.accessibility
            )
        }
    }
    
    class Search: SessionCell.Accessory {
        override public var viewIdentifier: String { "search" }
        
        public let placeholder: String
        public let searchTermChanged: (String?) -> Void
        
        fileprivate init(
            placeholder: String,
            searchTermChanged: @escaping (String?) -> Void,
            accessibility: Accessibility?
        ) {
            self.placeholder = placeholder
            self.searchTermChanged = searchTermChanged
            
            super.init(accessibility: accessibility)
        }
        
        // MARK: - Conformance
        
        override public func hash(into hasher: inout Hasher) {
            placeholder.hash(into: &hasher)
            accessibility.hash(into: &hasher)
        }
        
        override fileprivate func isEqual(to other: SessionCell.Accessory) -> Bool {
            return (
                other is Search &&
                placeholder == (other as? Search)?.placeholder &&
                accessibility == (other as? Search)?.accessibility
            )
        }
    }
    
    class Button: SessionCell.Accessory {
        override public var viewIdentifier: String { "button" }
        
        public let style: SessionButton.Style
        public let title: String
        public let run: (SessionButton?) -> Void
        
        fileprivate init(
            style: SessionButton.Style,
            title: String,
            run: @escaping (SessionButton?) -> Void,
            accessibility: Accessibility?
        ) {
            self.style = style
            self.title = title
            self.run = run
            
            super.init(accessibility: accessibility)
        }
        
        // MARK: - Conformance
        
        override public func hash(into hasher: inout Hasher) {
            style.hash(into: &hasher)
            title.hash(into: &hasher)
            accessibility.hash(into: &hasher)
        }
        
        override fileprivate func isEqual(to other: SessionCell.Accessory) -> Bool {
            return (
                other is Button &&
                style == (other as? Button)?.style &&
                title == (other as? Button)?.title &&
                accessibility == (other as? Button)?.accessibility
            )
        }
    }
    
    class Custom<T: SessionCell.Accessory.CustomViewInfo>: SessionCell.Accessory, AnyCustom {
        override public var viewIdentifier: String { "custom" }
        
        public var size: SessionCell.Accessory.Size { T.View.size }
        
        public let info: T
        
        fileprivate init(
            info: T,
            accessibility: Accessibility?
        ) {
            self.info = info
            
            super.init(accessibility: accessibility)
        }
        
        // MARK: - Conformance
        
        public func createView(maxContentWidth: CGFloat, using dependencies: Dependencies) -> UIView {
            return info.createView(maxContentWidth: maxContentWidth, using: dependencies)
        }
        
        override public func hash(into hasher: inout Hasher) {
            info.hash(into: &hasher)
            accessibility.hash(into: &hasher)
        }
        
        override fileprivate func isEqual(to other: SessionCell.Accessory) -> Bool {
            return (
                other is Custom &&
                info == (other as? Custom)?.info &&
                accessibility == (other as? Custom)?.accessibility
            )
        }
    }
    
    protocol AnyCustom {
        var size: SessionCell.Accessory.Size { get }
        var accessibility: Accessibility? { get }
        
        func createView(maxContentWidth: CGFloat, using dependencies: Dependencies) -> UIView
    }
}

// MARK: - SessionCell.Accessory.CustomView

public extension SessionCell.Accessory {
    enum Size {
        case fixed(width: CGFloat, height: CGFloat)
        case minWidth(height: CGFloat)
        case fillWidth(height: CGFloat)
        case fillWidthWrapHeight
    }
}

public extension SessionCell.Accessory {
    protocol CustomView: UIView {
        associatedtype Info
        
        static var size: Size { get }
        
        static func create(maxContentWidth: CGFloat, using dependencies: Dependencies) -> Self
        func update(with info: Info)
    }
    
    protocol CustomViewInfo: Equatable, Hashable {
        associatedtype View: CustomView where View.Info == Self
    }
}

public extension SessionCell.Accessory.CustomViewInfo {
    func createView(maxContentWidth: CGFloat, using dependencies: Dependencies) -> UIView {
        let view: View = View.create(maxContentWidth: maxContentWidth, using: dependencies)
        view.update(with: self)
        
        return view
    }
}
