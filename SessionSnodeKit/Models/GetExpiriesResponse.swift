// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Sodium
import SessionUtilitiesKit

public class GetExpiriesResponse: SnodeResponse {
    private enum CodingKeys: String, CodingKey {
        case expiries
    }
    
    public let expiries: [String: UInt64]
    
    // MARK: - Initialization
    
    required init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        
        expiries = ((try? container.decode([String: UInt64].self, forKey: .expiries)) ?? [:])
        
        try super.init(from: decoder)
    }
}
