import Foundation
import GRDB
import SessionUtilitiesKit

public enum SNMessagingKit { // Just to make the external API nice
    public static let migrations: [Migration.Type] = [
        _001_SUK_InitialSetupMigration.self,
        _002_SUK_SetupStandardJobs.self,
        _003_SUK_YDBToGRDBMigration.self,
        _004_SNK_InitialSetupMigration.self,
        _005_SNK_SetupStandardJobs.self,
        _006_SMK_InitialSetupMigration.self,
        _007_SMK_SetupStandardJobs.self,
        _008_SNK_YDBToGRDBMigration.self,
        _009_SMK_YDBToGRDBMigration.self,
        _010_FlagMessageHashAsDeletedOrInvalid.self,
        _011_RemoveLegacyYDB.self,
        _012_AddJobPriority.self,
        _013_FixDeletedMessageReadState.self,
        _014_FixHiddenModAdminSupport.self,
        _015_HomeQueryOptimisationIndexes.self,
        _016_ThemePreferences.self,
        _017_EmojiReacts.self,
        _018_OpenGroupPermission.self,
        _019_AddThreadIdToFTS.self,
        _020_AddJobUniqueHash.self,
        _021_AddSnodeReveivedMessageInfoPrimaryKey.self,
        _022_DropSnodeCache.self,
        _023_SplitSnodeReceivedMessageInfo.self,
        _024_ResetUserConfigLastHashes.self,
        _025_AddPendingReadReceipts.self,
        _026_AddFTSIfNeeded.self,
        _027_SessionUtilChanges.self,
        _028_GenerateInitialUserConfigDumps.self,
        _029_BlockCommunityMessageRequests.self,
        _030_MakeBrokenProfileTimestampsNullable.self,
        _031_RebuildFTSIfNeeded_2_4_5.self,
        _032_DisappearingMessagesConfiguration.self,
        _033_ScheduleAppUpdateCheckJob.self,
        _034_AddMissingWhisperFlag.self,
        _035_ReworkRecipientState.self,
        _036_GroupsRebuildChanges.self,
        _037_GroupsExpiredFlag.self,
        _038_FixBustedInteractionVariant.self,
        _039_DropLegacyClosedGroupKeyPairTable.self,
        _040_MessageDeduplicationTable.self,
        _041_RenameTableSettingToKeyValueStore.self,
        _042_MoveSettingsToLibSession.self,
        _043_RenameAttachments.self,
        _044_AddProMessageFlag.self
    ]
    
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
            .sendReadReceipts: SendReadReceiptsJob.self,
            .attachmentUpload: AttachmentUploadJob.self,
            .groupLeaving: GroupLeavingJob.self,
            .attachmentDownload: AttachmentDownloadJob.self,
            .configurationSync: ConfigurationSyncJob.self,
            .configMessageReceive: ConfigMessageReceiveJob.self,
            .expirationUpdate: ExpirationUpdateJob.self,
            .checkForAppUpdates: CheckForAppUpdatesJob.self,
            .displayPictureDownload: DisplayPictureDownloadJob.self,
            .getExpiration: GetExpirationJob.self,
            .groupInviteMember: GroupInviteMemberJob.self,
            .groupPromoteMember: GroupPromoteMemberJob.self,
            .processPendingGroupMemberRemovals: ProcessPendingGroupMemberRemovalsJob.self,
            .failedGroupInvitesAndPromotions: FailedGroupInvitesAndPromotionsJob.self
        ]
        
        executors.forEach { variant, executor in
            dependencies[singleton: .jobRunner].setExecutor(executor, for: variant)
        }
        
        // Register any recurring jobs to ensure they are actually scheduled
        dependencies[singleton: .jobRunner].registerRecurringJobs(
            scheduleInfo: [
                (.disappearingMessages, .recurringOnLaunch, true, false),
                (.failedMessageSends, .recurringOnLaunch, true, false),
                (.failedAttachmentDownloads, .recurringOnLaunch, true, false),
                (.updateProfilePicture, .recurringOnActive, false, false),
                (.retrieveDefaultOpenGroupRooms, .recurringOnActive, false, false),
                (.garbageCollection, .recurringOnActive, false, false),
                (.failedGroupInvitesAndPromotions, .recurringOnLaunch, true, false),
                (.checkForAppUpdates, .recurring, false, false)
            ]
        )
    }
}
