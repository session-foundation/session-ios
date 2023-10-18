// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import DifferenceKit
import SessionUtilitiesKit

// MARK: - EditableStateHolder

public protocol EditableStateHolder: AnyObject, TableData, ErasedEditableStateHolder {
    var editableState: EditableState<TableItem> { get }
}

public extension EditableStateHolder {
    var textChanged: AnyPublisher<(text: String?, item: TableItem), Never> { editableState.textChanged }
    
    func setIsEditing(_ isEditing: Bool) {
        editableState._isEditing.send(isEditing)
    }
    
    func textChanged(_ text: String?, for item: TableItem) {
        editableState._textChanged.send((text, item))
    }
}

// MARK: - ErasedEditableStateHolder

public protocol ErasedEditableStateHolder: AnyObject {
    var isEditing: AnyPublisher<Bool, Never> { get }
    
    func setIsEditing(_ isEditing: Bool)
    func textChanged<Item>(_ text: String?, for item: Item)
}

public extension ErasedEditableStateHolder {
    var isEditing: AnyPublisher<Bool, Never> { Just(false).eraseToAnyPublisher() }
    
    func setIsEditing(_ isEditing: Bool) {}
    func textChanged<Item>(_ text: String?, for item: Item) {}
}

public extension ErasedEditableStateHolder where Self: EditableStateHolder {
    var isEditing: AnyPublisher<Bool, Never> { editableState.isEditing }
    
    func setIsEditing(_ isEditing: Bool) {
        editableState._isEditing.send(isEditing)
    }
    
    func textChanged<Item>(_ text: String?, for item: Item) {
        guard let convertedItem: TableItem = item as? TableItem else { return }
        
        editableState._textChanged.send((text, convertedItem))
    }
}

// MARK: - EditableState

public struct EditableState<TableItem: Hashable & Differentiable> {
    let isEditing: AnyPublisher<Bool, Never>
    let textChanged: AnyPublisher<(text: String?, item: TableItem), Never>
    
    // MARK: - Internal Variables
    
    fileprivate let _isEditing: CurrentValueSubject<Bool, Never> = CurrentValueSubject(false)
    fileprivate let _textChanged: PassthroughSubject<(text: String?, item: TableItem), Never> = PassthroughSubject()
    
    // MARK: - Initialization
    
    init() {
        self.isEditing = _isEditing
            .removeDuplicates()
            .shareReplay(1)
        self.textChanged = _textChanged
            .eraseToAnyPublisher()
    }
}
