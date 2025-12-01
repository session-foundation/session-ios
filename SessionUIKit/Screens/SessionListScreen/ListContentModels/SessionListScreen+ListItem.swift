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
    
    class ListItemDataState<Section: ListSection, ListItem: Hashable & Differentiable>: SectionedListItemData, ObservableObject {
        @Published public private(set) var listItemData: [SectionModel]  = []
        
        public init() {}
        
        public func updateTableData(_ updatedData: [SectionModel]) { self.listItemData = updatedData }
    }
    
    struct ListItemInfo<ID: Hashable & Differentiable>: Equatable, Hashable, Differentiable {
        public enum Variant: Equatable, Hashable, Differentiable {
            case cell(info: ListItemCell.Info)
            case logoWithPro(info: ListItemLogoWithPro.Info)
            case dataMatrix(info: [[ListItemDataMatrix.Info]])
            case button(title: String)
            case profilePicture(info: ListItemProfilePicture.Info)
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
