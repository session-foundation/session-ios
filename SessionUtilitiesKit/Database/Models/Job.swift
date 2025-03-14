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
    internal static let dependencyForeignKey = ForeignKey([Columns.id], to: [JobDependencies.Columns.dependantId])
    public static let dependantJobDependency = hasMany(
        JobDependencies.self,
        using: JobDependencies.jobForeignKey
    )
    public static let dependancyJobDependency = hasMany(
        JobDependencies.self,
        using: JobDependencies.dependantForeignKey
    )
    internal static let jobsThisJobDependsOn = hasMany(
        Job.self,
        through: dependantJobDependency,
        using: JobDependencies.dependant
    )
    internal static let jobsThatDependOnThisJob = hasMany(
        Job.self,
        through: dependancyJobDependency,
        using: JobDependencies.job
    )
    
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case priority
        case failureCount
        case variant
        case behaviour
        case shouldBlock
        case shouldSkipLaunchBecomeActive
        case nextRunTimestamp
        case threadId
        case interactionId
        case details
        case uniqueHashValue
    }
    
    public enum Variant: Int, Codable, DatabaseValueConvertible, CaseIterable {
        // Deprecated Jobs
        case _legacy_getSnodePool = 1
        case _legacy_buildPaths = 3009
        case _legacy_getSwarm = 3010
        
        /// This is a recurring job that handles the removal of disappearing messages and is triggered
        /// at the timestamp of the next disappearing message
        case disappearingMessages = 0
        
        /// This is a recurring job that checks if the user needs to update their profile picture on launch, and if so
        /// attempt to download the latest
        case updateProfilePicture = 2
        
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
        
        /// This is a job that runs once whenever a message is sent to notify the push notification server
        /// about the message
        case notifyPushServer
        
        /// This is a job that runs once at most every 3 seconds per thread whenever a message is marked as read
        /// (if read receipts are enabled) to notify other members in a conversation that their message was read
        case sendReadReceipts
        
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
    
    public enum Behaviour: Int, Codable, DatabaseValueConvertible, CaseIterable {
        /// This job will run once and then be removed from the jobs table
        case runOnce
        
        /// This job will run once the next time the app launches and then be removed from the jobs table
        case runOnceNextLaunch
        
        /// This job will run and then will be updated with a new `nextRunTimestamp` (at least 1 second in
        /// the future) in order to be run again
        case recurring
        
        /// This job will run once each launch and may run again during the same session if `nextRunTimestamp`
        /// gets set
        case recurringOnLaunch
        
        /// This job will run once each whenever the app becomes active (launch and return from background) and
        /// may run again during the same session if `nextRunTimestamp` gets set
        case recurringOnActive
        
        /// This job will run once after a config sync (the config sync will filter to match a jobs to the same `threadId` as the config
        /// but then the individual job will need it's own handling about whether it can run or not)
        ///
        /// **Note:** Jobs run with this behaviour will retry whenever a config sync occurs (or on launch since we automatically
        /// enqueue a config sync for all configs on launch) and ignore the `maxFailureCount` so will retry indefinitely
        case runOnceAfterConfigSyncIgnoringPermanentFailure
    }
    
    /// The `id` value is auto incremented by the database, if the `Job` hasn't been inserted into
    /// the database yet this value will be `nil`
    public var id: Int64? = nil
    
    /// The `priority` value is used to allow for forcing some jobs to run before others (Default value `0`)
    ///
    /// Jobs will be run in the following order:
    /// - Jobs scheduled in the past (or with no `nextRunTimestamp`) first
    /// - Jobs with a higher `priority` value
    /// - Jobs with a sooner `nextRunTimestamp` value
    /// - The order the job was inserted into the database
    public var priority: Int64
    
    /// A counter for the number of times this job has failed
    public let failureCount: UInt
    
    /// The type of job
    public let variant: Variant
    
    /// How the job should behave
    public let behaviour: Behaviour
    
    /// When the app starts this flag controls whether the job should prevent other jobs from starting until after it completes
    ///
    /// **Note:** This flag is only supported for jobs with an `OnLaunch` behaviour because there is no way to guarantee
    /// jobs with any other behaviours will be added to the JobRunner before all the `OnLaunch` blocking jobs are completed
    /// resulting in the JobRunner no longer blocking
    public let shouldBlock: Bool
    
    /// When the app starts it also triggers any `OnActive` jobs, this flag controls whether the job should skip this initial `OnActive`
    /// trigger (generally used for the same job registered with both `OnLaunch` and `OnActive` behaviours)
    public let shouldSkipLaunchBecomeActive: Bool
    
    /// Seconds since epoch to indicate the next datetime that this job should run
    public let nextRunTimestamp: TimeInterval
    
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
    
    /// When initalizing with `shouldBeUnique` set to `true` this value will be populated with a hash constructed by
    /// combining the `variant`, `threadId`, `interactionId` and `details` and if this value is populated
    /// adding/inserting a `Job` will fail if there is already a job with the same `uniqueHashValue` in the database or
    /// in the `JobRunner`
    public let uniqueHashValue: Int?
    
    /// Extra data which can be attached to a job that doesn't get persisted to the database (generally used for running
    /// a job directly which may need some special behaviour)
    public let transientData: Any?
    
    /// The other jobs which this job is dependant on
    ///
    /// **Note:** When completing a job the dependencies **MUST** be cleared before the job is
    /// deleted or it will automatically delete any dependant jobs
    public var dependencies: QueryInterfaceRequest<Job> {
        request(for: Job.jobsThisJobDependsOn)
    }
    
    /// The other jobs which depend on this job
    ///
    /// **Note:** When completing a job the dependencies **MUST** be cleared before the job is
    /// deleted or it will automatically delete any dependant jobs
    public var dependantJobs: QueryInterfaceRequest<Job> {
        request(for: Job.jobsThatDependOnThisJob)
    }
    
    // MARK: - Initialization
    
    fileprivate init(
        id: Int64?,
        priority: Int64,
        failureCount: UInt,
        variant: Variant,
        behaviour: Behaviour,
        shouldBlock: Bool,
        shouldSkipLaunchBecomeActive: Bool,
        nextRunTimestamp: TimeInterval,
        threadId: String?,
        interactionId: Int64?,
        details: Data?,
        uniqueHashValue: Int?,
        transientData: Any?
    ) {
        self.id = id
        self.priority = priority
        self.failureCount = failureCount
        self.variant = variant
        self.behaviour = behaviour
        self.shouldBlock = shouldBlock
        self.shouldSkipLaunchBecomeActive = shouldSkipLaunchBecomeActive
        self.nextRunTimestamp = nextRunTimestamp
        self.threadId = threadId
        self.interactionId = interactionId
        self.details = details
        self.uniqueHashValue = uniqueHashValue
        self.transientData = transientData
    }
    
    internal init(
        id: Int64?,
        priority: Int64 = 0,
        failureCount: UInt,
        variant: Variant,
        behaviour: Behaviour,
        shouldBlock: Bool,
        shouldBeUnique: Bool,
        shouldSkipLaunchBecomeActive: Bool,
        nextRunTimestamp: TimeInterval,
        threadId: String?,
        interactionId: Int64?,
        details: Data?,
        transientData: Any?
    ) {
        Job.ensureValidBehaviour(
            behaviour: behaviour,
            shouldBlock: shouldBlock,
            shouldSkipLaunchBecomeActive: shouldSkipLaunchBecomeActive
        )
        
        self.id = id
        self.priority = priority
        self.failureCount = failureCount
        self.variant = variant
        self.behaviour = behaviour
        self.shouldBlock = shouldBlock
        self.shouldSkipLaunchBecomeActive = shouldSkipLaunchBecomeActive
        self.nextRunTimestamp = nextRunTimestamp
        self.threadId = threadId
        self.interactionId = interactionId
        self.details = details
        self.uniqueHashValue = Job.createUniqueHash(
            shouldBeUnique: shouldBeUnique,
            customHash: nil,
            variant: variant,
            threadId: threadId,
            interactionId: interactionId,
            detailsData: details
        )
        self.transientData = transientData
    }
    
    public init(
        priority: Int64 = 0,
        failureCount: UInt = 0,
        variant: Variant,
        behaviour: Behaviour = .runOnce,
        shouldBlock: Bool = false,
        shouldBeUnique: Bool = false,
        shouldSkipLaunchBecomeActive: Bool = false,
        nextRunTimestamp: TimeInterval = 0,
        threadId: String? = nil,
        interactionId: Int64? = nil,
        transientData: Any? = nil
    ) {
        Job.ensureValidBehaviour(
            behaviour: behaviour,
            shouldBlock: shouldBlock,
            shouldSkipLaunchBecomeActive: shouldSkipLaunchBecomeActive
        )
        
        self.priority = priority
        self.failureCount = failureCount
        self.variant = variant
        self.behaviour = behaviour
        self.shouldBlock = shouldBlock
        self.shouldSkipLaunchBecomeActive = shouldSkipLaunchBecomeActive
        self.nextRunTimestamp = nextRunTimestamp
        self.threadId = threadId
        self.interactionId = interactionId
        self.details = nil
        self.uniqueHashValue = Job.createUniqueHash(
            shouldBeUnique: shouldBeUnique,
            customHash: nil,
            variant: variant,
            threadId: threadId,
            interactionId: interactionId,
            detailsData: nil
        )
        self.transientData = transientData
    }
    
    public init?<T: Encodable>(
        priority: Int64 = 0,
        failureCount: UInt = 0,
        variant: Variant,
        behaviour: Behaviour = .runOnce,
        shouldBlock: Bool = false,
        shouldBeUnique: Bool = false,
        shouldSkipLaunchBecomeActive: Bool = false,
        nextRunTimestamp: TimeInterval = 0,
        threadId: String? = nil,
        interactionId: Int64? = nil,
        details: T?,
        transientData: Any? = nil
    ) {
        precondition(T.self != Job.self, "[Job] Fatal error trying to create a Job with a Job as it's details")
        Job.ensureValidBehaviour(
            behaviour: behaviour,
            shouldBlock: shouldBlock,
            shouldSkipLaunchBecomeActive: shouldSkipLaunchBecomeActive
        )
        
        guard
            let details: T = details,
            let detailsData: Data = try? JSONEncoder()
                .with(outputFormatting: .sortedKeys)    // Needed for deterministic comparison
                .encode(details)
        else { return nil }
        
        self.priority = priority
        self.failureCount = failureCount
        self.variant = variant
        self.behaviour = behaviour
        self.shouldBlock = shouldBlock
        self.shouldSkipLaunchBecomeActive = shouldSkipLaunchBecomeActive
        self.nextRunTimestamp = nextRunTimestamp
        self.threadId = threadId
        self.interactionId = interactionId
        self.details = detailsData
        self.uniqueHashValue = Job.createUniqueHash(
            shouldBeUnique: shouldBeUnique,
            customHash: (details as? UniqueHashable)?.customHash,
            variant: variant,
            threadId: threadId,
            interactionId: interactionId,
            detailsData: detailsData
        )
        self.transientData = transientData
    }
    
    fileprivate static func ensureValidBehaviour(
        behaviour: Behaviour,
        shouldBlock: Bool,
        shouldSkipLaunchBecomeActive: Bool
    ) {
        // Blocking jobs can only run on launch as we can't guarantee that any other behaviours will get added
        // to the JobRunner before any prior blocking jobs have completed (resulting in them being non-blocking)
        let blockingValid: Bool = (!shouldBlock || behaviour == .recurringOnLaunch || behaviour == .runOnceNextLaunch)
        let becomeActiveValid: Bool = (!shouldSkipLaunchBecomeActive || behaviour == .recurringOnActive)
        precondition(blockingValid, "[Job] Fatal error trying to create a blocking job which doesn't run on launch")
        precondition(becomeActiveValid, "[Job] Fatal error trying to create a job which skips on 'OnActive' triggered during launch with doesn't run on active")
    }
    
    private static func createUniqueHash(
        shouldBeUnique: Bool,
        customHash: Int?,
        variant: Variant,
        threadId: String?,
        interactionId: Int64?,
        detailsData: Data?
    ) -> Int? {
        // Only generate a unique hash if the Job should actually be unique (we don't want to prevent
        // all duplicate jobs, just the ones explicitly marked as unique)
        guard shouldBeUnique else { return nil }
        
        switch customHash {
            case .some(let customHash): return customHash
            default:
                var hasher: Hasher = Hasher()
                variant.hash(into: &hasher)
                threadId?.hash(into: &hasher)
                interactionId?.hash(into: &hasher)
                detailsData?.hash(into: &hasher)
                
                return hasher.finalize()
        }
    }
    
    private static func createUniqueHash(
        shouldBeUnique: Bool,
        variant: Variant,
        threadId: String?,
        interactionId: Int64?,
        detailsData: Data?
    ) -> Int? {
        // Only generate a unique hash if the Job should actually be unique (we don't want to prevent
        // all duplicate jobs, just the ones explicitly marked as unique)
        guard shouldBeUnique else { return nil }
        
        var hasher: Hasher = Hasher()
        variant.hash(into: &hasher)
        threadId?.hash(into: &hasher)
        interactionId?.hash(into: &hasher)
        detailsData?.hash(into: &hasher)
        
        return hasher.finalize()
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
            priority: try container.decode(Int64.self, forKey: .priority),
            failureCount: try container.decode(UInt.self, forKey: .failureCount),
            variant: try container.decode(Variant.self, forKey: .variant),
            behaviour: try container.decode(Behaviour.self, forKey: .behaviour),
            shouldBlock: try container.decode(Bool.self, forKey: .shouldBlock),
            shouldSkipLaunchBecomeActive: try container.decode(Bool.self, forKey: .shouldSkipLaunchBecomeActive),
            nextRunTimestamp: try container.decode(TimeInterval.self, forKey: .nextRunTimestamp),
            threadId: try container.decodeIfPresent(String.self, forKey: .threadId),
            interactionId: try container.decodeIfPresent(Int64.self, forKey: .interactionId),
            details: try container.decodeIfPresent(Data.self, forKey: .details),
            uniqueHashValue: try container.decodeIfPresent(Int.self, forKey: .uniqueHashValue),
            transientData: nil
        )
    }
    
    func encode(to encoder: Encoder) throws {
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)

        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(priority, forKey: .priority)
        try container.encode(failureCount, forKey: .failureCount)
        try container.encode(variant, forKey: .variant)
        try container.encode(behaviour, forKey: .behaviour)
        try container.encode(shouldBlock, forKey: .shouldBlock)
        try container.encode(shouldSkipLaunchBecomeActive, forKey: .shouldSkipLaunchBecomeActive)
        try container.encode(nextRunTimestamp, forKey: .nextRunTimestamp)
        try container.encodeIfPresent(threadId, forKey: .threadId)
        try container.encodeIfPresent(interactionId, forKey: .interactionId)
        try container.encodeIfPresent(details, forKey: .details)
        try container.encodeIfPresent(uniqueHashValue, forKey: .uniqueHashValue)
    }
}

