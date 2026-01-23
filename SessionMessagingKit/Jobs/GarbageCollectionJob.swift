// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUtilitiesKit
import SessionNetworkingKit

// MARK: - Log.Category

private extension Log.Category {
    static let cat: Log.Category = .create("GarbageCollectionJob", defaultLevel: .info)
}

// MARK: - GarbageCollectionJob

/// This job deletes unused and orphaned data from the database as well as orphaned files from device storage
///
/// **Note:** When sheduling this job if no `Details` are provided (with a list of `typesToCollect`) then this job will
/// assume that it should be collecting all `Types`
public enum GarbageCollectionJob: JobExecutor {
    public static var maxFailureCount: Int = -1
    public static var requiresThreadId: Bool = false
    public static let requiresInteractionId: Bool = false
    public static let approxSixMonthsInSeconds: TimeInterval = (6 * 30 * 24 * 60 * 60)
    public static let fourteenDaysInSeconds: TimeInterval = (14 * 24 * 60 * 60)
    private static let minInteractionsToTrim: Int = 2000
    
    private struct FileInfo {
        let attachmentDownloadUrls: Set<String>
        let displayPictureFilePaths: Set<String>
        let messageDedupeRecords: [MessageDeduplication]
    }
    
    public static func canStart(
        jobState: JobState,
        alongside runningJobs: [JobState],
        using dependencies: Dependencies
    ) -> Bool {
        return true
    }
    
