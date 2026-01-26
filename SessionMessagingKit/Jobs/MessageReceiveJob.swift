// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUtilitiesKit

// MARK: - Log.Category

private extension Log.Category {
    static let cat: Log.Category = .create("MessageReceiveJob", defaultLevel: .info)
}

// MARK: - MessageReceiveJob

public enum MessageReceiveJob: JobExecutor {
    public static var maxFailureCount: Int = 10
    public static var requiresThreadId: Bool = true
    public static let requiresInteractionId: Bool = false
    
    public static func canStart(
        jobState: JobState,
        alongside runningJobs: [JobState],
        using dependencies: Dependencies
    ) -> Bool {
        return true
    }
    
    public static func run(_ job: Job, using dependencies: Dependencies) async throws -> JobExecutionResult {
        guard
            let threadId: String = job.threadId,
            let detailsData: Data = job.details,
            let details: Details = try? JSONDecoder(using: dependencies).decode(Details.self, from: detailsData)
        else { throw JobRunnerError.missingRequiredDetails }
        
        let currentUserSessionIds: Set<String> = try await {
            switch details.messages.first?.threadVariant {
                case .none: throw JobRunnerError.missingRequiredDetails
                case .contact, .group, .legacyGroup:
                    return [dependencies[cache: .general].sessionId.hexString]
                    
                case .community:
                    guard let server: CommunityManager.Server = await dependencies[singleton: .communityManager].server(threadId: threadId) else {
                        return [dependencies[cache: .general].sessionId.hexString]
                    }
                    try Task.checkCancellation()
                    
                    return server.currentUserSessionIds
            }
        }()
        
        /// Shouldn't happen but just in case we may as well succeed immediately
        guard !details.messages.isEmpty else {
            return .success
        }
        
        try await dependencies[singleton: .storage].writeAsync { db in
            var permanentFailures: Int = 0
            var failedMessages: [(info: Details.MessageInfo, error: Error)] = []
            
            for messageInfo in details.messages {
                do {
                    let info: MessageReceiver.InsertedInteractionInfo? = try MessageReceiver.handle(
                        db,
                        threadId: threadId,
                        threadVariant: messageInfo.threadVariant,
                        message: messageInfo.message,
                        decodedMessage: messageInfo.decodedMessage,
                        serverExpirationTimestamp: messageInfo.serverExpirationTimestamp,
                        suppressNotifications: false,
                        currentUserSessionIds: currentUserSessionIds,
                        using: dependencies
                    )
                    
                    /// Notify about the received message
                    MessageReceiver.prepareNotificationsForInsertedInteractions(
                        db,
                        insertedInteractionInfo: info,
                        isMessageRequest: dependencies.mutate(cache: .libSession) { cache in
                            cache.isMessageRequest(threadId: threadId, threadVariant: messageInfo.threadVariant)
                        },
                        using: dependencies
                    )
                }
                catch
                    /// Ignore duplicate, self-send, outdated and ignorable errors (these will usually be caught during parsing but
                    /// sometimes can get past and conflict at database insertion - eg. for open group messages) we also don't
                    /// bother logging as it results in excessive logging which isn't useful)
                    DatabaseError.SQLITE_CONSTRAINT_UNIQUE,
                    DatabaseError.SQLITE_CONSTRAINT,    /// Sometimes thrown for UNIQUE
                    MessageError.duplicateMessage,
                    MessageError.duplicatedCall,
                    MessageError.outdatedMessage,
                    MessageError.ignorableMessage,
                    MessageError.ignorableMessageRequestMessage,
                    MessageError.deprecatedMessage,
                    MessageError.selfSend {}
                catch {
                    switch error {
                        /// The following errors are unrecoverable so don't bother adding them to `failedMessages`
                        case MessageError.encodingFailed,
                            MessageError.decodingFailed,
                            MessageError.invalidMessage,
                            MessageError.missingRequiredField,
                            MessageError.protoConversionFailed,
                            MessageError.unknownMessage,
                            MessageError.requiredSignatureMissing,
                            MessageError.invalidConfigMessageHandling,
                            MessageError.invalidRevokedRetrievalMessageHandling,
                            MessageError.invalidGroupUpdate,
                            MessageError.communitiesDoNotSupportControlMessages,
                            MessageError.requiresGroupId,
                            MessageError.requiresGroupIdentityPrivateKey,
                            MessageError.messageTooLarge,
                            MessageError.invalidSender:
                            Log.error(.cat, "Permanently failed message due to error: \(error)")
                            permanentFailures += 1
                            continue
                            
                        default: failedMessages.append((messageInfo, error))
                    }
                }
            }
            
            /// If all messages were due to permanent failures then permanently fail this job
            guard permanentFailures != details.messages.count else {
                throw JobRunnerError.permanentFailure(MessageError.invalidMessage("All messages failed to process"))
            }
            
            /// If we weren't able to process any messages then we should report this job as a failure
            guard failedMessages.count != details.messages.count else {
                guard !failedMessages.isEmpty else {
                    throw JobRunnerError.permanentFailure(MessageError.invalidMessage("Invalid state"))
                    
                }
                
                for (_, error) in failedMessages {
                    Log.error(.cat, "Couldn't receive message due to error: \(error)")
                }
                
                /// Fail the job with the error of the last message we processed (it doens't really matter which error fails it so
                /// may as well use this one
                throw failedMessages[failedMessages.count - 1].error
            }
            
            /// Otherwise we should schedule another job that only includes the failed messages - this gives those messages another
            /// chance to be processed (in case the failure was due to a race condition) and also allows us to complete this job
            /// successfully
            if !failedMessages.isEmpty {
                dependencies[singleton: .jobRunner].add(
                    db,
                    job: Job(
                        variant: .messageReceive,
                        threadId: threadId,
                        details: Details(messages: failedMessages.map { messageInfo, _ in messageInfo })
                    )
                )
            }
        }
        try Task.checkCancellation()
        
        return .success
    }
}

