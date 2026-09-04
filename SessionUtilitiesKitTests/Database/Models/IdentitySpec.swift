// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

import Quick
import Nimble

@testable import SessionUtilitiesKit

class IdentitySpec: AsyncSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies()
        @TestState var mockStorage: Storage! = try! Storage.createForTesting(using: dependencies)
        
        beforeEach {
            dependencies.set(singleton: .storage, to: mockStorage)
            try await mockStorage.perform(migrations: [ _001_SUK_InitialSetupMigration.self ])
        }
        
        // MARK: - an Identity
        describe("an Identity") {
            // MARK: -- correctly retrieves the user key pair
            it("correctly retrieves the user key pair") {
                try await mockStorage.write { db in
                    try Identity(variant: .x25519PublicKey, data: "Test3".data(using: .utf8)!).insert(db)
                    try Identity(variant: .x25519PrivateKey, data: "Test4".data(using: .utf8)!).insert(db)
                }
                
                try await mockStorage.read { db in
                    let keyPair = try Identity.fetchUserKeyPair(db)
                    
                    expect(keyPair?.publicKey)
                        .to(equal("Test3".data(using: .utf8)?.bytes))
                    expect(keyPair?.secretKey)
                        .to(equal("Test4".data(using: .utf8)?.bytes))
                }
            }
            
            // MARK: -- correctly retrieves the user ED25519 key pair
            it("correctly retrieves the user ED25519 key pair") {
                try await mockStorage.write { db in
                    try Identity(variant: .ed25519PublicKey, data: "Test5".data(using: .utf8)!).insert(db)
                    try Identity(variant: .ed25519SecretKey, data: "Test6".data(using: .utf8)!).insert(db)
                }
                
                try await mockStorage.read { db in
                    let keyPair = try Identity.fetchUserEd25519KeyPair(db)
                    
                    expect(keyPair?.publicKey)
                        .to(equal("Test5".data(using: .utf8)?.bytes))
                    expect(keyPair?.secretKey)
                        .to(equal("Test6".data(using: .utf8)?.bytes))
                }
            }
            
            // MARK: -- returns nil when the identity has not been stored
            it("returns nil when the identity has not been stored") {
                try await mockStorage.read { db in
                    expect(try Identity.fetchUserKeyPair(db)).to(beNil())
                    expect(try Identity.fetchUserEd25519KeyPair(db)).to(beNil())
                }
            }
            
            // MARK: -- throws rather than reporting an absent identity when the table cannot be read
            ///
            /// An absent identity means "new user" to every caller, and one of them registers a fresh account on the
            /// strength of it - overwriting the identity the read failed to see. So an unreadable table must not
            /// produce the same answer as an empty one
            it("throws rather than reporting an absent identity when the table cannot be read") {
                try await mockStorage.write { db in
                    try Identity(variant: .ed25519PublicKey, data: "Test5".data(using: .utf8)!).insert(db)
                    try Identity(variant: .ed25519SecretKey, data: "Test6".data(using: .utf8)!).insert(db)
                    try Identity(variant: .x25519PublicKey, data: "Test3".data(using: .utf8)!).insert(db)
                    try Identity(variant: .x25519PrivateKey, data: "Test4".data(using: .utf8)!).insert(db)
                }
                
                /// Removing the table is a stand-in for any read failure - what matters is that the failure is
                /// distinguishable from an empty result, not which failure it was
                try await mockStorage.write { db in
                    try db.execute(sql: "DROP TABLE identity")
                }
                
                try await mockStorage.read { db in
                    expect { try Identity.fetchUserEd25519KeyPair(db) }.to(throwError())
                    expect { try Identity.fetchUserKeyPair(db) }.to(throwError())
                }
            }
            
            // MARK: -- reports whether an identity is stored
            it("reports whether an identity is stored") {
                try await mockStorage.read { db in
                    expect(try Identity.hasStoredIdentity(db)).to(beFalse())
                }
                
                try await mockStorage.write { db in
                    try Identity(variant: .ed25519PublicKey, data: "Test5".data(using: .utf8)!).insert(db)
                }
                
                try await mockStorage.read { db in
                    expect(try Identity.hasStoredIdentity(db)).to(beTrue())
                }
            }
            
            // MARK: -- reports a stored identity even when it is incomplete
            ///
            /// A partially written identity is still an identity that must not be overwritten, and it is exactly the
            /// shape `fetchUserEd25519KeyPair` reports as absent
            it("reports a stored identity even when it is incomplete") {
                try await mockStorage.write { db in
                    try Identity(variant: .ed25519PublicKey, data: "Test5".data(using: .utf8)!).insert(db)
                }
                
                try await mockStorage.read { db in
                    expect(try Identity.fetchUserEd25519KeyPair(db)).to(beNil())
                    expect(try Identity.hasStoredIdentity(db)).to(beTrue())
                }
            }
        }
    }
}
