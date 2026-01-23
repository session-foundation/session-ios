// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation

// MARK: - Sorting Methods

public extension JobQueue {
    enum JobSorter {
        static func unsorted(
            _ jobs: [JobState],
            context: JobPriorityContext,
            retrievedData: Any?
        ) -> [JobState] { return jobs }
        
        static func sortById(
            _ jobs: [JobState],
            context: JobPriorityContext,
            retrievedData: Any?
        ) -> [JobState] {
            return jobs.sorted { lhs, rhs in
                lhs.queueId < rhs.queueId
            }
        }
        
        static func sortByFilePriority(
            _ jobs: [JobState],
            context: JobPriorityContext,
            retrievedData: Any?
        ) -> [JobState] {
            guard let data: FileSortData = retrievedData as? FileSortData else { return jobs }
            
            /// Perform the sort
            return jobs.sorted { lhs, rhs in
                switch (lhs.job.variant, rhs.job.variant) {
                    /// Don't reorder uploads
                    case (.attachmentUpload, .attachmentUpload): return false
                    case (.reuploadUserDisplayPicture, .reuploadUserDisplayPicture): return false
                    
                    /// File uploads are more important than display picture re-uploads
                    case (.attachmentUpload, .reuploadUserDisplayPicture): return true
                    case (.reuploadUserDisplayPicture, .attachmentUpload): return false
                        
                    /// Uploads are more important than downloads
                    case (.attachmentUpload, .attachmentDownload),
                        (.attachmentUpload, .displayPictureDownload),
                        (.reuploadUserDisplayPicture, .attachmentDownload),
                        (.reuploadUserDisplayPicture, .displayPictureDownload):
                        return true
                        
                    case (.attachmentDownload, .attachmentUpload),
                        (.attachmentDownload, .reuploadUserDisplayPicture),
                        (.displayPictureDownload, .attachmentUpload),
                        (.displayPictureDownload, .reuploadUserDisplayPicture):
                        return false
                    
                    case (.attachmentDownload, .attachmentDownload):
                        /// Downloads for the active conversation are higher priority
                        let lhsIsForActiveThread: Bool = (lhs.job.threadId == context.activeThreadId)
                        let rhsIsForActiveThread: Bool = (rhs.job.threadId == context.activeThreadId)
                        
                        switch (context.activeThreadId, lhsIsForActiveThread, rhsIsForActiveThread) {
                            case (.some, true, false): return true
                            case (.some, false, true): return false
                            default: break
                        }
                        
                        /// If neither are for the active thread then we should prioritise attachments for newer messages over
                        /// older ones (as generally they will be the most important for users, and are less likely to have expired)
                        guard
                            let lhsAttachmentId: String = data.jobIdToAttachmentId[lhs.queueId],
                            let lhsTimestampMs: Int64 = data.attachmentIdToTimestampMs[lhsAttachmentId],
                            let rhsAttachmentId: String = data.jobIdToAttachmentId[rhs.queueId],
                            let rhsTimestampMs: Int64 = data.attachmentIdToTimestampMs[rhsAttachmentId]
                        else { return false }
                        
                        return (lhsTimestampMs > rhsTimestampMs)
                        
                    case (.attachmentDownload, .displayPictureDownload):
                        return isHigherPriority(
                            attachmentDownloadJob: lhs,
                            displayPictureDownloadJob: rhs,
                            context: context,
                            fileSortData: data
                        )
                        
                    case (.displayPictureDownload, .attachmentDownload):
                        /// To reduce duplication we call the same function but pass `lhs` and `rhs` the other way around,
                        /// so we need to invert the result
                        let invertedResult: Bool = isHigherPriority(
                            attachmentDownloadJob: rhs,
                            displayPictureDownloadJob: lhs,
                            context: context,
                            fileSortData: data
                        )
                        
                        return !invertedResult
                    
                    case (.displayPictureDownload, .displayPictureDownload):
                        /// We should prioritise jobs which update the conversation list
                        let lhsUpdatesConvoList: Bool = data
                            .displayPictureJobIdsUpdatingConversationList
                            .contains(lhs.queueId)
                        let rhsUpdatesConvoList: Bool = data
                            .displayPictureJobIdsUpdatingConversationList
                            .contains(rhs.queueId)
                        
                        switch (lhsUpdatesConvoList, rhsUpdatesConvoList) {
                            case (true, false): return true
                            case (false, true): return false
                            default: break
                        }
                        
                        /// Display pics for the active thread have a higher priority
                        let lhsIsForActiveThread: Bool = (data.jobIdToThreadId[lhs.queueId] == context.activeThreadId)
                        let rhsIsForActiveThread: Bool = (data.jobIdToThreadId[rhs.queueId] == context.activeThreadId)
                        
                        switch (context.activeThreadId, lhsIsForActiveThread, rhsIsForActiveThread) {
                            case (.some, true, false): return true
                            case (.some, false, true): return false
                            default: break
                        }
                        
                        /// Otherwise we should prioritise display pics for more recent messages over older ones
                        guard
                            let lhsProfileId: String = data.jobIdToProfileId[lhs.queueId],
                            let lhsTimestampMs: Int64 = data.profileIdsToLastMessageTimestampMs[lhsProfileId],
                            let rhsProfileId: String = data.jobIdToProfileId[rhs.queueId],
                            let rhsTimestampMs: Int64 = data.profileIdsToLastMessageTimestampMs[rhsProfileId]
                        else { return false }
                        
                        return (lhsTimestampMs > rhsTimestampMs)
                        
                    default:
                        Log.critical(.jobRunner, "Tried to prioritise \(lhs.job.variant) against \(rhs.job.variant) via the `\(Self.self)` priority checker.")
                        return false
                }
            }
        }
        