// MARK: - MessageReceiveJob.Details

extension MessageReceiveJob {
    public struct Details: Codable {
        public struct MessageInfo: Codable {
            private enum CodingKeys: String, CodingKey {
                case message
                case variant
                case threadVariant
                case serverExpirationTimestamp
                @available(*, deprecated, message: "'serializedProtoData' has been removed, access `decodedMesage` instead")
                case serializedProtoData
                case decodedMessage
            }
            
            public let message: Message
            public let variant: Message.Variant
            public let threadVariant: SessionThread.Variant
            public let serverExpirationTimestamp: TimeInterval?
            public let decodedMessage: DecodedMessage
            
            public init(
                message: Message,
                variant: Message.Variant,
                threadVariant: SessionThread.Variant,
                serverExpirationTimestamp: TimeInterval?,
                decodedMessage: DecodedMessage
            ) {
                self.message = message
                self.variant = variant
                self.threadVariant = threadVariant
                self.serverExpirationTimestamp = serverExpirationTimestamp
                self.decodedMessage = decodedMessage
            }
            
            // MARK: - Codable
            
            public init(from decoder: Decoder) throws {
                let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
                
                guard let variant: Message.Variant = try? container.decode(Message.Variant.self, forKey: .variant) else {
                    Log.error(.cat, "Unable to decode messageReceive job due to missing variant")
                    throw StorageError.decodingFailed
                }
                
                let message: Message = try variant.decode(from: container, forKey: .message)
                // FIXME: Remove this once 2.15.0 has been out for long enough
                let decodedMessage: DecodedMessage
                if
                    let sender: SessionId = try? SessionId(from: message.sender),
                    let sentTimestampMs: UInt64 = message.sentTimestampMs,
                    let legacyProtoData: Data = try container.decodeIfPresent(Data.self, forKey: .serializedProtoData)
                {
                    decodedMessage = DecodedMessage(
                        content: legacyProtoData,
                        sender: sender,
                        decodedEnvelope: nil,
                        sentTimestampMs: sentTimestampMs
                    )
                }
                else {
                    decodedMessage = try container.decode(DecodedMessage.self, forKey: .decodedMessage)
                }
                
                self = MessageInfo(
                    message: message,
                    variant: variant,
                    threadVariant: try container.decode(SessionThread.Variant.self, forKey: .threadVariant),
                    serverExpirationTimestamp: try? container.decode(TimeInterval.self, forKey: .serverExpirationTimestamp),
                    decodedMessage: decodedMessage
                )
            }
            
            public func encode(to encoder: Encoder) throws {
                var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
                
                guard let variant: Message.Variant = Message.Variant(from: message) else {
                    Log.error(.cat, "Unable to encode messageReceive job due to unsupported variant")
                    throw StorageError.objectNotFound
                }

                try container.encode(message, forKey: .message)
                try container.encode(variant, forKey: .variant)
                try container.encode(threadVariant, forKey: .threadVariant)
                try container.encodeIfPresent(serverExpirationTimestamp, forKey: .serverExpirationTimestamp)
                try container.encode(decodedMessage, forKey: .decodedMessage)
            }
        }
        
        public let messages: [MessageInfo]
        
        public init(messages: [ProcessedMessage]) {
            self.messages = messages.compactMap { processedMessage in
                switch processedMessage {
                    case .config: return nil
                    case .standard(_, _, let messageInfo, _): return messageInfo
                }
            }
        }
        
        public init(messages: [MessageInfo]) {
            self.messages = messages
        }
    }
}
