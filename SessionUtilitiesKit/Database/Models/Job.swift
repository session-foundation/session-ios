// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import GRDB

public protocol UniqueHashable {
    var customHash: Int { get }
}

public struct Job: Codable, Equatable, Hashable, Identifiable, FetchableRecord, MutablePersistableRecord, TableRecord, ColumnExpressible {
    public static var databaseTableName: String { "job" }
    
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case failureCount
        case variant
        case threadId
        case interactionId
        case details
    }
    
    public enum Variant: Int, Codable, DatabaseValueConvertible, CaseIterable {
        // Deprecated Jobs
        case _legacy_getSnodePool = 1
        case _legacy_buildPaths = 3009
        case _legacy_getSwarm = 3010
        case _legacy_notifyPushServer = 2001
        
        /// This is a recurring job that handles the removal of disappearing messages and is triggered
        /// at the timestamp of the next disappearing message
        case disappearingMessages = 0
        
        /// This is a recurring job that checks if the user needs to re-upload their profile picture on launch
        case reuploadUserDisplayPicture = 2
        
        /// This is a recurring job that ensures the app fetches the default open group rooms on launch
        case retrieveDefaultOpenGroupRooms
        
        /// This is a recurring job that removes expired and orphaned data, it runs on launch and can also be triggered
        /// as 'runOnce' to avoid waiting until the next launch to clear data
        case garbageCollection
        
        /// This is a recurring job that runs on launch and flags any messages marked as 'sending' to
        /// be in their 'failed' state
        ///
        /// **Note:** This is a blocking job so it will run before any other jobs and prevent them from
        /// running until it's complete
        case failedMessageSends = 1000
        
        /// This is a recurring job that runs on launch and flags any attachments marked as 'uploading' to
        /// be in their 'failed' state
        ///
        /// **Note:** This is a blocking job so it will run before any other jobs and prevent them from
        /// running until it's complete
        case failedAttachmentDownloads
        
        /// This is a recurring job that runs on return from background and registeres and uploads the
        /// latest device push tokens
        case syncPushTokens = 2000
        
        /// This is a job that runs once at most every 3 seconds per thread whenever a message is marked as read
        /// (if read receipts are enabled) to notify other members in a conversation that their message was read
        case sendReadReceipts = 2002
        
        /// This is a job that runs once whenever a message is received to attempt to decode and properly
        /// process the message
        case messageReceive = 3000
        
        /// This is a job that runs once whenever a message is sent to attempt to encode and properly
        /// send the message
        case messageSend
        
        /// This is a job that runs once whenever an attachment is uploaded to attempt to encode and properly
        /// upload the attachment
        case attachmentUpload
        
        /// This is a job that runs once whenever an attachment is downloaded to attempt to decode and properly
        /// download the attachment
        case attachmentDownload

        /// This is a job that runs once whenever the user leaves a group to send a group leaving message, remove group
        /// record and group member record
        case groupLeaving
        
        /// This is a job that runs once whenever the user config or a closed group config changes, it retrieves the
        /// state of all config objects and syncs any that are flagged as needing to be synced
        case configurationSync
        
        /// This is a job that runs once whenever a config message is received to attempt to decode it and update the
        /// config state with the changes; this job will generally be scheduled along since a `messageReceive` job
        /// and will block the standard message receive job
        case configMessageReceive
        
        /// This is a job that runs once whenever disappearing after read messages are read and needed to update the
        /// expiration on the network
        case expirationUpdate
        
        /// This is a job that runs once whenever a message is marked as read because of syncing from user config and
        /// needs to get expiration from network
        case getExpiration

        /// This is a job that runs at most once every 24 hours in order to check if there is a new update available on GitHub
        case checkForAppUpdates = 3011
        
        /// This is a job which downloads a display picture for a user, group or community (it's separate from the
        /// `attachmentDownloadJob` as these files are likely to be much smaller so we don't want them to be
        /// blocked by larger attachment downloads
        case displayPictureDownload
        
        /// This is a job which sends an invitation to a member of a group asynchronously so the admin doesn't need to
        /// wait during group creation
        case groupInviteMember
        
        /// This is a job which sends a promotion to a member of a group asynchronously so the admin doesn't need to
        /// wait during promotions
        case groupPromoteMember
        
        /// This is a job which checks for any pending group member removals and performs the tasks required to remove
        /// them if any exist - only one job can run at a time (if there is already a running job then any subsequent job will
        /// be deferred until it completes)
        case processPendingGroupMemberRemovals
        
        /// This is a job which checks for any pending group member invitations or promotions and marks them as failed
        ///
        /// **Note:** This is a blocking job so it will run before any other jobs and prevent them from
        /// running until it's complete
        case failedGroupInvitesAndPromotions
    }
    
    /// The `id` value is auto incremented by the database, if the `Job` hasn't been inserted into
    /// the database yet this value will be `nil`
    public var id: Int64? = nil
    
    /// A counter for the number of times this job has failed
    public let failureCount: UInt
    
    /// The type of job
    public let variant: Variant
    
    /// The id of the thread this job is associated with, if the associated thread is deleted this job will
    /// also be deleted
    ///
    /// **Note:** This will only be populated for Jobs associated to threads
    public let threadId: String?
    
    /// The id of the interaction this job is associated with, if the associated interaction is deleted this
    /// job will also be deleted
    ///
    /// **Note:** This will only be populated for Jobs associated to interactions
    public let interactionId: Int64?
    
    /// JSON encoded data required for the job
    public let details: Data?
    
    /// Extra data which can be attached to a job that doesn't get persisted to the database (generally used for running
    /// a job directly which may need some special behaviour)
    public let transientData: Any?
    
    // MARK: - Initialization
    
    internal init(
        id: Int64?,
        failureCount: UInt,
        variant: Variant,
        threadId: String?,
        interactionId: Int64?,
        details: Data?,
        transientData: Any?
    ) {
        self.id = id
        self.failureCount = failureCount
        self.variant = variant
        self.threadId = threadId
        self.interactionId = interactionId
        self.details = details
        self.transientData = transientData
    }
    
    public init(
        failureCount: UInt = 0,
        variant: Variant,
        threadId: String? = nil,
        interactionId: Int64? = nil,
        transientData: Any? = nil
    ) {
        self.failureCount = failureCount
        self.variant = variant
        self.threadId = threadId
        self.interactionId = interactionId
        self.details = nil
        self.transientData = transientData
    }
    
    public init?<T: Encodable>(
        failureCount: UInt = 0,
        variant: Variant,
        threadId: String? = nil,
        interactionId: Int64? = nil,
        details: T?,
        transientData: Any? = nil
    ) {
        precondition(T.self != Job.self, "[Job] Fatal error trying to create a Job with a Job as it's details")
        
        guard
            let details: T = details,
            let detailsData: Data = try? JSONEncoder()
                .with(outputFormatting: .sortedKeys)    // Needed for deterministic comparison
                .encode(details)
        else { return nil }
        
        self.failureCount = failureCount
        self.variant = variant
        self.threadId = threadId
        self.interactionId = interactionId
        self.details = detailsData
        self.transientData = transientData
    }
    
    // MARK: - Custom Database Interaction
    
    public mutating func didInsert(_ inserted: InsertionSuccess) {
        self.id = inserted.rowID
    }
}