// MARK: - Equatable

public extension Job {
    static func == (lhs: Job, rhs: Job) -> Bool {
        return (
            lhs.id == rhs.id &&
            lhs.priority == rhs.priority &&
            lhs.failureCount == rhs.failureCount &&
            lhs.variant == rhs.variant &&
            lhs.behaviour == rhs.behaviour &&
            lhs.shouldBlock == rhs.shouldBlock &&
            lhs.shouldSkipLaunchBecomeActive == rhs.shouldSkipLaunchBecomeActive &&
            lhs.nextRunTimestamp == rhs.nextRunTimestamp &&
            lhs.threadId == rhs.threadId &&
            lhs.interactionId == rhs.interactionId &&
            lhs.details == rhs.details &&
            lhs.uniqueHashValue == rhs.uniqueHashValue
            /// `transientData` ignored for equality check
        )
    }
}

// MARK: - Hashable

public extension Job {
    func hash(into hasher: inout Hasher) {
        id?.hash(into: &hasher)
        priority.hash(into: &hasher)
        failureCount.hash(into: &hasher)
        variant.hash(into: &hasher)
        behaviour.hash(into: &hasher)
        shouldBlock.hash(into: &hasher)
        shouldSkipLaunchBecomeActive.hash(into: &hasher)
        nextRunTimestamp.hash(into: &hasher)
        threadId?.hash(into: &hasher)
        interactionId?.hash(into: &hasher)
        details?.hash(into: &hasher)
        uniqueHashValue?.hash(into: &hasher)
        /// `transientData` ignored for hashing
    }
}

