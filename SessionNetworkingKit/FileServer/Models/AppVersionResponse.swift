// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension Network.FileServer {
    class AppVersionResponse: AppVersionInfo {
        enum CodingKeys: String, CodingKey {
            case prerelease
        }
        
        public let prerelease: AppVersionInfo?
        
        public init(
            version: String,
            updated: TimeInterval?,
            name: String?,
            notes: String?,
            assets: [Asset]?,
            prerelease: AppVersionInfo?
        ) {
            self.prerelease = prerelease
            
            super.init(
                version: version,
                updated: updated,
                name: name,
                notes: notes,
                assets: assets
            )
        }
        
        required init(from decoder: Decoder) throws {
            let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
            
            self.prerelease = try? container.decode(AppVersionInfo?.self, forKey: .prerelease)
            
            try super.init(from: decoder)
        }
        
        public override func encode(to encoder: Encoder) throws {
            try super.encode(to: encoder)
            
            var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(prerelease, forKey: .prerelease)
        }
    }
    
    // MARK: - AppVersionInfo
    
    class AppVersionInfo: Codable {
        enum CodingKeys: String, CodingKey {
            case version = "result"
            case updated
            case name
            case notes
            case assets
        }
        
        public struct Asset: Codable {
            enum CodingKeys: String, CodingKey {
                case name
                case url
            }
            
            public let name: String
            public let url: String
        }
        
        public let version: String
        public let updated: TimeInterval?
        public let name: String?
        public let notes: String?
        public let assets: [Asset]?
        
        public init(
            version: String,
            updated: TimeInterval?,
            name: String?,
            notes: String?,
            assets: [Asset]?
        ) {
            self.version = version
            self.updated = updated
            self.name = name
            self.notes = notes
            self.assets = assets
        }
        
        public func encode(to encoder: Encoder) throws {
            var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
            
            try container.encode(version, forKey: .version)
            try container.encodeIfPresent(updated, forKey: .updated)
            try container.encodeIfPresent(name, forKey: .name)
            try container.encodeIfPresent(notes, forKey: .notes)
            try container.encodeIfPresent(assets, forKey: .assets)
        }
    }
}