// MARK: - Codable

public extension Job {
    init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        
        self = Job(
            id: try container.decodeIfPresent(Int64.self, forKey: .id),
            failureCount: try container.decode(UInt.self, forKey: .failureCount),
            variant: try container.decode(Variant.self, forKey: .variant),
            threadId: try container.decodeIfPresent(String.self, forKey: .threadId),
            interactionId: try container.decodeIfPresent(Int64.self, forKey: .interactionId),
            details: try container.decodeIfPresent(Data.self, forKey: .details),
            transientData: nil
        )
    }
    
    func encode(to encoder: Encoder) throws {
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)

        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(failureCount, forKey: .failureCount)
        try container.encode(variant, forKey: .variant)
        try container.encodeIfPresent(threadId, forKey: .threadId)
        try container.encodeIfPresent(interactionId, forKey: .interactionId)
        try container.encodeIfPresent(details, forKey: .details)
    }
}

// MARK: - Equatable

public extension Job {
    static func == (lhs: Job, rhs: Job) -> Bool {
        return (
            lhs.id == rhs.id &&
            lhs.failureCount == rhs.failureCount &&
            lhs.variant == rhs.variant &&
            lhs.threadId == rhs.threadId &&
            lhs.interactionId == rhs.interactionId &&
            lhs.details == rhs.details
            /// `transientData` ignored for equality check
        )
    }
}

// MARK: - Hashable

public extension Job {
    func hash(into hasher: inout Hasher) {
        id?.hash(into: &hasher)
        failureCount.hash(into: &hasher)
        variant.hash(into: &hasher)
        threadId?.hash(into: &hasher)
        interactionId?.hash(into: &hasher)
        details?.hash(into: &hasher)
        /// `transientData` ignored for hashing
    }
}

// MARK: - Convenience

public extension Job {
    func with(
        failureCount: UInt
    ) -> Job {
        return Job(
            id: self.id,
            failureCount: failureCount,
            variant: self.variant,
            threadId: self.threadId,
            interactionId: self.interactionId,
            details: self.details,
            transientData: self.transientData
        )
    }
    
    func with<T: Encodable>(details: T) -> Job? {
        guard
            let detailsData: Data = try? JSONEncoder()
                .with(outputFormatting: .sortedKeys)    // Needed for deterministic comparison
                .encode(details)
        else { return nil }
        
        return Job(
            id: self.id,
            failureCount: self.failureCount,
            variant: self.variant,
            threadId: self.threadId,
            interactionId: self.interactionId,
            details: detailsData,
            transientData: self.transientData
        )
    }
}
