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

        /// The loading/error banner under the logo - one identifier for the slot, with the individual states
        /// distinguished by their text (`checkingProStatus`, `proStatusLoading`, `errorCheckingProStatus`,
        /// `proErrorRefreshingStatus`) rather than by separate identifiers
        public static let statusBanner: String = "pro-settings-status-banner"

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
        /// **Note:** Not the read-only "Refund requested" row shown while a refund is being processed - Android has
        /// no equivalent of that row, so it stays unnamed until both platforms agree on a string
        public static let requestRefund: String = "pro-settings-request-refund"

        /// The "Cancel Pro Access" action
        public static let cancelPlan: String = "pro-settings-cancel-plan"

        /// The "Renew Pro Access" action, shown when access has expired
        public static let renewPlan: String = "pro-settings-renew-plan"

        /// The "Recover Pro Access" action
        public static let recoverPlan: String = "pro-settings-recover-plan"

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