        private static func isHigherPriority(
            attachmentDownloadJob lhs: JobState,
            displayPictureDownloadJob rhs: JobState,
            context: JobPriorityContext,
            fileSortData: FileSortData
        ) -> Bool {
            guard
                lhs.job.variant == .attachmentDownload,
                rhs.job.variant == .displayPictureDownload
            else {
                Log.critical(.jobRunner, "Tried to check priorty of incorrect job variants, expected 'lhs: \(Job.Variant.attachmentDownload), rhs: \(Job.Variant.displayPictureDownload)' got 'lhs: \(lhs.job.variant), rhs: \(rhs.job.variant)'.")
                return false
            }
            
            /// If the display picture appears on the home screen then we should prioritise it
            if fileSortData.displayPictureJobIdsUpdatingConversationList.contains(rhs.queueId) {
                return true
            }
            
            /// If we don't have an active thread then don't prioritise
            guard context.activeThreadId != nil else {
                return false
            }
            
            /// If the display picture belongs to a user in this thread then prioritise by timestamp
            guard
                let lhsAttachmentId: String = fileSortData.jobIdToAttachmentId[lhs.queueId],
                let lhsTimestampMs: Int64 = fileSortData.attachmentIdToTimestampMs[lhsAttachmentId],
                let rhsProfileId: String = fileSortData.jobIdToProfileId[rhs.queueId],
                let rhsTimestampMs: Int64 = fileSortData.profileIdsToLastMessageTimestampMs[rhsProfileId]
            else { return false }
            
            /// The attachment is a higher priority if it's in a newer, or the same, message
            return (lhsTimestampMs >= rhsTimestampMs)
        }
    }
}

// MARK: - DataRetriever

public protocol JobSorterDataRetriever {
    static func retrieveData(_ jobs: [JobState], using dependencies: Dependencies) async -> Any?
}

public extension JobQueue.JobSorter {
    enum EmptyRetriever: JobSorterDataRetriever {
        public static func retrieveData(_ jobs: [JobState], using dependencies: Dependencies) async -> Any? {
            return nil
        }
    }
    
    struct FileSortData {
        let jobIdToAttachmentId: [JobQueue.JobQueueId: String]
        let attachmentIdToTimestampMs: [String: Int64]
        let jobIdToProfileId: [JobQueue.JobQueueId: String]
        let profileIdsToLastMessageTimestampMs: [String: Int64]
        let profileIdsInConversationList: Set<String>
        let jobIdToThreadId: [JobQueue.JobQueueId: String]
        let displayPictureJobIdsUpdatingConversationList: Set<JobQueue.JobQueueId>
        
        public init(
            jobIdToAttachmentId: [JobQueue.JobQueueId: String],
            attachmentIdToTimestampMs: [String: Int64],
            jobIdToProfileId: [JobQueue.JobQueueId: String],
            profileIdsToLastMessageTimestampMs: [String: Int64],
            profileIdsInConversationList: Set<String>,
            jobIdToThreadId: [JobQueue.JobQueueId: String],
            displayPictureJobIdsUpdatingConversationList: Set<JobQueue.JobQueueId>
        ) {
            self.jobIdToAttachmentId = jobIdToAttachmentId
            self.attachmentIdToTimestampMs = attachmentIdToTimestampMs
            self.jobIdToProfileId = jobIdToProfileId
            self.profileIdsToLastMessageTimestampMs = profileIdsToLastMessageTimestampMs
            self.profileIdsInConversationList = profileIdsInConversationList
            self.jobIdToThreadId = jobIdToThreadId
            self.displayPictureJobIdsUpdatingConversationList = displayPictureJobIdsUpdatingConversationList
        }
    }
}
