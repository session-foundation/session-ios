// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import DifferenceKit
import SessionUIKit

extension SessionCell {
    public struct Info<ID: Hashable & Differentiable>: Equatable, Hashable, Differentiable {
        let id: ID
        let position: Position
        let leftAccessory: SessionCell.Accessory?
        let title: TextInfo?
        let subtitle: TextInfo?
        let rightAccessory: SessionCell.Accessory?
        let styling: StyleInfo
        let isEnabled: Bool
        let accessibility: Accessibility?
        let confirmationInfo: ConfirmationModal.Info?
        let onTap: (() -> Void)?
        let onTapView: ((UIView?) -> Void)?
        
        var currentBoolValue: Bool {
            return (
                (leftAccessory?.currentBoolValue ?? false) ||
                (rightAccessory?.currentBoolValue ?? false)
            )
        }
        
        // MARK: - Initialization
        
        init(
            id: ID,
            position: Position = .individual,
            leftAccessory: SessionCell.Accessory? = nil,
            title: SessionCell.TextInfo? = nil,
            subtitle: SessionCell.TextInfo? = nil,
            rightAccessory: SessionCell.Accessory? = nil,
            styling: StyleInfo = StyleInfo(),
            isEnabled: Bool = true,
            accessibility: Accessibility? = nil,
            confirmationInfo: ConfirmationModal.Info? = nil,
            onTap: (() -> Void)? = nil,
            onTapView: ((UIView?) -> Void)? = nil
        ) {
            self.id = id
            self.position = position
            self.leftAccessory = leftAccessory
            self.title = title
            self.subtitle = subtitle
            self.rightAccessory = rightAccessory
            self.styling = styling
            self.isEnabled = isEnabled
            self.accessibility = accessibility
            self.confirmationInfo = confirmationInfo
            self.onTap = onTap
            self.onTapView = onTapView
        }
        
        // MARK: - Conformance
        
        public var differenceIdentifier: ID { id }
        
        public func hash(into hasher: inout Hasher) {
            id.hash(into: &hasher)
            position.hash(into: &hasher)
            leftAccessory.hash(into: &hasher)
            title.hash(into: &hasher)
            subtitle.hash(into: &hasher)
            rightAccessory.hash(into: &hasher)
            styling.hash(into: &hasher)
            isEnabled.hash(into: &hasher)
            accessibility.hash(into: &hasher)
            confirmationInfo.hash(into: &hasher)
        }
        
        public static func == (lhs: Info<ID>, rhs: Info<ID>) -> Bool {
            return (
                lhs.id == rhs.id &&
                lhs.position == rhs.position &&
                lhs.leftAccessory == rhs.leftAccessory &&
                lhs.title == rhs.title &&
                lhs.subtitle == rhs.subtitle &&
                lhs.rightAccessory == rhs.rightAccessory &&
                lhs.styling == rhs.styling &&
                lhs.isEnabled == rhs.isEnabled &&
                lhs.accessibility == rhs.accessibility
            )
        }
        
        // MARK: - Convenience
        
        public func updatedPosition(for index: Int, count: Int) -> Info {
            return Info(
                id: id,
                position: Position.with(index, count: count),
                leftAccessory: leftAccessory,
                title: title,
                subtitle: subtitle,
                rightAccessory: rightAccessory,
                styling: styling,
                isEnabled: isEnabled,
                accessibility: accessibility,
                confirmationInfo: confirmationInfo,
                onTap: onTap,
                onTapView: onTapView
            )
        }
    }
}

// MARK: - Convenience Initializers

public extension SessionCell.Info {
    // Accessory, () -> Void

    init(
        id: ID,
        position: Position = .individual,
        accessory: SessionCell.Accessory,
        styling: SessionCell.StyleInfo = SessionCell.StyleInfo(),
        isEnabled: Bool = true,
        accessibility: Accessibility? = nil,
        confirmationInfo: ConfirmationModal.Info? = nil,
        onTap: (() -> Void)? = nil
    ) {
        self.id = id
        self.position = position
        self.leftAccessory = accessory
        self.title = nil
        self.subtitle = nil
        self.rightAccessory = nil
        self.styling = styling
        self.isEnabled = isEnabled
        self.accessibility = accessibility
        self.confirmationInfo = confirmationInfo
        self.onTap = onTap
        self.onTapView = nil
    }

