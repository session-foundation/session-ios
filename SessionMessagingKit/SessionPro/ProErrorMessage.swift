// Copyright © 2025 Session Technology Foundation. All rights reserved.

import Foundation
import SessionNetworkingKit
import SessionUIKit

public extension Network.SessionPro.ResponseHeader {
    /// User-facing message for a failed Pro request.
    ///
    /// The backend sends an open-ended `errorCode` slug (spec §5.1) plus an English diagnostic `error`.
    /// We prefer a localized `pro_error_<slug>` string when one exists (so a brand-new slug needs only a
    /// translation entry — no code change), with any brand tokens ({pro}/{app_pro}/{app_name}) substituted;
    /// otherwise we fall back to the backend diagnostic, then a generic message.
    // stringlint:ignore_contents
    var userFacingMessage: String {
        if let slug: String = errorCode {
            let key: String = "pro_error_\(slug)"
            let localized: String = LocalizationHelper(template: key)
                .localized()

            // LocalizationHelper returns the key itself when the string is missing, so a differing
            // result means a real translation exists (base English counts).
            if localized != key {
                return localized
            }
        }

        return error ?? "errorGeneric".localized()
    }
}
