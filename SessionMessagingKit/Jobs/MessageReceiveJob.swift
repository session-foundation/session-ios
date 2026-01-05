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
    
    public static func run<S: Scheduler>(
        _ job: Job,
        scheduler: S,
        success: @escaping (Job, Bool) -> Void,
        failure: @escaping (Job, Error, Bool) -> Void,
        deferred: @escaping (Job) -> Void,
        using dependencies: Dependencies
    ) {
        guard
            let threadId: String = job.threadId,
            let detailsData: Data = job.details,
            let details: Details = try? JSONDecoder(using: dependencies).decode(Details.self, from: detailsData)
        else { return failure(job, JobRunnerError.missingRequiredDetails, true) }
        
        Task {
            typealias Result = (
                updatedJob: Job,
                lastError: Error?,
                remainingMessagesToProcess: [Details.MessageInfo]
            )
            
            do {
                let currentUserSessionIds: Set<String> = try await {
                    switch details.messages.first?.threadVariant {
                        case .none: throw JobRunnerError.missingRequiredDetails
                        case .contact, .group, .legacyGroup:
                            return [dependencies[cache: .general].sessionId.hexString]
                            
                        case .community:
                            guard let server: CommunityManager.Server = await dependencies[singleton: .communityManager].server(threadId: threadId) else {
                                return [dependencies[cache: .general].sessionId.hexString]
                            }
                            
                            return server.currentUserSessionIds
                    }
                }()
                
                let result: Result = try await dependencies[singleton: .storage].writeAsync { db in
                    var lastError: Error?
                    var remainingMessagesToProcess: [Details.MessageInfo] = []
                    
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
                        catch {
                            // If the current message is a permanent failure then override it with the
                            // new error (we want to retry if there is a single non-permanent error)
                            switch error {
                                    // Ignore duplicate and self-send errors (these will usually be caught during
                                    // parsing but sometimes can get past and conflict at database insertion - eg.
                                    // for open group messages) we also don't bother logging as it results in
                                    // excessive logging which isn't useful)
                                case DatabaseError.SQLITE_CONSTRAINT_UNIQUE,
                                    DatabaseError.SQLITE_CONSTRAINT,    // Sometimes thrown for UNIQUE
                                    MessageError.duplicateMessage,
                                    MessageError.selfSend:
                                    break
                                    
                                case is MessageError:
                                    Log.error(.cat, "Permanently failed message due to error: \(error)")
                                    continue
                                    
                                default:
                                    Log.error(.cat, "Couldn't receive message due to error: \(error)")
                                    lastError = error
                                    
                                    // We failed to process this message but it is a retryable error
                                    // so add it to the list to re-process
                                    remainingMessagesToProcess.append(messageInfo)
                            }
                        }
                    }
                    
                    /// If any messages failed to process then we want to update the job to only include those failed messages
                    guard !remainingMessagesToProcess.isEmpty else { return (job, lastError, []) }
                    
                    return (
                        try job
                            .with(details: Details(messages: remainingMessagesToProcess))
                            .defaulting(to: job)
                            .upserted(db),
                        lastError,
                        remainingMessagesToProcess
                    )
                }
                
                return scheduler.schedule {
                    /// Report the result of the job
                    switch result.lastError {
                        case let error as MessageError: failure(result.updatedJob, error, true)
                        case .some(let error): failure(result.updatedJob, error, false)
                        case .none: success(result.updatedJob, false)
                    }
                    
                    success(result.updatedJob, false)
                }
            }
            catch {
                return scheduler.schedule {
                    failure(job, error, false)
                }
            }
        }
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
                // FIXME: Remove this once pro has been out for long enough
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
