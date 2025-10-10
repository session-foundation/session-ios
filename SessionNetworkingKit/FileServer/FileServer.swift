// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit

public extension Network {
    enum FileServer {
        public static let defaultServer = "http://filev2.getsession.org"
        internal static let defaultEdPublicKey = "b8eef9821445ae16e2e97ef8aa6fe782fd11ad5253cd6723b281341dba22e371"
        
        public static func server(using dependencies: Dependencies) -> String {
            guard dependencies[feature: .customFileServer].isValid else {
                return defaultServer
            }
            
            return dependencies[feature: .customFileServer].url
        }
        
        internal static func edPublicKey(using dependencies: Dependencies) -> String {
            let customPubkey: String = dependencies[feature: .customFileServer].pubkey
            
            guard
                dependencies[feature: .customFileServer].isValid,
                !customPubkey.isEmpty   /// An empty `pubkey` will be considered value (as we just fallback to the default)
            else { return defaultEdPublicKey }
            
            return dependencies[feature: .customFileServer].pubkey
        }
        
        internal static func x25519PublicKey(using dependencies: Dependencies) throws -> String {
            let edPublicKey: String = edPublicKey(using: dependencies)
            let x25519Pubkey: [UInt8] = try dependencies[singleton: .crypto].tryGenerate(
                .x25519(ed25519Pubkey: Array(Data(hex: edPublicKey)))
            )
            
            return x25519Pubkey.toHexString()
        }
        
        internal static func x25519PublicKey(for url: URL, using dependencies: Dependencies) throws -> String {
            let edPublicKey: String = (url.fragmentParameters[.publicKey] ?? defaultEdPublicKey)
            
            guard Hex.isValid(edPublicKey) && edPublicKey.count == 64 else {
                throw CryptoError.invalidPublicKey
            }
            
            let x25519Pubkey: [UInt8] = try dependencies[singleton: .crypto].tryGenerate(
                .x25519(ed25519Pubkey: Array(Data(hex: edPublicKey)))
            )
            
            return x25519Pubkey.toHexString()
        }
        
        public static func downloadUrlString(
            for fileId: String,
            using dependencies: Dependencies
        ) -> String {
            var fragments: [HTTPFragmentParam: String] = [:]
            let edPublicKey: String = edPublicKey(using: dependencies)
            
            if dependencies[feature: .deterministicAttachmentEncryption] {
                fragments[.deterministicEncryption] = ""   /// No value needed
            }
            
            if edPublicKey != defaultEdPublicKey {
                fragments[.publicKey] = edPublicKey
            }
            
            let baseUrl: String = [
                server(using: dependencies),
                Endpoint.fileIndividual(fileId).path
            ].joined(separator: "/")
            
            return [baseUrl, HTTPFragmentParam.string(for: fragments)]
                .filter { !$0.isEmpty }
                .joined(separator: "#")
        }
        
        public static func fileId(for downloadUrl: String?) -> String? {
            return downloadUrl
                .map { urlString -> String? in
                    urlString
                        .split(separator: "/")  // stringlint:ignore
                        .last
                        .map { String($0) }
                }
        }
        
        public static func usesDeterministicEncryption(_ downloadUrl: String?) -> Bool {
            return (downloadUrl
                .map { URL(string: $0) }?
                .fragmentParameters[.deterministicEncryption] != nil)
        }
    }
}

// MARK: - Dev Settings

public extension FeatureStorage {
    static let customFileServer: FeatureConfig<Network.FileServer.Custom> = Dependencies.create(
        identifier: "customFileServer"
    )
}

public extension Network.FileServer {
    struct Custom: Sendable, Equatable, Codable, FeatureOption {
        public typealias RawValue = String
        
        private struct Values: Equatable, Codable {
            public let url: String
            public let pubkey: String
        }
        
        public static let defaultOption: Custom = Custom(
            url: "",
            pubkey: ""
        )
        
        public let title: String = "Custom File Server"
        public let subtitle: String? = nil
        private let values: Values
        
        public var url: String { values.url }
        public var pubkey: String { values.pubkey }
        public var isEmpty: Bool {
            values.url.isEmpty &&
            values.pubkey.isEmpty
        }
        public var isValid: Bool {
            let pubkeyValid: Bool = (
                Hex.isValid(values.pubkey) &&
                values.pubkey.count == 64
            )
            
            return (
                URL(string: url) != nil && (
                    values.pubkey.isEmpty ||    /// Default pubkey would be used if empty
                    pubkeyValid
                )
            )
        }
        
        /// This is needed to conform to `FeatureOption` so it can be saved to `UserDefaults`
        public var rawValue: String {
            (try? JSONEncoder().encode(values)).map { String(data: $0, encoding: .utf8) } ?? ""
        }
        
        // MARK: - Initialization
        
        public init(url: String, pubkey: String) {
            self.values = Values(url: url, pubkey: pubkey)
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
            url: String? = nil,
            pubkey: String? = nil
        ) -> Custom {
            return Custom(
                url: (url ?? self.values.url),
                pubkey: (pubkey ?? self.values.pubkey)
            )
        }
        
        // MARK: - Equality
        
        public static func == (lhs: Custom, rhs: Custom) -> Bool {
            return (lhs.values == rhs.values)
        }
    }
}
