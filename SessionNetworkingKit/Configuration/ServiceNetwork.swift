// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit

// MARK: - FeatureStorage

public extension FeatureStorage {
    static let serviceNetwork: FeatureConfig<ServiceNetwork> = Dependencies.create(
        identifier: "serviceNetwork",
        defaultOption: .mainnet
    )
    
    static let devnetConfig: FeatureConfig<ServiceNetwork.DevnetConfiguration> = Dependencies.create(
        identifier: "devnetConfig"
    )
}

// MARK: - ServiceNetwork

public enum ServiceNetwork: Int, Sendable, FeatureOption, CaseIterable {
    case mainnet = 1
    case testnet = 2
    case devnet = 3
    
    // MARK: - Feature Option
    
    public static var defaultOption: ServiceNetwork = .mainnet
    
    public var title: String {
        switch self {
            case .mainnet: return "Mainnet"
            case .testnet: return "Testnet"
            case .devnet: return "Devnet"
        }
    }
    
    public var subtitle: String? {
        switch self {
            case .mainnet: return "This is the production service node network."
            case .testnet: return "This is the test service node network, it should be used for testing features which are currently in development and may be unstable."
            case .devnet: return "This is a development service node network, it allows you to point your client at a custom service node network for testing."
        }
    }
}

public extension ServiceNetwork {
    struct DevnetConfiguration: Equatable, Codable, FeatureOption {
        public typealias RawValue = String
        
        private struct Values: Equatable, Codable {
            public let pubkey: String
            public let ip: String
            public let httpPort: UInt16
            public let omqPort: UInt16
        }
        
        public static let defaultOption: DevnetConfiguration = DevnetConfiguration(
            pubkey: "",
            ip: "",
            httpPort: 0,
            omqPort: 0
        )
        
        public let title: String = "Devnet Configuration"
        public let subtitle: String? = nil
        private let values: Values
        
        public var pubkey: String { values.pubkey }
        public var ip: String { values.ip }
        public var httpPort: UInt16 { values.httpPort }
        public var omqPort: UInt16 { values.omqPort }
        public var isValid: Bool {
            let pubkeyValid: Bool = (
                Hex.isValid(values.pubkey) &&
                values.pubkey.count == 64
            )
            let ipValid: Bool = (
                values.ip.split(separator: ".").count == 4 &&
                values.ip.split(separator: ".").allSatisfy({ part in
                    UInt8(part, radix: 10) != nil
                })
            )
            
            /// The `httpPort` and `omqPort` values are valid by default due to type safety
            return (pubkeyValid && ipValid)
        }
        
        /// This is needed to conform to `FeatureOption` so it can be saved to `UserDefaults`
        public var rawValue: String {
            (try? JSONEncoder().encode(values)).map { String(data: $0, encoding: .utf8) } ?? ""
        }
        
        // MARK: - Initialization
        
        public init(pubkey: String, ip: String, httpPort: UInt16, omqPort: UInt16) {
            self.values = Values(pubkey: pubkey, ip: ip, httpPort: httpPort, omqPort: omqPort)
        }
        
        public init?(rawValue: String) {
            guard
                let data: Data = rawValue.data(using: .utf8),
                let decodedValues: Values = try? JSONDecoder().decode(Values.self, from: data)
            else { return nil }
            
            self.values = decodedValues
        }
        
        // MARK: - Functions
        
        public func with(
            pubkey: String? = nil,
            ip: String? = nil,
            httpPort: UInt16? = nil,
            omqPort: UInt16? = nil
        ) -> DevnetConfiguration {
            return DevnetConfiguration(
                pubkey: (pubkey ?? self.values.pubkey),
                ip: (ip ?? self.values.ip),
                httpPort: (httpPort ?? self.values.httpPort),
                omqPort: (omqPort ?? self.values.omqPort)
            )
        }
        
        // MARK: - Equality
        
        public static func == (lhs: DevnetConfiguration, rhs: DevnetConfiguration) -> Bool {
            return (lhs.values == rhs.values)
        }
    }
}
