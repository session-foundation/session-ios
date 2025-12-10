// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SwiftUI

// MARK: - SessionProCTAManagerType

public protocol SessionProCTAManagerType: AnyObject {
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
}

// MARK: - Convenience

public extension SessionProCTAManagerType {
    @discardableResult @MainActor func showSessionProCTAIfNeeded(
        _ variant: ProCTAModal.Variant,
        onConfirm: (() -> Void)?,
        onCancel: (() -> Void)?,
        afterClosed: (() -> Void)?,
        presenting: ((UIViewController) -> Void)?
    ) -> Bool {
        showSessionProCTAIfNeeded(
            variant,
            dismissType: .recursive,
            onConfirm: onConfirm,
            onCancel: onCancel,
            afterClosed: afterClosed,
            presenting: presenting
        )
    }
    
    @discardableResult @MainActor func showSessionProCTAIfNeeded(
        _ variant: ProCTAModal.Variant,
        onConfirm: (() -> Void)?,
        onCancel: (() -> Void)?,
        presenting: ((UIViewController) -> Void)?
    ) -> Bool {
        showSessionProCTAIfNeeded(
            variant,
            dismissType: .recursive,
            onConfirm: onConfirm,
            onCancel: onCancel,
            afterClosed: nil,
            presenting: presenting
        )
    }
    
    @discardableResult @MainActor func showSessionProCTAIfNeeded(
        _ variant: ProCTAModal.Variant,
        onConfirm: (() -> Void)?,
        presenting: ((UIViewController) -> Void)?
    ) -> Bool {
        showSessionProCTAIfNeeded(
            variant,
            dismissType: .recursive,
            onConfirm: onConfirm,
            onCancel: nil,
            afterClosed: nil,
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
