// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import DifferenceKit

public extension SessionListScreenContent {
    protocol ListItemData {
        associatedtype ListItem: Hashable & Differentiable
    }
    
    protocol SectionedListItemData: ListItemData {
        associatedtype Section: ListSection
        
        typealias SectionModel = ArraySection<Section, ListItemInfo<ListItem>>
    }
    
    class ListItemDataState<Section: ListSection, ListItem: Hashable & Differentiable>: SectionedListItemData {
        public private(set) var listItemData: [SectionModel]  = []
        
        public init() {}
        
        public func updateTableData(_ updatedData: [SectionModel]) { self.listItemData = updatedData }
    }
    
    struct CellInfo: Equatable, Hashable, Differentiable {
        let leadingAccessory: ListItemAccessory?
        let title: TextInfo?
        let subtitle: TextInfo?
        let description: TextInfo?
        let trailingAccessory: ListItemAccessory?
        
        public init(
            leadingAccessory: ListItemAccessory? = nil,
            title: TextInfo? = nil,
            subtitle: TextInfo? = nil,
            description: TextInfo? = nil,
            trailingAccessory: ListItemAccessory? = nil
        ) {
            self.leadingAccessory = leadingAccessory
            self.title = title
            self.subtitle = subtitle
            self.description = description
            self.trailingAccessory = trailingAccessory
        }
    }
    
    struct DataMatrixInfo: Equatable, Hashable, Differentiable {
        let leadingAccessory: ListItemAccessory?
        let title: TextInfo?
        let trailingAccessory: ListItemAccessory?
        
        public init(
            leadingAccessory: ListItemAccessory? = nil,
            title: TextInfo? = nil,
            trailingAccessory: ListItemAccessory? = nil,
        ) {
            self.leadingAccessory = leadingAccessory
            self.title = title
            self.trailingAccessory = trailingAccessory
        }
    }
    
    struct ListItemInfo<ID: Hashable & Differentiable>: Equatable, Hashable, Differentiable {
        public enum Variant: Equatable, Hashable, Differentiable {
            case cell(info: CellInfo)
            case logoWithPro
            case dataMatrix(info: [[DataMatrixInfo]])
        }
        
        let id: ID
        let variant: Variant
        let isEnabled: Bool
        let accessibility: Accessibility?
        let confirmationInfo: ConfirmationModal.Info?
        let onTap: (@MainActor () -> Void)?
        
        public init(
            id: ID,
            variant: Variant,
            isEnabled: Bool = true,
            accessibility: Accessibility? = nil,
            confirmationInfo: ConfirmationModal.Info? = nil,
            onTap: (@MainActor () -> Void)? = nil
        ) {
            self.id = id
            self.variant = variant
            self.isEnabled = isEnabled
            self.accessibility = accessibility
            self.confirmationInfo = confirmationInfo
            self.onTap = onTap
        }
        
        // MARK: - Conformance
        
        public var differenceIdentifier: ID { id }
        
        public func hash(into hasher: inout Hasher) {
            id.hash(into: &hasher)
            variant.hash(into: &hasher)
            isEnabled.hash(into: &hasher)
            accessibility.hash(into: &hasher)
            confirmationInfo.hash(into: &hasher)
        }
        
        public static func == (lhs: ListItemInfo<ID>, rhs: ListItemInfo<ID>) -> Bool {
            return (
                lhs.id == rhs.id &&
                lhs.variant == rhs.variant &&
                lhs.isEnabled == rhs.isEnabled &&
                lhs.accessibility == rhs.accessibility
            )
        }
    }
}
