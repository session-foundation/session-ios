// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public class SendMessagesResponse: SnodeRecursiveResponse<SendMessagesResponse.SwarmItem> {
    private enum CodingKeys: String, CodingKey {
        case difficulty
        case hash
        case swarm
    }
    
    public let difficulty: Int64
    public let hash: String
    
    // MARK: - Initialization
    
    required init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        
        difficulty = try container.decode(Int64.self, forKey: .difficulty)
        hash = try container.decode(String.self, forKey: .hash)
        
        try super.init(from: decoder)
    }
}

// MARK: - SwarmItem

public extension SendMessagesResponse {
    class SwarmItem: SnodeSwarmItem {
        private enum CodingKeys: String, CodingKey {
            case hash
            case already
        }
        
        public let hash: String
        
        /// `true` if a message with this hash was already stored
        ///
        /// **Note:** The `hash` is still included and signed even if this occurs
        public let already: Bool
        
        // MARK: - Initialization
        
        required init(from decoder: Decoder) throws {
            let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
            
            hash = try container.decode(String.self, forKey: .hash)
            already = ((try? container.decode(Bool.self, forKey: .already)) ?? false)
            
            try super.init(from: decoder)
        }
    }
}
