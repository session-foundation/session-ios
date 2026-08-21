// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public enum SessionProUI {}

// MARK: - AccessibilityIdentifier

public extension SessionProUI {
    /// Accessibility identifiers for the Pro settings surface
    ///
    /// **Note:** These exact strings are a cross-platform contract with Android (its `content-descriptions` module
    /// defines the same values) so a single Appium locator serves both platforms - renaming one means renaming it
    /// in three repos. See `SessionProBadge.AccessibilityIdentifier` for the badge itself
    // stringlint:ignore_contents
    enum AccessibilityIdentifier {
        /// The Pro entry in the main settings list, which opens this screen
        public static let menuItem: String = "pro-menu-item"

        /// The state-bearing line within that entry - "Upgrade Session", "Session Pro Beta" or "Renew Pro Beta"
        ///
        /// **Note:** `menuItem` sits on the tap target, which carries no text of its own, so the row's *state* is
        /// only readable through this. A flat identifier rather than the generic
        /// `ListItemCell.AccessibilityIdentifier.title`, so a locator can address it without a parent traversal -
        /// and, one element carrying one identifier, this replaces `action-item-title` on this row rather than
        /// sitting alongside it
        public static let menuItemTitle: String = "pro-menu-item-title"

        /// The loading/error banner under the logo - one identifier for the slot, with the individual states
        /// distinguished by their text (`checkingProStatus`, `proStatusLoading`, `errorCheckingProStatus`,
        /// `proErrorRefreshingStatus`) rather than by separate identifiers
        public static let statusBanner: String = "pro-settings-status-banner"

        /// The hero copy under the logo - one identifier for the slot, with the statuses distinguished by their
        /// text (`proAccessRenewStart`, `proFullestPotential`, `proThanksForSupporting`) rather than by separate
        /// identifiers. The `unknown` status renders no element at all, so absence is a meaningful assertion
        ///
        /// **Note:** Supplied by the caller rather than hard-coded into `ListItemLogoWithPro`, because the payment
        /// screen renders the same component with a description of its own - tagging it inside the component would
        /// put this identifier on two different screens' copy
        public static let heroDescription: String = "pro-settings-description"

        /// The "Your Pro Stats" section header
        public static let statsHeader: String = "pro-settings-stats-header"

        /// The four cells of the "Your Pro Stats" matrix
        ///
        /// **Note:** These sit on the cell's *title*, which is the whole "N badges sent" string - so an assertion
        /// reads the value from the element's accessibility **label**, since the identifier takes over `name`
        public static let statsLongerMessages: String = "pro-stats-longer-messages"
        public static let statsPinnedConversations: String = "pro-stats-pinned-conversations"
        public static let statsBadgesSent: String = "pro-stats-badges-sent"
        public static let statsGroupsUpgraded: String = "pro-stats-groups-upgraded"

        /// The "Pro Settings" section header
        public static let manageHeader: String = "pro-settings-manage-header"

        /// The "Pro Beta Features" section header
        public static let featuresHeader: String = "pro-settings-features-header"

        /// The rows of the "This message used the following Session Pro features" list on the message info screen
        ///
        /// **Note:** One identifier per feature rather than an indexed set, so a test can assert *which* features a
        /// message was sent with. These sit on the row's text, so the label is the localized feature name
        ///
        /// **Note:** The names are the per-message subset of the shared Pro feature vocabulary (Desktop derives its
        /// equivalents from that full list), so one feature is named the same wherever it appears
        public static let messageFeatureBadges: String = "pro-message-feature-badges"
        public static let messageFeatureLongerMessages: String = "pro-message-feature-longer-messages"
        public static let messageFeatureAnimatedDisplayPicture: String = "pro-message-feature-animated-display-picture"

        /// The "Update Pro Access" row
        ///
        /// **Note:** `ListItemCell` is a `Button`, so its title and subtitle merge into this one element rather
        /// than staying separately addressable - the expiry text is part of *this* element's accessibility label
        public static let updatePlan: String = "pro-settings-update-plan"

        /// The title of the "Update Pro Access" row, which reads "Refund Requested" while a refund is
        /// being processed
        ///
        /// **Note:** A flat identifier rather than the generic `ListItemCell.AccessibilityIdentifier.title`,
        /// for the same reason as `menuItemTitle`: `ListItemCell` is a `Button`, so its label merges title
        /// and subtitle and the title is not readable through [updatePlan] alone
        public static let updatePlanTitle: String = "pro-settings-update-plan-title"

        /// The remaining-access line within the "Update Pro Access" row
        ///
        /// **Note:** A flat identifier rather than the generic `ListItemCell.AccessibilityIdentifier.subtitle`,
        /// so a locator can address it without a parent traversal. One element carries one identifier, so this
        /// replaces `action-item-subtitle` on this row rather than sitting alongside it
        public static let updatePlanSubtitle: String = "pro-settings-update-plan-subtitle"

