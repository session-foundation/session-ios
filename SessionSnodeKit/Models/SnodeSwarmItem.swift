// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public class SnodeSwarmItem: Codable {
    private enum CodingKeys: String, CodingKey {
        case signatureBase64 = "signature"
        
        case failed
        case timeout
        case code
        case reason
        case badPeerResponse = "bad_peer_response"
        case queryFailure = "query_failure"
    }
    
    /// Should be present as long as the request didn't fail
    public let signatureBase64: String?
    
    /// `true` if the request failed, possibly accompanied by one of the following: `timeout`, `code`,
    /// `reason`, `badPeerResponse`, `queryFailure`
    public let failed: Bool
    
    /// `true` if the inter-swarm request timed out
    public let timeout: Bool?
    
    /// `X` if the inter-swarm request returned error code `X`
    public let code: Int?
    
    /// a reason string, e.g. propagating a thrown exception messages
    public let reason: String?
    
    /// `true` if the peer returned an unparseable response
    public let badPeerResponse: Bool?
    
    /// `true` if the database failed to perform the query
    public let queryFailure: Bool?
    
    // MARK: - Initialization
    
    public required init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        
        signatureBase64 = try? container.decode(String.self, forKey: .signatureBase64)
        failed = ((try? container.decode(Bool.self, forKey: .failed)) ?? false)
        timeout = try? container.decode(Bool.self, forKey: .timeout)
        code = try? container.decode(Int.self, forKey: .code)
        reason = try? container.decode(String.self, forKey: .reason)
        badPeerResponse = try? container.decode(Bool.self, forKey: .badPeerResponse)
        queryFailure = try? container.decode(Bool.self, forKey: .queryFailure)
    }
}
