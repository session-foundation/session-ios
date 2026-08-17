// Copyright © 2026 Session Technology Foundation. All rights reserved.
//
// stringlint:ignore

import Foundation

// MARK: - KeychainAccessGroupMigration

/// Copies keychain items into the app group's access group so they survive a change of team ID.
///
/// A keychain item belongs to exactly one access group. Items written without an explicit group land in the
/// app's **first** access group, which is the first entry of its `keychain-access-groups` entitlement when it
/// has one and the application identifier otherwise. Every target here declares that entitlement, and its
/// value is team-prefixed, so a change of team ID makes those items unreachable. An app group identifier
/// carries no team prefix on iOS and doubles as an access group, so an item written there is addressed by a
/// string that the team change does not alter.
///
/// Items are **copied, not moved**: leaving the original in place costs a duplicate and removes a failure mode,
/// and it becomes unreachable of its own accord once the team changes. Where a value is rotated - only
/// `replaceDatabaseKey` does this - the copies cannot diverge, because an unscoped write deletes across every
/// access group before it adds.
public enum KeychainAccessGroupMigration {
    public enum KeyOutcome: Equatable {
        /// Written to the app group's access group and read back with a matching value
        case migrated

        /// Already in the app group with a matching value, so nothing was written
        ///
        /// This is the steady state after the first successful run, and keeping it distinct from `migrated` is
        /// what stops the migration rewriting the key on every launch - see `migrate(key:into:using:)`
        case alreadyPresent

        /// The app has never created this item - not a failure, several keys are created lazily
        case sourceMissing

        /// The item could not be written to, or could not be read back from, the app group
        case failed(String)
    }

    public struct Result: Equatable {
        public let outcomes: [KeychainStorage.DataKey: KeyOutcome]

        /// Keys confirmed to be readable from the app group's access group
        public var verifiedKeys: [KeychainStorage.DataKey] {
            outcomes
                .filter { _, outcome in outcome == .migrated || outcome == .alreadyPresent }
                .map { key, _ in key }
        }

        public var failedKeys: [KeychainStorage.DataKey] {
            outcomes
                .filter { _, outcome in
                    switch outcome {
                        case .failed: return true
                        default: return false
                    }
                }
                .map { key, _ in key }
        }

        public var isFullySucceeded: Bool { failedKeys.isEmpty }
    }

    /// Runs the migration for `keys` and verifies each result.
    ///
    /// Verification is not optional decoration. An unscoped keychain read searches **every** access group the
    /// app belongs to, so an item left behind in the default group reads back exactly like one that was
    /// migrated - a failed migration is indistinguishable from a successful one until the team ID changes, at
    /// which point it can no longer be fixed. The read-back here is scoped to the app group specifically, which
    /// is the only way to assert where an item actually lives.
    ///
    /// Access group membership derives from entitlements, so this only functions where entitlements are applied -
    /// which means a host application. `KeychainStorageSpec` (in `SessionTests`, the target that has one) asserts
    /// the scoping this depends on against the real Security framework.
    @discardableResult public static func run(
        keys: [KeychainStorage.DataKey],
        using dependencies: Dependencies
    ) -> Result {
        let keychain: KeychainStorageType = dependencies[singleton: .keychain]
        let accessGroup: String = keychain.appGroupAccessGroup
        let outcomes: [KeychainStorage.DataKey: KeyOutcome] = keys.reduce(into: [:]) { result, key in
            result[key] = migrate(key: key, into: accessGroup, using: keychain)
        }
        let result: Result = Result(outcomes: outcomes)

        switch result.isFullySucceeded {
            case true:
                Log.info(.keychain, "Keychain access group migration verified \(result.verifiedKeys.count)/\(keys.count) key(s).")

            case false:
                /// There is no telemetry to report this through, so the log is the only signal that reaches a
                /// human - keep it at `critical` so it survives log filtering in a user-supplied report
                Log.critical(.keychain, "Keychain access group migration FAILED for \(result.failedKeys.count)/\(keys.count) key(s): \(result.failedKeys.map { $0.rawValue }.joined(separator: ", ")).")
        }

        return result
    }

    /// Reports which of `keys` is currently readable from the app group's access group, without writing anything.
    ///
    /// There is no telemetry, so a migration that fails in the field reports itself only to the log. This exists so
    /// the state can be read back on demand instead.
    public enum KeyState: Equatable {
        case present

        /// The app group holds no such item - expected for keys which have not been created yet
        case absent

        /// The read itself failed, which is **not** the same as the item being absent and must not be
        /// presented as though it were: it means this check learned nothing about that key
        case unreadable(String)
    }

    public static func verify(
        keys: [KeychainStorage.DataKey],
        using dependencies: Dependencies
    ) -> [KeychainStorage.DataKey: KeyState] {
        let keychain: KeychainStorageType = dependencies[singleton: .keychain]
        let accessGroup: String = keychain.appGroupAccessGroup

        return keys.reduce(into: [:]) { result, key in
            do {
                _ = try keychain.data(forKey: key, accessGroup: accessGroup)
                result[key] = .present
            }
            catch {
                result[key] = ((error as? KeychainStorageError)?.code == errSecItemNotFound ?
                    .absent :
                    .unreadable("\(error)")
                )
            }
        }
    }

    private static func migrate(
        key: KeychainStorage.DataKey,
        into accessGroup: String,
        using keychain: KeychainStorageType
    ) -> KeyOutcome {
        /// Read the value as the app normally would, which searches every access group the app belongs to - so
        /// this finds the item whether it is still in the default group or has already been migrated, and the
        /// write below is idempotent in either case
        ///
        /// Only `errSecItemNotFound` means the app has never created this item. Every other failure - a locked
        /// keychain, a missing entitlement - is a read that did not work, and reporting those as "missing" would
        /// let a run that read nothing at all report itself as a success
        var source: Data
        do { source = try keychain.data(forKey: key) }
        catch {
            guard (error as? KeychainStorageError)?.code == errSecItemNotFound else {
                return .failed("could not be read: \(error)")
            }

            return .sourceMissing
        }
        defer { source.resetBytes(in: 0..<source.count) }

        /// Do not rewrite a value the app group already holds
        ///
        /// The scoped setter deletes and then adds, which are two calls with nothing atomic between them. Before
        /// the transfer that is harmless because the default-group copy survives it - but **after** the transfer the
        /// app group holds the only reachable copy of the database key, so writing unconditionally would delete
        /// that sole copy and re-add it on every single launch. A kill in that window loses the database with no
        /// recovery path, and the post-transfer state is precisely the one this exists to produce.
        ///
        /// Comparing first makes the steady state a read
        if var existing: Data = try? keychain.data(forKey: key, accessGroup: accessGroup) {
            defer { existing.resetBytes(in: 0..<existing.count) }

            if existing == source { return .alreadyPresent }
        }

        do { try keychain.set(data: source, forKey: key, accessGroup: accessGroup) }
        catch { return .failed("write failed: \(error)") }

        guard var verified: Data = try? keychain.data(forKey: key, accessGroup: accessGroup) else {
            return .failed("could not be read back from the app group access group")
        }
        defer { verified.resetBytes(in: 0..<verified.count) }

        guard verified == source else { return .failed("value read back from the app group access group differs") }

        return .migrated
    }
}
