// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtil
import SessionUtilitiesKit

public extension Network {
    enum SessionPro {
        public static let apiVersion: UInt8 = 0

        /// The production backend base URL + Ed25519 signing pubkey, which come from libsession (the single
        /// source of truth), replacing the previously hard-coded — and stale — client copies
        ///
        /// **Note:** These are only the defaults — use `server(using:)` and `edPublicKey(using:)` so the
        /// `customProBackend` dev override is honoured (reading these directly bypasses it)
        static let defaultServer: String = (SESSION_PRO_BACKEND_URL.map { String(cString: $0) } ?? "")
        public static let defaultEdPublicKey: String =
            (SESSION_PRO_BACKEND_PUBKEY.map { Data(bytes: $0, count: 32).toHexString() } ?? "")

        /// The backend to talk to, which is the libsession-provided production URL unless a custom backend
        /// has been configured in the developer settings
        public static func server(using dependencies: Dependencies) -> String {
            let customUrl: String = dependencies[feature: .customProBackend].url

            guard
                dependencies[feature: .customProBackend].isValid,
                !customUrl.isEmpty  /// An empty `url` means the default should be used
            else { return defaultServer }

            return customUrl
        }

        /// The Ed25519 key the Session Pro backend signs with
        ///
        /// **Warning:** This key does double duty — it authenticates the backend for our own requests **and**
        /// it's the key `libSession` verifies other users' proofs against when decoding their messages (see
        /// `session_protocol_decode_envelope`). A device pointed at a custom backend therefore can't validate
        /// a proof signed by the production backend, and vice versa, so every device in a test needs the
        /// same override or their proofs will read as `invalidProBackendSig` to each other.
        public static func edPublicKey(using dependencies: Dependencies) -> String {
            let customPubkey: String = dependencies[feature: .customProBackend].pubkey

            guard
                dependencies[feature: .customProBackend].isValid,
                !customPubkey.isEmpty   /// An empty `pubkey` means the default should be used
            else { return defaultEdPublicKey }

            return customPubkey
        }

        internal static func x25519PublicKey(using dependencies: Dependencies) throws -> String {
            let x25519Pubkey: [UInt8] = try dependencies[singleton: .crypto].tryGenerate(
                .x25519(ed25519Pubkey: Array(Data(hex: edPublicKey(using: dependencies))))
            )

            return x25519Pubkey.toHexString()
        }
    }
}

// MARK: - Dev Settings

public extension FeatureStorage {
    static let customProBackend: FeatureConfig<Network.SessionPro.Custom> = Dependencies.create(
        identifier: "customProBackend"
    )
}

public extension Network.SessionPro {
    /// A custom Session Pro backend to use instead of the libsession-provided production one
    ///
    /// **Note:** This mirrors `Network.FileServer.Custom` — the production Pro backend has no way to grant an
    /// entitlement to a test account (it has no `/dev` routes, by design), so the automated tests need to be
    /// able to point at a QA instance, which brings its own signing key with it
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

        public let title: String = "Custom Pro Backend"
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
