// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionUtilitiesKit

public extension Network.FileServer {
    struct ParsedDownloadUrl: ParsedDownloadUrlType {
        public let originalUrlString: String
        public let url: URL
        public let scheme: String
        public let host: String
        public let fileId: String
        public let customPubkeyHex: String?
        public let wantsStreamDecryption: Bool
        
        init(_ urlString: String, _ parsedUrl: URL, _ libSessionValue: file_server_parsed_download_url) {
            originalUrlString = urlString
            url = parsedUrl
            scheme = libSessionValue.get(\.scheme)
            host = libSessionValue.get(\.host)
            fileId = libSessionValue.get(\.file_id)
            customPubkeyHex = libSessionValue.get(\.custom_pubkey_hex, nullIfEmpty: true)
            wantsStreamDecryption = libSessionValue.wants_stream_decryption
        }
    }
}

extension file_server_parsed_download_url: @retroactive CAccessible {}