    public static func run(_ job: Job, using dependencies: Dependencies) async throws -> JobExecutionResult {
        let details: Details = {
            guard
                let detailsData: Data = job.details,
                let details: Details = try? JSONDecoder(using: dependencies)
                    .decode(Details.self, from: detailsData)
            else { return Details(typesToCollect: Types.allCases, manuallyTriggered: false) }
            
            return details
        }()
        
        /// Only do a full collection if the job isn't the recurring one or it's been 23 hours since it last ran (23 hours so a user who opens the
        /// app at about the same time every day will trigger the garbage collection) - since this runs when the app becomes active we
        /// want to prevent it running to frequently (the app becomes active if a system alert, the notification center or the control panel
        /// are shown)
        let lastGarbageCollection: Date = dependencies[defaults: .standard, key: .lastGarbageCollection]
            .defaulting(to: Date.distantPast)
        
        guard
            details.manuallyTriggered ||
            dependencies.dateNow.timeIntervalSince(lastGarbageCollection) > (23 * 60 * 60)
        else {
            Log.info(.cat, "Ignored due to frequency")
            return .success
        }
        
        let timestampNow: TimeInterval = dependencies.dateNow.timeIntervalSince1970
        let fileInfo: FileInfo = try await dependencies[singleton: .storage].writeAsync { db in
            let userSessionId: SessionId = dependencies[cache: .general].sessionId
            
            /// Remove any old open group messages - open group messages which are older than six months
            if details.typesToCollect.contains(.oldOpenGroupMessages) && dependencies.mutate(cache: .libSession, { $0.get(.trimOpenGroupMessagesOlderThanSixMonths) }) {
                let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
                let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
                let threadIdLiteral: SQL = SQL(stringLiteral: Interaction.Columns.threadId.name)
                let minInteractionsToTrimSql: SQL = SQL("\(GarbageCollectionJob.minInteractionsToTrim)")
                
                try db.execute(literal: """
                    DELETE FROM \(Interaction.self)
                    WHERE \(Column.rowID) IN (
                        SELECT \(interaction[.rowId])
                        FROM \(Interaction.self)
                        JOIN \(SessionThread.self) ON (
                            \(SQL("\(thread[.variant]) = \(SessionThread.Variant.community)")) AND
                            \(thread[.id]) = \(interaction[.threadId])
                        )
                        JOIN (
                            SELECT
                                COUNT(\(interaction[.rowId])) AS interactionCount,
                                \(interaction[.threadId])
                            FROM \(Interaction.self)
                            GROUP BY \(interaction[.threadId])
                        ) AS interactionInfo ON interactionInfo.\(threadIdLiteral) = \(interaction[.threadId])
                        WHERE (
                            \(interaction[.timestampMs]) < \((timestampNow - approxSixMonthsInSeconds) * 1000) AND
                            interactionInfo.interactionCount >= \(minInteractionsToTrimSql)
                        )
                    )
                """)
                try Task.checkCancellation()
            }
            
            /// Orphaned jobs - jobs which have had their threads or interactions removed
            if details.typesToCollect.contains(.orphanedJobs) {
                let job: TypedTableAlias<Job> = TypedTableAlias()
                let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
                let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
                
                try db.execute(literal: """
                    DELETE FROM \(Job.self)
                    WHERE \(Column.rowID) IN (
                        SELECT \(job[.rowId])
                        FROM \(Job.self)
                        LEFT JOIN \(SessionThread.self) ON \(thread[.id]) = \(job[.threadId])
                        LEFT JOIN \(Interaction.self) ON \(interaction[.id]) = \(job[.interactionId])
                        WHERE (
                            -- Never delete config sync jobs, even if their threads were deleted
                            \(SQL("\(job[.variant]) != \(Job.Variant.configurationSync)")) AND
                            (
                                \(job[.threadId]) IS NOT NULL AND
                                \(thread[.id]) IS NULL
                            ) OR (
                                \(job[.interactionId]) IS NOT NULL AND
                                \(interaction[.id]) IS NULL
                            )
                        )
                    )
                """)
                try Task.checkCancellation()
            }
            
            /// Orphaned link previews - link previews which have no interactions with matching url & rounded timestamps
            if details.typesToCollect.contains(.orphanedLinkPreviews) {
                let linkPreview: TypedTableAlias<LinkPreview> = TypedTableAlias()
                let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
                
                try db.execute(literal: """
                    DELETE FROM \(LinkPreview.self)
                    WHERE \(Column.rowID) IN (
                        SELECT \(linkPreview[.rowId])
                        FROM \(LinkPreview.self)
                        LEFT JOIN \(Interaction.self) ON (
                            \(interaction[.linkPreviewUrl]) = \(linkPreview[.url]) AND
                            \(Interaction.linkPreviewFilterLiteral())
                        )
                        WHERE \(interaction[.id]) IS NULL
                    )
                """)
                try Task.checkCancellation()
            }
            
            /// Orphaned open groups - open groups which are no longer associated to a thread (except for the session-run ones for which
            /// we want cached image data even if the user isn't in the group)
            if details.typesToCollect.contains(.orphanedOpenGroups) {
                let openGroup: TypedTableAlias<OpenGroup> = TypedTableAlias()
                let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
                
                try db.execute(literal: """
                    DELETE FROM \(OpenGroup.self)
                    WHERE \(Column.rowID) IN (
                        SELECT \(openGroup[.rowId])
                        FROM \(OpenGroup.self)
                        LEFT JOIN \(SessionThread.self) ON \(thread[.id]) = \(openGroup[.threadId])
                        WHERE (
                            \(thread[.id]) IS NULL AND
                            \(SQL("\(openGroup[.server]) != \(Network.SOGS.defaultServer.lowercased())"))
                        )
                    )
                """)
                try Task.checkCancellation()
            }
            
            /// Orphaned open group capabilities - capabilities which have no existing open groups with the same server
            if details.typesToCollect.contains(.orphanedOpenGroupCapabilities) {
                let capability: TypedTableAlias<Capability> = TypedTableAlias()
                let openGroup: TypedTableAlias<OpenGroup> = TypedTableAlias()
                
                try db.execute(literal: """
                    DELETE FROM \(Capability.self)
                    WHERE \(Column.rowID) IN (
                        SELECT \(capability[.rowId])
                        FROM \(Capability.self)
                        LEFT JOIN \(OpenGroup.self) ON \(openGroup[.server]) = \(capability[.openGroupServer])
                        WHERE \(openGroup[.threadId]) IS NULL
                    )
                """)
                try Task.checkCancellation()
            }
            
            /// Orphaned blinded id lookups - lookups which have no existing threads or approval/block settings for either blinded/un-blinded id
            if details.typesToCollect.contains(.orphanedBlindedIdLookups) {
                let blindedIdLookup: TypedTableAlias<BlindedIdLookup> = TypedTableAlias()
                let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
                let contact: TypedTableAlias<Contact> = TypedTableAlias()
                
                try db.execute(literal: """
                    DELETE FROM \(BlindedIdLookup.self)
                    WHERE \(Column.rowID) IN (
                        SELECT \(blindedIdLookup[.rowId])
                        FROM \(BlindedIdLookup.self)
                        LEFT JOIN \(SessionThread.self) ON (
                            \(thread[.id]) = \(blindedIdLookup[.blindedId]) OR
                            \(thread[.id]) = \(blindedIdLookup[.sessionId])
                        )
                        LEFT JOIN \(Contact.self) ON (
                            \(contact[.id]) = \(blindedIdLookup[.blindedId]) OR
                            \(contact[.id]) = \(blindedIdLookup[.sessionId])
                        )
                        WHERE (
                            \(thread[.id]) IS NULL AND
                            \(contact[.id]) IS NULL
                        )
                    )
                """)
                try Task.checkCancellation()
            }
            
            /// Approved blinded contact records - once a blinded contact has been approved there is no need to keep the blinded
            /// contact record around anymore
            if details.typesToCollect.contains(.approvedBlindedContactRecords) {
                let contact: TypedTableAlias<Contact> = TypedTableAlias()
                let blindedIdLookup: TypedTableAlias<BlindedIdLookup> = TypedTableAlias()
                
                try db.execute(literal: """
                    DELETE FROM \(Contact.self)
                    WHERE \(Column.rowID) IN (
                        SELECT \(contact[.rowId])
                        FROM \(Contact.self)
                        LEFT JOIN \(BlindedIdLookup.self) ON (
                            \(blindedIdLookup[.blindedId]) = \(contact[.id]) AND
                            \(blindedIdLookup[.sessionId]) IS NOT NULL
                        )
                        WHERE \(blindedIdLookup[.sessionId]) IS NOT NULL
                    )
                """)
                try Task.checkCancellation()
            }
            
            /// Orphaned attachments - attachments which have no related interactions, quotes or link previews
            if details.typesToCollect.contains(.orphanedAttachments) {
                let attachment: TypedTableAlias<Attachment> = TypedTableAlias()
                let linkPreview: TypedTableAlias<LinkPreview> = TypedTableAlias()
                let interactionAttachment: TypedTableAlias<InteractionAttachment> = TypedTableAlias()
                
                try db.execute(literal: """
                    DELETE FROM \(Attachment.self)
                    WHERE \(Column.rowID) IN (
                        SELECT \(attachment[.rowId])
                        FROM \(Attachment.self)
                        LEFT JOIN \(LinkPreview.self) ON \(linkPreview[.attachmentId]) = \(attachment[.id])
                        LEFT JOIN \(InteractionAttachment.self) ON \(interactionAttachment[.attachmentId]) = \(attachment[.id])
                        WHERE (
                            \(linkPreview[.url]) IS NULL AND
                            \(interactionAttachment[.attachmentId]) IS NULL
                        )
                    )
                """)
                try Task.checkCancellation()
            }
            
            if details.typesToCollect.contains(.orphanedProfiles) {
                let profile: TypedTableAlias<Profile> = TypedTableAlias()
                let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
                let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
                let quote: TypedTableAlias<Quote> = TypedTableAlias()
                let groupMember: TypedTableAlias<GroupMember> = TypedTableAlias()
                let contact: TypedTableAlias<Contact> = TypedTableAlias()
                let blindedIdLookup: TypedTableAlias<BlindedIdLookup> = TypedTableAlias()
                
                try db.execute(literal: """
                    DELETE FROM \(Profile.self)
                    WHERE \(Column.rowID) IN (
                        SELECT \(profile[.rowId])
                        FROM \(Profile.self)
                        LEFT JOIN \(SessionThread.self) ON \(thread[.id]) = \(profile[.id])
                        LEFT JOIN \(Interaction.self) ON \(interaction[.authorId]) = \(profile[.id])
                        LEFT JOIN \(Quote.self) ON \(quote[.authorId]) = \(profile[.id])
                        LEFT JOIN \(GroupMember.self) ON \(groupMember[.profileId]) = \(profile[.id])
                        LEFT JOIN \(Contact.self) ON \(contact[.id]) = \(profile[.id])
                        LEFT JOIN \(BlindedIdLookup.self) ON (
                            blindedIdLookup.blindedId = \(profile[.id]) OR
                            blindedIdLookup.sessionId = \(profile[.id])
                        )
                        WHERE (
                            \(thread[.id]) IS NULL AND
                            \(interaction[.authorId]) IS NULL AND
                            \(quote[.authorId]) IS NULL AND
                            \(groupMember[.profileId]) IS NULL AND
                            \(contact[.id]) IS NULL AND
                            \(blindedIdLookup[.blindedId]) IS NULL
                        )
                    )
                """)
                try Task.checkCancellation()
            }
            
            /// Remove interactions which should be disappearing after read but never be read within 14 days
            if details.typesToCollect.contains(.expiredUnreadDisappearingMessages) {
                try Interaction.deleteWhere(
                    db,
                    .filter(Interaction.Columns.expiresInSeconds != 0),
                    .filter(Interaction.Columns.expiresStartedAtMs == nil),
                    .filter(Interaction.Columns.timestampMs < (timestampNow - fourteenDaysInSeconds) * 1000)
                )
                try Task.checkCancellation()
            }
            
            if details.typesToCollect.contains(.expiredPendingReadReceipts) {
                _ = try PendingReadReceipt
                    .filter(PendingReadReceipt.Columns.serverExpirationTimestamp <= timestampNow)
                    .deleteAll(db)
                try Task.checkCancellation()
            }
            
            if details.typesToCollect.contains(.shadowThreads) {
                // Shadow threads are thread records which were created to start a conversation that
                // didn't actually get turned into conversations (ie. the app was closed or crashed
                // before the user sent a message)
                let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
                let contact: TypedTableAlias<Contact> = TypedTableAlias()
                let openGroup: TypedTableAlias<OpenGroup> = TypedTableAlias()
                let closedGroup: TypedTableAlias<ClosedGroup> = TypedTableAlias()
                
                try db.execute(literal: """
                    DELETE FROM \(SessionThread.self)
                    WHERE \(Column.rowID) IN (
                        SELECT \(thread[.rowId])
                        FROM \(SessionThread.self)
                        LEFT JOIN \(Contact.self) ON \(contact[.id]) = \(thread[.id])
                        LEFT JOIN \(OpenGroup.self) ON \(openGroup[.threadId]) = \(thread[.id])
                        LEFT JOIN \(ClosedGroup.self) ON \(closedGroup[.threadId]) = \(thread[.id])
                        WHERE (
                            \(contact[.id]) IS NULL AND
                            \(openGroup[.threadId]) IS NULL AND
                            \(closedGroup[.threadId]) IS NULL AND
                            \(thread[.shouldBeVisible]) = false AND
                            \(SQL("\(thread[.id]) != \(userSessionId.hexString)"))
                        )
                    )
                """)
                try Task.checkCancellation()
            }
            
            if details.typesToCollect.contains(.pruneExpiredLastHashRecords) {
                // Delete any expired SnodeReceivedMessageInfo values associated to a specific node
                try SnodeReceivedMessageInfo
                    .select(Column.rowID)
                    .filter(SnodeReceivedMessageInfo.Columns.expirationDateMs <= (timestampNow * 1000))
                    .deleteAll(db)
                try Task.checkCancellation()
            }
            
            /// Retrieve any files which need to be deleted
            var attachmentDownloadUrls: Set<String> = []
            var displayPictureFilePaths: Set<String> = []
            var messageDedupeRecords: [MessageDeduplication] = []
            
            /// Orphaned attachment files - attachment files which don't have an associated record in the database
            if details.typesToCollect.contains(.orphanedAttachmentFiles) {
                /// **Note:** Thumbnails are stored in the `NSCachesDirectory` directory which should be automatically manage
                /// it's own garbage collection so we can just ignore it according to the various comments in the following stack overflow
                /// post, the directory will be cleared during app updates as well as if the system is running low on memory (if the app isn't running)
                /// https://stackoverflow.com/questions/6879860/when-are-files-from-nscachesdirectory-removed
                attachmentDownloadUrls = try Attachment
                    .select(.downloadUrl)
                    .filter(Attachment.Columns.downloadUrl != nil)
                    .asRequest(of: String.self)
                    .fetchSet(db)
                try Task.checkCancellation()
            }
            
            /// Orphaned display picture files - profile avatar files which don't have an associated record in the database
            if details.typesToCollect.contains(.orphanedDisplayPictures) {
                displayPictureFilePaths.insert(
                    contentsOf: Set(try Profile
                        .select(.displayPictureUrl)
                        .filter(Profile.Columns.displayPictureUrl != nil)
                        .asRequest(of: String.self)
                        .fetchSet(db)
                        .compactMap { try? dependencies[singleton: .displayPictureManager].path(for: $0) })
                )
                try Task.checkCancellation()
                
                displayPictureFilePaths.insert(
                    contentsOf: Set(try ClosedGroup
                        .select(.displayPictureUrl)
                        .filter(ClosedGroup.Columns.displayPictureUrl != nil)
                        .asRequest(of: String.self)
                        .fetchSet(db)
                        .compactMap { try? dependencies[singleton: .displayPictureManager].path(for: $0) })
                )
                try Task.checkCancellation()
                
                displayPictureFilePaths.insert(
                    contentsOf: Set(try OpenGroup
                        .select(.displayPictureOriginalUrl)
                        .filter(OpenGroup.Columns.displayPictureOriginalUrl != nil)
                        .asRequest(of: String.self)
                        .fetchSet(db)
                        .compactMap { try? dependencies[singleton: .displayPictureManager].path(for: $0) })
                )
                try Task.checkCancellation()
            }
            
            if details.typesToCollect.contains(.pruneExpiredDeduplicationRecords) {
                messageDedupeRecords = try MessageDeduplication
                    .filter(
                        MessageDeduplication.Columns.expirationTimestampSeconds != nil &&
                        MessageDeduplication.Columns.expirationTimestampSeconds < timestampNow
                    )
                    .fetchAll(db)
                try Task.checkCancellation()
            }
            
            return FileInfo(
                attachmentDownloadUrls: attachmentDownloadUrls,
                displayPictureFilePaths: displayPictureFilePaths,
                messageDedupeRecords: messageDedupeRecords
            )
        }
        
        var deletionErrors: [Error] = []
        
        /// Orphaned attachment files (actual deletion)
        if details.typesToCollect.contains(.orphanedAttachmentFiles) {
            let attachmentDirPath: String = dependencies[singleton: .attachmentManager]
                .sharedDataAttachmentsDirPath()
            let allAttachmentFilePaths: Set<String> = (Set((try? dependencies[singleton: .fileManager]
                .contentsOfDirectory(atPath: attachmentDirPath))?
                .map { filename in
                    URL(fileURLWithPath: attachmentDirPath)
                        .appendingPathComponent(filename)
                        .path
                } ?? []))
            let databaseAttachmentFilePaths: Set<String> = Set(fileInfo.attachmentDownloadUrls
                .compactMap { try? dependencies[singleton: .attachmentManager].path(for: $0) })
            let orphanedAttachmentFiles: Set<String> = allAttachmentFilePaths
                .subtracting(databaseAttachmentFilePaths)
            
            orphanedAttachmentFiles.forEach { filepath in
                /// We don't want a single deletion failure to block deletion of the other files so try each one and store
                /// the error to be used to determine success/failure of the job
                do { try dependencies[singleton: .fileManager].removeItem(atPath: filepath) }
                catch CocoaError.fileNoSuchFile {}  /// No need to do anything if the file doesn't eixst
                catch { deletionErrors.append(error) }
            }
            try Task.checkCancellation()
            
            Log.info(.cat, "Orphaned attachments removed: \(orphanedAttachmentFiles.count)")
        }
        
        /// Orphaned display picture files (actual deletion)
        if details.typesToCollect.contains(.orphanedDisplayPictures) {
            let allDisplayPictureFilePaths: Set<String> = (try? dependencies[singleton: .fileManager]
                .contentsOfDirectory(atPath: dependencies[singleton: .displayPictureManager].sharedDataDisplayPictureDirPath()))
                .defaulting(to: [])
                .map { filename in
                    URL(fileURLWithPath: dependencies[singleton: .displayPictureManager].sharedDataDisplayPictureDirPath())
                        .appendingPathComponent(filename)
                        .path
                }
                .asSet()
            let orphanedFilePaths: Set<String> = allDisplayPictureFilePaths
                .subtracting(fileInfo.displayPictureFilePaths)
            
            orphanedFilePaths.forEach { path in
                /// We don't want a single deletion failure to block deletion of the other files so try each one and store
                /// the error to be used to determine success/failure of the job
                do { try dependencies[singleton: .fileManager].removeItem(atPath: path) }
                catch CocoaError.fileNoSuchFile {}  /// No need to do anything if the file doesn't eixst
                catch { deletionErrors.append(error) }
            }
            try Task.checkCancellation()
            
            Log.info(.cat, "Orphaned display pictures removed: \(orphanedFilePaths.count)")
        }
        
        /// Explicit deduplication records that we want to delete
        if details.typesToCollect.contains(.pruneExpiredDeduplicationRecords) {
            fileInfo.messageDedupeRecords.forEach { record in
                /// We don't want a single deletion failure to block deletion of the other files so try each one and store
                /// the error to be used to determine success/failure of the job
                do {
                    try dependencies[singleton: .extensionHelper].removeDedupeRecord(
                        threadId: record.threadId,
                        uniqueIdentifier: record.uniqueIdentifier
                    )
                }
                catch CocoaError.fileNoSuchFile {}  /// No need to do anything if the file doesn't eixst
                catch { deletionErrors.append(error) }
            }
            try Task.checkCancellation()
            
            Log.info(.cat, "Dedupe records removed: \(fileInfo.messageDedupeRecords.count)")
        }
        
        /// Report a single file deletion as a job failure (even if other content was successfully removed)
        guard deletionErrors.isEmpty else {
            throw (deletionErrors.first ?? StorageError.generic)
        }
        
        /// Define a `successClosure` to avoid duplication
        let successClosure: () -> Void = {
            
        }
        
        /// Since the explicit file deletion was successful we can now _actually_ delete the `MessageDeduplication`
        /// entries from the database (we don't do this until after the files have been removed to ensure we don't orphan
        /// files by doing so)
        if !fileInfo.messageDedupeRecords.isEmpty {
            try await dependencies[singleton: .storage].writeAsync { db in
                try fileInfo.messageDedupeRecords.forEach { try $0.delete(db) }
            }
            try Task.checkCancellation()
        }
        
        /// If we did a full collection then update the `lastGarbageCollection` date to prevent a full collection
        /// from running again in the next 23 hours
        if !details.manuallyTriggered {
            dependencies[defaults: .standard, key: .lastGarbageCollection] = dependencies.dateNow
        }
        
        return .success
    }
}

// MARK: - GarbageCollectionJob.Details

extension GarbageCollectionJob {
    public enum Types: Codable, CaseIterable {
        case oldOpenGroupMessages
        case orphanedJobs
        case orphanedLinkPreviews
        case orphanedOpenGroups
        case orphanedOpenGroupCapabilities
        case orphanedBlindedIdLookups
        case approvedBlindedContactRecords
        case orphanedProfiles
        case orphanedAttachments
        case orphanedAttachmentFiles
        case orphanedDisplayPictures
        case expiredUnreadDisappearingMessages // unread disappearing messages after 14 days
        case expiredPendingReadReceipts
        case shadowThreads
        case pruneExpiredLastHashRecords
        case pruneExpiredDeduplicationRecords
    }
    
    public struct Details: Codable {
        public let typesToCollect: [Types]
        public let manuallyTriggered: Bool
        
        public init(
            typesToCollect: [Types],
            manuallyTriggered: Bool
        ) {
            self.typesToCollect = typesToCollect
            self.manuallyTriggered = manuallyTriggered
        }
    }
}
