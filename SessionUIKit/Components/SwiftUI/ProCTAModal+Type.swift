// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SwiftUI

// MARK: - ProCTAOutcome

/// Why a Pro CTA was or was not shown.
///
/// Replaces a `Bool`, which collapsed the two "not shown" reasons into one and left every caller to
/// re-derive what to do next - which is how five call sites reached five different answers about the same
/// state.
public enum ProCTAOutcome: Equatable {
    /// The CTA was presented.
    case shown

    /// Suppressed because the user's PLAN reads active, so an upsell would offer them what they already pay
    /// for. The caller must still refuse whatever was gated - it is `ACCESS` that was missing, not the plan -
    /// but must refuse **without selling**.
    ///
    /// **TODO: [PRO] surfaces reaching this state with no neutral copy currently refuse in silence.**
    /// Accepted deliberately rather than overlooked: the alternative was blocking the access/display split on
    /// a translation round for an edge case (active plan, no usable proof). `ConversationVC`'s send gate shows
    /// what the fix looks like - it explains the refusal without offering a purchase. Do NOT "fix" this by
    /// reinstating the upsell; that is the bug this state exists to prevent.
    case suppressedPlanActive
}

// MARK: - SessionProCTAManagerType

public protocol SessionProCTAManagerType: AnyObject {
    @discardableResult @MainActor func showSessionProCTAIfNeeded(
        _ variant: ProCTAModal.Variant,
        dismissType: Modal.DismissType,
        onConfirm: (() -> Void)?,
        onCancel: (() -> Void)?,
        afterClosed: (() -> Void)?,
        presenting: ((UIViewController) -> Void)?
    ) -> ProCTAOutcome
    
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
    ) -> ProCTAOutcome {
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
    ) -> ProCTAOutcome {
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
    ) -> ProCTAOutcome {
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
