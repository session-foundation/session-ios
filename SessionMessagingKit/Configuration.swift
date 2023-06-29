import Foundation
import SessionUtilitiesKit

public enum SNMessagingKit { // Just to make the external API nice
    public static func migrations() -> TargetMigrations {
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
                    (Features.useSharedUtilForUserConfig() ?
                        _014_GenerateInitialUserConfigDumps.self :
                        (nil as Migration.Type?)
                    ),
                    _015_DisappearingMessagesConfiguration.self
                ].compactMap { $0 }
            ]
        )
    }
    
    public static func configure() {
        // Configure the job executors
        JobRunner.add(executor: DisappearingMessagesJob.self, for: .disappearingMessages)
        JobRunner.add(executor: FailedMessageSendsJob.self, for: .failedMessageSends)
        JobRunner.add(executor: FailedAttachmentDownloadsJob.self, for: .failedAttachmentDownloads)
        JobRunner.add(executor: UpdateProfilePictureJob.self, for: .updateProfilePicture)
        JobRunner.add(executor: RetrieveDefaultOpenGroupRoomsJob.self, for: .retrieveDefaultOpenGroupRooms)
        JobRunner.add(executor: GarbageCollectionJob.self, for: .garbageCollection)
        JobRunner.add(executor: MessageSendJob.self, for: .messageSend)
        JobRunner.add(executor: MessageReceiveJob.self, for: .messageReceive)
        JobRunner.add(executor: NotifyPushServerJob.self, for: .notifyPushServer)
        JobRunner.add(executor: SendReadReceiptsJob.self, for: .sendReadReceipts)
        JobRunner.add(executor: AttachmentUploadJob.self, for: .attachmentUpload)
        JobRunner.add(executor: GroupLeavingJob.self, for: .groupLeaving)
        JobRunner.add(executor: AttachmentDownloadJob.self, for: .attachmentDownload)
        JobRunner.add(executor: ConfigurationSyncJob.self, for: .configurationSync)
        JobRunner.add(executor: ConfigMessageReceiveJob.self, for: .configMessageReceive)
        JobRunner.add(executor: ExpirationUpdateJob.self, for: .expirationUpdate)
    }
}
