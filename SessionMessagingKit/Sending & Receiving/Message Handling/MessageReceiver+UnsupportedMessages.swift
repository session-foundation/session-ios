// Copyright © 2026 Session Technology Foundation. All rights reserved.

import Foundation
import GRDB
import SessionNetworkingKit
import SessionUtilitiesKit

extension MessageReceiver {
    internal static func handleUnsupportedMessage(
        _ db: ObservingDatabase,
        threadId: String,
        threadVariant: SessionThread.Variant,
        message: UnsupportedMessage,
        serverExpirationTimestamp: TimeInterval?,
        using dependencies: Dependencies
    ) throws -> InsertedInteractionInfo? {
        guard
            let serverHash: String = message.serverHash,
            try UnsupportedMessageRecord
                .filter(UnsupportedMessageRecord.Columns.hash == serverHash)
                .isEmpty(db)
        else { return nil }

        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        let serverExpiryMs: Int64? = serverExpirationTimestamp.map { Int64($0 * 1000) }

        /// Never create a conversation (or message request) for something we can't show, the record is still retained either way
        let placeholderVariant: Interaction.Variant? = try {
            switch message.placement {
                case .none: return nil
                case .incoming, .outgoing:
                    guard try SessionThread.exists(db, id: threadId) else { return nil }

                    return (message.placement == .outgoing ? .standardOutgoingUnsupported : .standardIncomingUnsupported)
            }
        }()
        var insertedInteractionInfo: InsertedInteractionInfo?

        if let variant: Interaction.Variant = placeholderVariant {
            let timestampMs: Int64 = Int64(message.sentTimestampMs ?? 0)
            let wasRead: Bool = (
                variant == .standardOutgoingUnsupported ||
                dependencies.mutate(cache: .libSession) { cache in
                    cache.timestampAlreadyRead(
                        threadId: threadId,
                        threadVariant: threadVariant,
                        timestampMs: UInt64(timestampMs),
                        openGroupUrlInfo: nil
                    )
                }
            )
            let messageExpirationInfo: Message.MessageExpirationInfo = Message.getMessageExpirationInfo(
                threadVariant: threadVariant,
                wasRead: wasRead,
                serverExpirationTimestamp: serverExpirationTimestamp,
                expiresInSeconds: message.expiresInSeconds,
                expiresStartedAtMs: message.expiresStartedAtMs,
                using: dependencies
            )
            let interaction: Interaction = try Interaction(
                serverHash: serverHash,
                threadId: threadId,
                threadVariant: threadVariant,
                authorId: (message.sender ?? userSessionId.hexString),
                variant: variant,
                timestampMs: timestampMs,
                wasRead: wasRead,
                expiresInSeconds: messageExpirationInfo.expiresInSeconds,
                expiresStartedAtMs: messageExpirationInfo.expiresStartedAtMs,
                using: dependencies
            ).inserted(db)

            if messageExpirationInfo.shouldUpdateExpiry {
                Message.updateExpiryForDisappearAfterReadMessages(
                    db,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    serverHash: serverHash,
                    expiresInSeconds: messageExpirationInfo.expiresInSeconds,
                    expiresStartedAtMs: messageExpirationInfo.expiresStartedAtMs,
                    using: dependencies
                )
            }

            insertedInteractionInfo = interaction.id.map { (threadId, threadVariant, $0, variant, wasRead, 0) }
        }

        var record: UnsupportedMessageRecord = UnsupportedMessageRecord(
            kind: message.kind,
            swarmPublicKey: message.swarmPublicKey,
            namespace: message.namespace.rawValue,
            hash: serverHash,
            serverTimestampMs: message.serverTimestampMs,
            serverExpiryMs: serverExpiryMs,
            data: message.rawData,
            placeholderMessageId: insertedInteractionInfo?.interactionId,
            expiresAtMs: (insertedInteractionInfo != nil ? nil :
                retainedExpiryMs(message: message, serverExpiryMs: serverExpiryMs)
            ),
            receivedAtMs: dependencies.networkOffsetTimestampMs(),
            lastAttemptVersion: UnsupportedMessageRecord.currentVersion(using: dependencies)
        )
        try record.insert(db)
        try UnsupportedMessageRecord.enforceLimits(db, using: dependencies)

        /// Only surface the banner for things which tell us this device is behind and which a stranger can't use to make claims
        /// about who sent what (an unknown type from someone else either has a bubble or came from a stranger)
        switch (message.kind, message.placement) {
            case (.newerFormat, _):
                UnsupportedMessageBanner.recordTrigger(db, trigger: .newerFormat, using: dependencies)

            case (.unknownType, .none) where message.sender == userSessionId.hexString:
                UnsupportedMessageBanner.recordTrigger(db, trigger: .otherDevice, using: dependencies)

            default: break
        }

        return insertedInteractionInfo
    }