    // leftAccessory, rightAccessory

    init(
        id: ID,
        position: Position = .individual,
        leftAccessory: SessionCell.Accessory,
        rightAccessory: SessionCell.Accessory,
        styling: SessionCell.StyleInfo = SessionCell.StyleInfo(),
        isEnabled: Bool = true,
        accessibility: Accessibility? = nil,
        confirmationInfo: ConfirmationModal.Info? = nil
    ) {
        self.id = id
        self.position = position
        self.leftAccessory = leftAccessory
        self.title = nil
        self.subtitle = nil
        self.rightAccessory = rightAccessory
        self.styling = styling
        self.isEnabled = isEnabled
        self.accessibility = accessibility
        self.confirmationInfo = confirmationInfo
        self.onTap = nil
        self.onTapView = nil
    }

    // String, () -> Void

    init(
        id: ID,
        position: Position = .individual,
        leftAccessory: SessionCell.Accessory? = nil,
        title: String,
        rightAccessory: SessionCell.Accessory? = nil,
        styling: SessionCell.StyleInfo = SessionCell.StyleInfo(),
        isEnabled: Bool = true,
        accessibility: Accessibility? = nil,
        confirmationInfo: ConfirmationModal.Info? = nil,
        onTap: (() -> Void)? = nil
    ) {
        self.id = id
        self.position = position
        self.leftAccessory = leftAccessory
        self.title = SessionCell.TextInfo(title, font: .title)
        self.subtitle = nil
        self.rightAccessory = rightAccessory
        self.styling = styling
        self.isEnabled = isEnabled
        self.accessibility = accessibility
        self.confirmationInfo = confirmationInfo
        self.onTap = onTap
        self.onTapView = nil
    }

    // TextInfo, () -> Void

    init(
        id: ID,
        position: Position = .individual,
        leftAccessory: SessionCell.Accessory? = nil,
        title: SessionCell.TextInfo,
        rightAccessory: SessionCell.Accessory? = nil,
        styling: SessionCell.StyleInfo = SessionCell.StyleInfo(),
        isEnabled: Bool = true,
        accessibility: Accessibility? = nil,
        confirmationInfo: ConfirmationModal.Info? = nil,
        onTap: (() -> Void)? = nil
    ) {
        self.id = id
        self.position = position
        self.leftAccessory = leftAccessory
        self.title = title
        self.subtitle = nil
        self.rightAccessory = rightAccessory
        self.styling = styling
        self.isEnabled = isEnabled
        self.accessibility = accessibility
        self.confirmationInfo = confirmationInfo
        self.onTap = onTap
        self.onTapView = nil
    }

    // String, String?, () -> Void

    init(
        id: ID,
        position: Position = .individual,
        leftAccessory: SessionCell.Accessory? = nil,
        title: String,
        subtitle: String?,
        rightAccessory: SessionCell.Accessory? = nil,
        styling: SessionCell.StyleInfo = SessionCell.StyleInfo(),
        isEnabled: Bool = true,
        accessibility: Accessibility? = nil,
        confirmationInfo: ConfirmationModal.Info? = nil,
        onTap: (() -> Void)? = nil,
        onTapView: ((UIView?) -> Void)? = nil
    ) {
        self.id = id
        self.position = position
        self.leftAccessory = leftAccessory
        self.title = SessionCell.TextInfo(title, font: .title)
        self.subtitle = SessionCell.TextInfo(subtitle, font: .subtitle)
        self.rightAccessory = rightAccessory
        self.styling = styling
        self.isEnabled = isEnabled
        self.accessibility = accessibility
        self.confirmationInfo = confirmationInfo
        self.onTap = onTap
        self.onTapView = onTapView
    }
}
