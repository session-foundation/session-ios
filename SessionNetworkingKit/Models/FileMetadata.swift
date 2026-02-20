// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionUtilitiesKit

public struct FileMetadata: Codable {
    public let id: String
    public let size: UInt64?
    public let uploaded: TimeInterval?
    public let expires: TimeInterval?
    
    public init(
        id: String,
        size: UInt64?,
        uploaded: TimeInterval? = nil,
        expires: TimeInterval? = nil
    ) {
        self.id = id
        self.size = size
        self.uploaded = uploaded
        self.expires = expires
    }
    
    init(_ libSessionValue: session_file_metadata) {
        id = libSessionValue.get(\.file_id)
        size = libSessionValue.size
        uploaded = (libSessionValue.uploaded_timestamp == 0 ? nil :
            TimeInterval(libSessionValue.uploaded_timestamp)
        )
        expires = (libSessionValue.expiry_timestamp == 0 ? nil :
            TimeInterval(libSessionValue.expiry_timestamp)
        )
    }
}

// MARK: - Codable

extension FileMetadata {
    public init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)

        /// **Note:** SOGS returns an `Int` and the storage server returns a `String` but we want to avoid handling both cases
        /// so parse the `Int` and convert it to a `String` so we can be consistent (SOGS is able to handle an array of Strings for
        /// the `files` param when posting a message just fine)
        if let intValue: Int64 = try? container.decode(Int64.self, forKey: .id) {
            self = FileMetadata(
                id: "\(intValue)",
                size: try container.decodeIfPresent(UInt64.self, forKey: .size),
                uploaded: try container.decodeIfPresent(TimeInterval.self, forKey: .uploaded),
                expires: try container.decodeIfPresent(TimeInterval.self, forKey: .expires)
            )
            return
        }
        
        self = FileMetadata(
            id: try container.decode(String.self, forKey: .id),
            size: try container.decodeIfPresent(UInt64.self, forKey: .size),
            uploaded: try container.decodeIfPresent(TimeInterval.self, forKey: .uploaded),
            expires: try container.decodeIfPresent(TimeInterval.self, forKey: .expires)
        )
    }
}

extension session_file_metadata: @retroactive CAccessible {}
