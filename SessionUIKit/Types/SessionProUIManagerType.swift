// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit

public protocol SessionProUIManagerType: Actor {
    nonisolated var characterLimit: Int { get }
    nonisolated var pinnedConversationLimit: Int { get }
    nonisolated var currentUserIsCurrentlyPro: Bool { get }
    nonisolated var currentUserIsPro: AsyncStream<Bool> { get }
    
    nonisolated func numberOfCharactersLeft(for content: String) -> Int
    func upgradeToPro(completion: ((_ result: Bool) -> Void)?) async
    
    @discardableResult @MainActor func showSessionProCTAIfNeeded(
        _ variant: ProCTAModal.Variant,
        dismissType: Modal.DismissType,
        afterClosed: (() -> Void)?,
        presenting: ((UIViewController) -> Void)?
    ) -> Bool
}

// MARK: - Convenience

public extension SessionProUIManagerType {
    @discardableResult @MainActor func showSessionProCTAIfNeeded(
        _ variant: ProCTAModal.Variant,
        afterClosed: (() -> Void)?,
        presenting: ((UIViewController) -> Void)?
    ) -> Bool {
        showSessionProCTAIfNeeded(
            variant,
            dismissType: .recursive,
            afterClosed: afterClosed,
            presenting: presenting
        )
    }
    
    @discardableResult @MainActor func showSessionProCTAIfNeeded(
        _ variant: ProCTAModal.Variant,
        presenting: ((UIViewController) -> Void)?
    ) -> Bool {
        showSessionProCTAIfNeeded(
            variant,
            dismissType: .recursive,
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
    
    public func upgradeToPro(completion: ((_ result: Bool) -> Void)?) async {
        completion?(false)
    }
    
    @discardableResult @MainActor func showSessionProCTAIfNeeded(
        _ variant: ProCTAModal.Variant,
        dismissType: Modal.DismissType,
        afterClosed: (() -> Void)?,
        presenting: ((UIViewController) -> Void)?
    ) -> Bool {
        return false
    }
}
