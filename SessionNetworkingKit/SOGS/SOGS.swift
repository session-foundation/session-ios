// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtil
import SessionUtilitiesKit

public extension Network {
    enum SOGS {
        public static let legacyDefaultServerIP = "116.203.70.33"
        public static let defaultServer = "https://open.getsession.org"
        public static let defaultServerPublicKey = "a03c383cf63c3c4efe67acc52112a6dd734b3a946b9545f488aaa93da7991238"
        public static let defaultAuthMethod: AuthenticationMethod = Authentication.community(
            roomToken: "",
            server: defaultServer,
            publicKey: defaultServerPublicKey,
            hasCapabilities: false,
            supportsBlinding: true,
            forceBlinded: false
        )
        public static let validTimestampVarianceThreshold: TimeInterval = (6 * 60 * 60)
        internal static let maxInactivityPeriodForPolling: TimeInterval = (14 * 24 * 60 * 60)
        
        public static func parsedDownloadUrl(for downloadUrl: String?) -> ParsedDownloadUrl? {
            return downloadUrl.map { urlString -> ParsedDownloadUrl? in
                var cResult: open_group_server_parsed_download_url = open_group_server_parsed_download_url()
                
                guard
                    let url: URL = URL(string: urlString),
                    let cUrlString: [CChar] = urlString.cString(using: .utf8),
                    session_open_group_server_parse_download_url(cUrlString, &cResult)
                else { return nil }
                
                return ParsedDownloadUrl(urlString, url, cResult)
            }
        }
    }
}