        /// The "Pro Badge" visibility row
        public static let showBadge: String = "pro-settings-show-badge"

        /// The toggle within the "Pro Badge" visibility row
        public static let showBadgeToggle: String = "pro-settings-show-badge-toggle"

        /// The "Request Refund" **action** in the "Manage Pro" section
        ///
        /// **Note:** Not the read-only "Refund requested" row shown while a refund is being processed. That
        /// row is the update-plan row's slot, so it carries [updatePlanTitle] / [updatePlanSubtitle] —
        /// matching Android, which keeps one row and swaps its title
        public static let requestRefund: String = "pro-settings-request-refund"

        /// The "Cancel Pro Access" action
        public static let cancelPlan: String = "pro-settings-cancel-plan"

        /// The "Renew Pro Access" action, shown when access has expired
        public static let renewPlan: String = "pro-settings-renew-plan"

        /// The "Recover Pro Access" action
        public static let recoverPlan: String = "pro-settings-recover-plan"

        /// The Pro store-flow screens (update / renew / refund / cancel), one identifier per destination
        /// so a spec can assert WHICH screen a state opens. Only one is ever on screen, which is what
        /// lets the parts below carry generic identifiers.
        ///
        /// **Note:** On iOS these sit on the screen's TITLE, not on its container. An
        /// `accessibilityIdentifier` placed on a SwiftUI container propagates to every descendant, which
        /// makes each child report the screen id and erases the more specific ids below - so the title,
        /// being a leaf, is where the screen identity has to live. Android tags its list root instead,
        /// because a Compose `testTag` does not propagate. Same strings either way, so one locator serves
        /// both; only the node differs.
        public static let screenChoosePlan: String = "pro-screen-choose-plan"
        public static let screenChoosePlanNoBilling: String = "pro-screen-choose-plan-no-billing"
        public static let screenChoosePlanNonOriginating: String = "pro-screen-choose-plan-non-originating"
        public static let screenCancelPlan: String = "pro-screen-cancel-plan"
        public static let screenCancelPlanNonOriginating: String = "pro-screen-cancel-plan-non-originating"
        public static let screenRefundPlan: String = "pro-screen-refund-plan"
        public static let screenRefundPlanNonOriginating: String = "pro-screen-refund-plan-non-originating"
        public static let screenRefundInProgress: String = "pro-screen-refund-in-progress"
        public static let screenPlanConfirmation: String = "pro-screen-plan-confirmation"

        /// The parts of whichever store-flow screen is showing. Generic on purpose: the screens are
        /// mutually exclusive, so the screen identifier above supplies the context and this stays four
        /// identifiers rather than four per screen.
        ///
        /// **Note:** Several of these screens differ only in their interpolated store name, so the
        /// description is often the only thing telling two of them apart - assert its text. As elsewhere
        /// on iOS the identifier takes over `name`, so the copy is read from `label`. Not every screen
        /// has all four.
        public static let screenHeader: String = "pro-screen-header"
        public static let screenTitle: String = "pro-screen-title"
        public static let screenDescription: String = "pro-screen-description"
        public static let screenAction: String = "pro-screen-action"

        /// The "how to manage this elsewhere" cells on the non-originating screens. Named per option
        /// rather than generically like the parts above, because two are shown at once.
        public static let linkCellLinkedDevice: String = "pro-link-cell-linked-device"
        public static let linkCellLinkedDeviceTitle: String = "pro-link-cell-linked-device-title"
        public static let linkCellLinkedDeviceDescription: String = "pro-link-cell-linked-device-description"
        public static let linkCellDevice: String = "pro-link-cell-device"
        public static let linkCellDeviceTitle: String = "pro-link-cell-device-title"
        public static let linkCellDeviceDescription: String = "pro-link-cell-device-description"
        public static let linkCellWebsite: String = "pro-link-cell-website"
        public static let linkCellWebsiteTitle: String = "pro-link-cell-website-title"
        public static let linkCellWebsiteDescription: String = "pro-link-cell-website-description"

        /// The "Pro FAQ" row in the help section
        public static let faq: String = "pro-settings-faq"

        /// The "Support" row in the help section
        public static let support: String = "pro-settings-support"
    }
}

// MARK: - ClientPlatform

public extension SessionProUI {
    enum ClientPlatform: Sendable, Equatable, CaseIterable {
        case iOS
        case android
        
        public var device: String { SNUIKit.proClientPlatformStringProvider(for: self).device }
        public var store: String { SNUIKit.proClientPlatformStringProvider(for: self).store }
        public var platform: String { SNUIKit.proClientPlatformStringProvider(for: self).platform }
        public var platformAccount: String { SNUIKit.proClientPlatformStringProvider(for: self).platformAccount }
    }
}
