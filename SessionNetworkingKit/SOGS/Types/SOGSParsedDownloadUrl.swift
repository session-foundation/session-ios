// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionUtilitiesKit

public extension Network.SOGS {
    struct ParsedDownloadUrl: ParsedDownloadUrlType {
        public let originalUrlString: String
        public let url: URL
        public let baseUrl: String
        public let room: String
        public let rawFileId: UInt64
        public let wantsStreamDecryption: Bool
        
        public var fileId: String { "\(rawFileId)" }
        
        init(_ urlString: String, _ parsedUrl: URL, _ libSessionValue: open_group_server_parsed_download_url) {
            originalUrlString = urlString
            url = parsedUrl
            baseUrl = libSessionValue.get(\.base_url)
            room = libSessionValue.get(\.room)
            rawFileId = libSessionValue.file_id
            wantsStreamDecryption = libSessionValue.wants_stream_decryption
        }
    }
}

extension open_group_server_parsed_download_url: @retroactive CAccessible {}
