// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit

public protocol SessionProUIManagerType: Actor {
    nonisolated var characterLimit: Int { get }
    nonisolated var pinnedConversationLimit: Int { get }
    nonisolated var currentUserIsCurrentlyPro: Bool { get }
    nonisolated var currentUserIsPro: AsyncStream<Bool> { get }
    
    nonisolated func numberOfCharactersLeft(for content: String) -> Int
    
    @discardableResult @MainActor func showSessionProCTAIfNeeded(
        _ variant: ProCTAModal.Variant,
        dismissType: Modal.DismissType,
        onConfirm: (() -> Void)?,
        onCancel: (() -> Void)?,
        afterClosed: (() -> Void)?,
        presenting: ((UIViewController) -> Void)?
    ) -> Bool
    
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
}

// MARK: - Noop

internal actor NoopSessionProUIManager: SessionProUIManagerType {
    private let isPro: Bool
    nonisolated public let characterLimit: Int
    nonisolated public let pinnedConversationLimit: Int
    nonisolated public let currentUserIsCurrentlyPro: Bool
    nonisolated public var currentUserIsPro: AsyncStream<Bool> {
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
        self.currentUserIsCurrentlyPro = isPro
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
    
    public func purchasePro(productId: String) async throws {}
}
