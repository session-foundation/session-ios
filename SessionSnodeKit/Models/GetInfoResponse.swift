// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit

extension SnodeAPI {
    public class GetInfoResponse: SnodeResponse {
        private enum CodingKeys: String, CodingKey {
            case versionString = "version"
        }
        
        let versionString: String?
        
        var version: Version? { versionString.map { Version.from($0) } }
        
        // MARK: - Initialization
        
        required init(from decoder: Decoder) throws {
            let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
            
            versionString = (try container.decode([Int]?.self, forKey: .versionString))?
                .map { "\($0)" }
                .joined(separator: ".")
            
            try super.init(from: decoder)
        }
    }
}
