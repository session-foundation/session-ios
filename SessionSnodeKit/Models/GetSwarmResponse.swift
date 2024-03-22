// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit

public class GetSwarmResponse: SnodeResponse {
    private enum CodingKeys: String, CodingKey {
        case swarm
        case internalSnodes = "snodes"
    }
    
    fileprivate struct _Snode: Codable {
        public enum CodingKeys: String, CodingKey {
            case ip
            case lmqPort = "port_omq"
            case x25519PublicKey = "pubkey_x25519"
            case ed25519PublicKey = "pubkey_ed25519"
        }
        
        /// The IPv4 address of the service node.
        let ip: String
        
        /// The storage server port where OxenMQ is listening.
        let lmqPort: UInt16
        
        /// This is the X25519 pubkey key of this service node, used for encrypting onion requests and for establishing an encrypted connection to the storage server's OxenMQ port.
        let x25519PublicKey: String
        
        /// The Ed25519 public key of this service node. This is the public key the service node uses wherever a signature is required (such as when signing recursive requests).
        let ed25519PublicKey: String
    }
    
    /// Contains the target swarm ID, encoded as a hex string. (This ID is a unsigned, 64-bit value and cannot be reliably transported unencoded through JSON)
    internal let swarm: String
    
    /// An array containing the list of service nodes in the target swarm.
    private let internalSnodes: [Failable<_Snode>]
    
    public var snodes: Set<Snode> {
        internalSnodes
            .compactMap { $0.value }
            .map { responseSnode in
                Snode(
                    ip: responseSnode.ip,
                    lmqPort: responseSnode.lmqPort,
                    x25519PublicKey: responseSnode.x25519PublicKey,
                    ed25519PublicKey: responseSnode.ed25519PublicKey
                )
            }
            .asSet()
    }
    
    // MARK: - Initialization
    
    required init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        
        swarm = try container.decode(String.self, forKey: .swarm)
        internalSnodes = try container.decode([Failable<_Snode>].self, forKey: .internalSnodes)
        
        try super.init(from: decoder)
    }
}

// MARK: - Decoder

extension GetSwarmResponse._Snode {
    public init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<GetSwarmResponse._Snode.CodingKeys> = try decoder.container(keyedBy: GetSwarmResponse._Snode.CodingKeys.self)
        
        do {
            // Strip the http from the IP (if included)
            let ip: String = (try container.decode(String.self, forKey: .ip))
                .replacingOccurrences(of: "http://", with: "")
                .replacingOccurrences(of: "https://", with: "")
            
            guard !ip.isEmpty && ip != "0.0.0.0" else { throw SnodeAPIError.invalidIP }

            self = GetSwarmResponse._Snode(
                ip: ip,
                lmqPort: try container.decode(UInt16.self, forKey: .lmqPort),
                x25519PublicKey: try container.decode(String.self, forKey: .x25519PublicKey),
                ed25519PublicKey: try container.decode(String.self, forKey: .ed25519PublicKey)
            )
        }
        catch {
            SNLog("Failed to parse snode: \(error.localizedDescription).")
            throw HTTPError.invalidJSON
        }
    }
}
