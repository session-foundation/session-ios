// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import Sodium
import GRDB
import SessionUtilitiesKit
import SessionMessagingKit

enum Onboarding {
    private static let profileNameRetrievalPublisher: Atomic<AnyPublisher<String?, Error>> = {
        // FIXME: Remove this once `useSharedUtilForUserConfig` is permanent
        guard Features.useSharedUtilForUserConfig else {
            return Atomic(
                Just(nil)
                    .setFailureType(to: Error.self)
                    .eraseToAnyPublisher()
            )
        }
        
        let userPublicKey: String = getUserHexEncodedPublicKey()
        
        return Atomic(
            SnodeAPI.getSwarm(for: userPublicKey)
                .subscribe(on: DispatchQueue.global(qos: .userInitiated))
                .tryFlatMap { swarm -> AnyPublisher<Void, Error> in
                    guard let snode = swarm.randomElement() else { throw SnodeAPIError.generic }
                    
                    return CurrentUserPoller
                        .poll(
                            namespaces: [.configUserProfile],
                            from: snode,
                            for: userPublicKey,
                            on: DispatchQueue.global(qos: .userInitiated),
                            // Note: These values mean the received messages will be
                            // processed immediately rather than async as part of a Job
                            calledFromBackgroundPoller: true,
                            isBackgroundPollValid: { true }
                        )
                        .tryFlatMap { receivedMessageTypes -> AnyPublisher<Void, Error> in
                            // FIXME: Remove this entire 'tryFlatMap' once the updated user config has been released for long enough
                            guard !receivedMessageTypes.isEmpty else {
                                return Just(())
                                    .setFailureType(to: Error.self)
                                    .eraseToAnyPublisher()
                            }
                            
                            SNLog("Onboarding failed to retrieve user config, checking for legacy config")
                            
                            return CurrentUserPoller
                                .poll(
                                    namespaces: [.default],
                                    from: snode,
                                    for: userPublicKey,
                                    on: DispatchQueue.global(qos: .userInitiated),
                                    // Note: These values mean the received messages will be
                                    // processed immediately rather than async as part of a Job
                                    calledFromBackgroundPoller: true,
                                    isBackgroundPollValid: { true }
                                )
                                .tryMap { receivedMessageTypes -> Void in
                                    guard
                                        let message: ConfigurationMessage = receivedMessageTypes
                                            .last(where: { $0 is ConfigurationMessage })
                                            .asType(ConfigurationMessage.self),
                                        let displayName: String = message.displayName
                                    else { return () }
                                    
                                    // Handle user profile changes
                                    Storage.shared.write { db in
                                        try ProfileManager.updateProfileIfNeeded(
                                            db,
                                            publicKey: userPublicKey,
                                            name: displayName,
                                            avatarUpdate: {
                                                guard
                                                    let profilePictureUrl: String = message.profilePictureUrl,
                                                    let profileKey: Data = message.profileKey
                                                else { return .none }
                                                
                                                return .updateTo(
                                                    url: profilePictureUrl,
                                                    key: profileKey,
                                                    fileName: nil
                                                )
                                            }(),
                                            sentTimestamp: TimeInterval((message.sentTimestamp ?? 0) / 1000),
                                            calledFromConfigHandling: false
                                        )
                                    }
                                    return ()
                                }
                                .eraseToAnyPublisher()
                        }
                }
                .flatMap { _ -> AnyPublisher<String?, Error> in
                    Storage.shared.readPublisher(receiveOn: DispatchQueue.global(qos: .userInitiated)) { db in
                        try Profile
                            .filter(id: userPublicKey)
                            .select(.name)
                            .asRequest(of: String.self)
                            .fetchOne(db)
                    }
                }
                .shareReplay(1)
                .eraseToAnyPublisher()
        )
    }()
    public static var profileNamePublisher: AnyPublisher<String?, Error> {
        profileNameRetrievalPublisher.wrappedValue
    }
    
    enum Flow {
        case register, recover, link
        
        func preregister(with seed: Data, ed25519KeyPair: KeyPair, x25519KeyPair: KeyPair) {
            let x25519PublicKey = x25519KeyPair.hexEncodedPublicKey
            
            // Create the initial shared util state (won't have been created on
            // launch due to lack of ed25519 key)
            SessionUtil.loadState(
                userPublicKey: x25519PublicKey,
                ed25519SecretKey: ed25519KeyPair.secretKey
            )
            
            // Store the user identity information
            Storage.shared.write { db in
                try Identity.store(
                    db,
                    seed: seed,
                    ed25519KeyPair: ed25519KeyPair,
                    x25519KeyPair: x25519KeyPair
                )
                
                // No need to show the seed again if the user is restoring or linking
                db[.hasViewedSeed] = (self == .recover || self == .link)
                
                // Create a contact for the current user and set their approval/trusted statuses so
                // they don't get weird behaviours
                try Contact
                    .fetchOrCreate(db, id: x25519PublicKey)
                    .save(db)
                try Contact
                    .filter(id: x25519PublicKey)
                    .updateAllAndConfig(
                        db,
                        Contact.Columns.isTrusted.set(to: true),    // Always trust the current user
                        Contact.Columns.isApproved.set(to: true),
                        Contact.Columns.didApproveMe.set(to: true)
                    )

                // Create the 'Note to Self' thread (not visible by default)
                try SessionThread
                    .fetchOrCreate(db, id: x25519PublicKey, variant: .contact)
                    .save(db)
            }
            
            // Set hasSyncedInitialConfiguration to true so that when we hit the
            // home screen a configuration sync is triggered (yes, the logic is a
            // bit weird). This is needed so that if the user registers and
            // immediately links a device, there'll be a configuration in their swarm.
            UserDefaults.standard[.hasSyncedInitialConfiguration] = (self == .register)
            
            // Only continue if this isn't a new account
            guard self != .register else { return }
            
            // Fetch the
            Onboarding.profileNamePublisher.sinkUntilComplete()
        }
        
        func completeRegistration() {
            // Set the `lastDisplayNameUpdate` to the current date, so that we don't
            // overwrite what the user set in the display name step with whatever we
            // find in their swarm (otherwise the user could enter a display name and
            // have it immediately overwritten due to the config request running slow)
            UserDefaults.standard[.lastDisplayNameUpdate] = Date()
            
            // Notify the app that registration is complete
            Identity.didRegister()
            
            // Now that we have registered get the Snode pool and sync push tokens
            GetSnodePoolJob.run()
            SyncPushTokensJob.run(uploadOnlyIfStale: false)
        }
    }
}