// MARK: - GRDB Interactions

extension Job {
    internal static func filterPendingJobs(
        variants: [Variant],
        excludeFutureJobs: Bool,
        includeJobsWithDependencies: Bool
    ) -> QueryInterfaceRequest<Job> {
        var query: QueryInterfaceRequest<Job> = Job
            .filter(
                // Retrieve all 'runOnce' and 'recurring' jobs
                [
                    Job.Behaviour.runOnce,
                    Job.Behaviour.recurring
                ].contains(Job.Columns.behaviour) || (
                    // Retrieve any 'recurringOnLaunch' and 'recurringOnActive' jobs that have a
                    // 'nextRunTimestamp'
                    [
                        Job.Behaviour.recurringOnLaunch,
                        Job.Behaviour.recurringOnActive
                    ].contains(Job.Columns.behaviour) &&
                    Job.Columns.nextRunTimestamp > 0
                )
            )
            .filter(variants.contains(Job.Columns.variant))
            .order(
                Job.Columns.nextRunTimestamp > Date().timeIntervalSince1970, // Past jobs first
                Job.Columns.priority.desc,
                Job.Columns.nextRunTimestamp,
                Job.Columns.id
            )
        
        if excludeFutureJobs {
            query = query.filter(Job.Columns.nextRunTimestamp <= Date().timeIntervalSince1970)
        }
        
        if !includeJobsWithDependencies {
            query = query.having(Job.jobsThisJobDependsOn.isEmpty)
        }
        
        return query
    }
}

// MARK: - Convenience

public extension Job {
    func with(
        failureCount: UInt = 0,
        nextRunTimestamp: TimeInterval
    ) -> Job {
        return Job(
            id: self.id,
            priority: self.priority,
            failureCount: failureCount,
            variant: self.variant,
            behaviour: self.behaviour,
            shouldBlock: self.shouldBlock,
            shouldBeUnique: (self.uniqueHashValue != nil),
            shouldSkipLaunchBecomeActive: self.shouldSkipLaunchBecomeActive,
            nextRunTimestamp: nextRunTimestamp,
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
            priority: self.priority,
            failureCount: self.failureCount,
            variant: self.variant,
            behaviour: self.behaviour,
            shouldBlock: self.shouldBlock,
            shouldBeUnique: (self.uniqueHashValue != nil),
            shouldSkipLaunchBecomeActive: self.shouldSkipLaunchBecomeActive,
            nextRunTimestamp: self.nextRunTimestamp,
            threadId: self.threadId,
            interactionId: self.interactionId,
            details: detailsData,
            transientData: self.transientData
        )
    }
}
