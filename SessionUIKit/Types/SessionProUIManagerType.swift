// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit

public protocol SessionProUIManagerType: Actor {
    nonisolated var characterLimit: Int { get }
    nonisolated var pinnedConversationLimit: Int { get }
    nonisolated var currentUserHasProAccess: Bool { get }
    nonisolated var currentUserProPlanIsActive: Bool { get }
    nonisolated var currentUserHasProAccessStream: AsyncStream<Bool> { get }
    nonisolated var currentUserProPlanIsActiveStream: AsyncStream<Bool> { get }
    
    nonisolated func numberOfCharactersLeft(for content: String) -> Int
    
    @discardableResult @MainActor func showSessionProCTAIfNeeded(
        _ variant: ProCTAModal.Variant,
        dismissType: Modal.DismissType,
        onConfirm: (() -> Void)?,
        onCancel: (() -> Void)?,
        afterClosed: (() -> Void)?,
        presenting: ((UIViewController) -> Void)?
    ) -> Bool
    
    @MainActor func showSessionProBottomSheetIfNeeded(
        afterClosed: (() -> Void)?,
        presenting: ((UIViewController) -> Void)?
    )
    
    func purchasePro(productId: String) async throws
}

// MARK: - Convenience

public extension SessionProUIManagerType {
    @discardableResult @MainActor func showSessionProCTAIfNeeded(
        _ variant: ProCTAModal.Variant,
        dismissType: Modal.DismissType = .recursive,
        onConfirm: (() -> Void)? = nil,
        onCancel: (() -> Void)? = nil,
        afterClosed: (() -> Void)? = nil,
        presenting: ((UIViewController) -> Void)? = nil
    ) -> Bool {
        showSessionProCTAIfNeeded(
            variant,
            dismissType: dismissType,
            onConfirm: onConfirm,
            onCancel: onCancel,
            afterClosed: afterClosed,
            presenting: presenting
        )
    }
    
    @MainActor func showSessionProBottomSheetIfNeeded(presenting: ((UIViewController) -> Void)?) {
        showSessionProBottomSheetIfNeeded(
            afterClosed: nil,
            presenting: presenting
        )
    }
}

// MARK: - Noop

internal actor NoopSessionProUIManager: SessionProUIManagerType {
    private let isPro: Bool
    nonisolated public let characterLimit: Int
    nonisolated public let pinnedConversationLimit: Int
    nonisolated public let currentUserHasProAccess: Bool
    nonisolated public let currentUserProPlanIsActive: Bool
    nonisolated public var currentUserHasProAccessStream: AsyncStream<Bool> {
        AsyncStream(unfolding: { return self.isPro })
    }
    nonisolated public var currentUserProPlanIsActiveStream: AsyncStream<Bool> {
        AsyncStream(unfolding: { return self.isPro })
    }
    
    init(
        isPro: Bool = false,
        characterLimit: Int = 2000,
        pinnedConversationLimit: Int = 5
    ) {
        self.isPro = isPro
        self.characterLimit = characterLimit
        self.pinnedConversationLimit = pinnedConversationLimit
        self.currentUserHasProAccess = isPro
        self.currentUserProPlanIsActive = isPro
    }
    
    nonisolated public func numberOfCharactersLeft(for content: String) -> Int { 0 }
    
    @discardableResult @MainActor func showSessionProCTAIfNeeded(
        _ variant: ProCTAModal.Variant,
        dismissType: Modal.DismissType,
        afterClosed: (() -> Void)?,
        presenting: ((UIViewController) -> Void)?
    ) -> Bool {
        return false
    }
    
    @MainActor func showSessionProBottomSheetIfNeeded(
        afterClosed: (() -> Void)?,
        presenting: ((UIViewController) -> Void)?
    ) {}
    
    public func purchasePro(productId: String) async throws {}
}
