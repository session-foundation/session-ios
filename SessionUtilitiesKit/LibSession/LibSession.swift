// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil

// MARK: - LibSession

public enum LibSession {
    public static var version: String { String(cString: LIBSESSION_UTIL_VERSION_STR) }
}