    /// When a retained message has no placeholder there is no interaction to own its expiry, so work out when the record itself
    /// should be removed
    private static func retainedExpiryMs(message: UnsupportedMessage, serverExpiryMs: Int64?) -> Int64? {
        /// A disappear-after-send setting can be read from an `unknownType` message (disappear-after-read can never start as the
        /// message is never shown)
        if
            let expiresStartedAtMs: Double = message.expiresStartedAtMs,
            let expiresInSeconds: TimeInterval = message.expiresInSeconds,
            expiresInSeconds > 0
        {
            return Int64(expiresStartedAtMs + (expiresInSeconds * 1000))
        }

        /// Otherwise the swarm expiry is the only signal, and it only indicates a disappearing message when it is shorter than the
        /// default message TTL (disappear-after-send messages are stored with a TTL matching their timer)
        guard
            let serverExpiryMs: Int64 = serverExpiryMs,
            (serverExpiryMs - message.serverTimestampMs) < Network.StorageServer.Message.defaultExpirationMs
        else { return nil }

        return serverExpiryMs
    }
}

// MARK: - UnsupportedMessageBanner

// stringlint:ignore_contents
public extension KeyValueStore.Int64Key {
    static let unsupportedMessageBannerTriggeredAtMs: KeyValueStore.Int64Key = "unsupportedMessageBannerTriggeredAtMs"
    static let unsupportedMessageBannerOtherDeviceTriggeredAtMs: KeyValueStore.Int64Key = "unsupportedMessageBannerOtherDeviceTriggeredAtMs"
    static let unsupportedMessageBannerDismissedAtMs: KeyValueStore.Int64Key = "unsupportedMessageBannerDismissedAtMs"
}

public enum UnsupportedMessageBanner {
    /// After being dismissed the banner only reappears for a trigger at least this long after the dismissal, a stranger can deposit
    /// newer-format data into a one-to-one namespace so this bounds how often they can bring it back
    public static let reappearAfterDismissalMs: Int64 = (7 * 24 * 60 * 60 * 1000)

    public enum Trigger {
        case newerFormat

        /// An `unknownType` message which came from one of our own devices but couldn't be placed in a conversation
        case otherDevice
    }

    public enum State: Equatable {
        case hidden
        case general
        case otherDevice

        public var text: String? {
            // FIXME: Move these to Crowdin once the design is settled
            switch self {
                case .hidden: return nil
                case .general:
                    return "Some messages can't be shown on this device. Update Session to read them." // stringlint:ignore

                case .otherDevice:
                    return "One of your other devices is using a newer version of Session. Update this device to keep your messages in sync." // stringlint:ignore
            }
        }
    }

    public static let observedKeys: [KeyValueStore.Int64Key] = [
        .unsupportedMessageBannerTriggeredAtMs,
        .unsupportedMessageBannerOtherDeviceTriggeredAtMs,
        .unsupportedMessageBannerDismissedAtMs
    ]

    static func recordTrigger(_ db: ObservingDatabase, trigger: Trigger, using dependencies: Dependencies) {
        let nowMs: Int64 = dependencies.networkOffsetTimestampMs()

        db[.unsupportedMessageBannerTriggeredAtMs] = nowMs

        if trigger == .otherDevice {
            db[.unsupportedMessageBannerOtherDeviceTriggeredAtMs] = nowMs
        }
    }

    public static func dismiss(_ db: ObservingDatabase, using dependencies: Dependencies) {
        db[.unsupportedMessageBannerDismissedAtMs] = dependencies.networkOffsetTimestampMs()
    }

    public static func state(_ db: ObservingDatabase) -> State {
        return state(
            triggeredAtMs: db[.unsupportedMessageBannerTriggeredAtMs],
            otherDeviceTriggeredAtMs: db[.unsupportedMessageBannerOtherDeviceTriggeredAtMs],
            dismissedAtMs: db[.unsupportedMessageBannerDismissedAtMs]
        )
    }

    public static func state(triggeredAtMs: Int64?, otherDeviceTriggeredAtMs: Int64?, dismissedAtMs: Int64?) -> State {
        guard let triggeredAtMs: Int64 = triggeredAtMs else { return .hidden }

        let visibleFromMs: Int64 = dismissedAtMs.map { $0 + reappearAfterDismissalMs } ?? Int64.min

        guard triggeredAtMs >= visibleFromMs else { return .hidden }

        guard
            let otherDeviceTriggeredAtMs: Int64 = otherDeviceTriggeredAtMs,
            otherDeviceTriggeredAtMs >= visibleFromMs
        else { return .general }
        
        return .otherDevice
    }
}
