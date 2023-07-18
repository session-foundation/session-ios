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
                    // Wait until the feature is turned on before doing the migration that generates
                    // the config dump data
                    // FIXME: Remove this once `useSharedUtilForUserConfig` is permanent
                    (Features.useSharedUtilForUserConfig(db) ?
                        _014_GenerateInitialUserConfigDumps.self :
                        (nil as Migration.Type?)
                    )
                ].compactMap { $0 }
            ]
        )
    }
    
    public static func configure() {
        // Configure the job executors
        JobRunner.setExecutor(DisappearingMessagesJob.self, for: .disappearingMessages)
        JobRunner.setExecutor(FailedMessageSendsJob.self, for: .failedMessageSends)
        JobRunner.setExecutor(FailedAttachmentDownloadsJob.self, for: .failedAttachmentDownloads)
        JobRunner.setExecutor(UpdateProfilePictureJob.self, for: .updateProfilePicture)
        JobRunner.setExecutor(RetrieveDefaultOpenGroupRoomsJob.self, for: .retrieveDefaultOpenGroupRooms)
        JobRunner.setExecutor(GarbageCollectionJob.self, for: .garbageCollection)
        JobRunner.setExecutor(MessageSendJob.self, for: .messageSend)
        JobRunner.setExecutor(MessageReceiveJob.self, for: .messageReceive)
        JobRunner.setExecutor(NotifyPushServerJob.self, for: .notifyPushServer)
        JobRunner.setExecutor(SendReadReceiptsJob.self, for: .sendReadReceipts)
        JobRunner.setExecutor(AttachmentUploadJob.self, for: .attachmentUpload)
        JobRunner.setExecutor(GroupLeavingJob.self, for: .groupLeaving)
        JobRunner.setExecutor(AttachmentDownloadJob.self, for: .attachmentDownload)
        JobRunner.setExecutor(ConfigurationSyncJob.self, for: .configurationSync)
        JobRunner.setExecutor(ConfigMessageReceiveJob.self, for: .configMessageReceive)
    }
}
