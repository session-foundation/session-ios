import Foundation
import GRDB
import SessionUtilitiesKit

public enum SNMessagingKit: MigratableTarget { // Just to make the external API nice
    public static func migrations(_ db: Database) -> TargetMigrations {
        return TargetMigrations(
            identifier: .messagingKit,
            migrations: [
                [
                    _001_InitialSetupMigration.self,
                    _002_SetupStandardJobs.self
                ],
                [
                    _003_YDBToGRDBMigration.self
                ],
                [
                    _004_RemoveLegacyYDB.self
                ],
                [
                    _005_FixDeletedMessageReadState.self,
                    _006_FixHiddenModAdminSupport.self,
                    _007_HomeQueryOptimisationIndexes.self
                ],
                [
                    _008_EmojiReacts.self,
                    _009_OpenGroupPermission.self,
                    _010_AddThreadIdToFTS.self
                ],  // Add job priorities
                [
                    _011_AddPendingReadReceipts.self,
                    _012_AddFTSIfNeeded.self,
                    _013_SessionUtilChanges.self,
                    _014_GenerateInitialUserConfigDumps.self,
                    _015_BlockCommunityMessageRequests.self,
                    _016_DisappearingMessagesConfiguration.self,
                    _017_GroupsRebuildChanges.self
                ]
            ]
        )
    }
    
    public static func configure(using dependencies: Dependencies) {
        // Configure the job executors
        let executors: [Job.Variant: JobExecutor.Type] = [
            .disappearingMessages: DisappearingMessagesJob.self,
            .failedMessageSends: FailedMessageSendsJob.self,
            .failedAttachmentDownloads: FailedAttachmentDownloadsJob.self,
            .updateProfilePicture: UpdateProfilePictureJob.self,
            .retrieveDefaultOpenGroupRooms: RetrieveDefaultOpenGroupRoomsJob.self,
            .garbageCollection: GarbageCollectionJob.self,
            .messageSend: MessageSendJob.self,
            .messageReceive: MessageReceiveJob.self,
            .notifyPushServer: NotifyPushServerJob.self,
            .sendReadReceipts: SendReadReceiptsJob.self,
            .attachmentUpload: AttachmentUploadJob.self,
            .groupLeaving: GroupLeavingJob.self,
            .attachmentDownload: AttachmentDownloadJob.self,
            .configurationSync: ConfigurationSyncJob.self,
            .configMessageReceive: ConfigMessageReceiveJob.self,
            .expirationUpdate: ExpirationUpdateJob.self,
            .getExpiration: GetExpirationJob.self
        ]
        
        executors.forEach { variant, executor in
            dependencies[singleton: .jobRunner].setExecutor(executor, for: variant)
        }
    }
}
