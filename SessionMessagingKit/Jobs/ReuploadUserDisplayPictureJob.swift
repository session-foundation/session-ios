// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUtilitiesKit
import SessionNetworkingKit

// MARK: - Log.Category

private extension Log.Category {
    static let cat: Log.Category = .create("ReuploadUserDisplayPictureJob", defaultLevel: .info)
}

// MARK: - ReuploadUserDisplayPictureJob

public enum ReuploadUserDisplayPictureJob: JobExecutor {
    public static let maxFailureCount: Int = -1
    public static let requiresThreadId: Bool = false
    public static let requiresInteractionId: Bool = false
    private static let maxExtendTTLFrequency: TimeInterval = (60 * 60 * 2)
    private static let maxDisplayPictureTTL: TimeInterval = (60 * 60 * 24 * 14)
    private static let maxReuploadFrequency: TimeInterval = (maxDisplayPictureTTL - (60 * 60 * 24 * 2))
    
    public static func canStart(
        jobState: JobState,
        alongside runningJobs: [JobState],
        using dependencies: Dependencies
    ) -> Bool {
        /// Don't want to run more than 1 at a time as it would be inefficient
        return false
    }
    
    public static func run(_ job: Job, using dependencies: Dependencies) async throws -> JobExecutionResult {
        /// Don't run when inactive or not in main app
        guard dependencies[defaults: .appGroup, key: .isMainAppActive] else {
            return .success
        }
        
        /// Wait for a successful poll
        _ = try await dependencies[singleton: .currentUserPoller]
            .successfulPollCount
            .first(where: { $0 > 0 }) ?? {
                Log.info(.cat, "Never received an initial poll response")
                throw JobRunnerError.missingRequiredDetails
            }()
        try Task.checkCancellation()
        
        /// Retrieve the users profile data
        let profile: Profile = dependencies.mutate(cache: .libSession) { $0.profile }
        try Task.checkCancellation()
        
        /// If we don't have a display pic then no need to do anything
        guard
            let displayPictureUrl: URL = profile.displayPictureUrl.map({ URL(string: $0) }),
            let displayPictureEncryptionKey: Data = profile.displayPictureEncryptionKey
        else {
            Log.info(.cat, "User has no display picture")
            return .success
        }
        
        guard
            let filePath: String = try? dependencies[singleton: .displayPictureManager]
                .path(for: displayPictureUrl.absoluteString),
            dependencies[singleton: .fileManager].fileExists(atPath: filePath)
        else {
            Log.warn(.cat, "User has display picture but file was not found")
            return .success
        }
        
        /// Only try to extend the TTL of the users display pic if enough time has passed since it was last updated
        let lastUpdated: Date = Date(timeIntervalSince1970: profile.profileLastUpdated ?? 0)
        
        guard
            dependencies.dateNow.timeIntervalSince(lastUpdated) > maxExtendTTLFrequency ||
            dependencies[feature: .shortenFileTTL]
        else {
            Log.info(.cat, "Ignoring as not enough time has passed since the last TTL extension")
            return .success
        }
        
        /// Try to extend the TTL of the existing profile pic first (default to providing no TTL which will extend to the server
        /// configuration)
        do {
            let targetTTL: TimeInterval? = (dependencies[feature: .shortenFileTTL] ? 60 : nil)
            let request: Network.PreparedRequest<Network.FileServer.ExtendExpirationResponse> = try Network.FileServer.preparedExtend(
                url: displayPictureUrl,
                customTtl: targetTTL,
                using: dependencies
            )
            
            // FIXME: Make this async/await when the refactored networking is merged
            _ = try await request
                .send(using: dependencies)
                .values
                .first(where: { _ in true })?.1 ?? { throw AttachmentError.uploadFailed }()
            try Task.checkCancellation()
            
            /// Even though the data hasn't changed, we need to trigger `Profile.UpdateLocal` in order for the
            /// `profileLastUpdated` value to be updated correctly
            try await Profile.updateLocal(
                displayPictureUpdate: .currentUserUpdateTo(
                    url: displayPictureUrl.absoluteString,
                    key: displayPictureEncryptionKey,
                    type: .reupload
                ),
                using: dependencies
            )
            Log.info(.cat, "Existing profile expiration extended")
            
            return .success
        } catch NetworkError.notFound {
            /// If we get a `404` it means we couldn't extend the TTL of the file so need to re-upload
        } catch {
            throw error
        }
        
        /// Since we made it here it means that refreshing the TTL failed so we may need to reupload the display picture
        let pendingDisplayPicture: PendingAttachment = PendingAttachment(
            source: .media(.url(URL(fileURLWithPath: filePath))),
            using: dependencies
        )
        try Task.checkCancellation()
        
        /// Check to see whether we want to reupload the profile
        guard
            profile.profileLastUpdated == 0 ||
            dependencies.dateNow.timeIntervalSince(lastUpdated) > maxReuploadFrequency ||
            dependencies[feature: .shortenFileTTL] ||
            dependencies[singleton: .displayPictureManager].reuploadNeedsPreparation(
                attachment: pendingDisplayPicture
            )
        else {
            Log.info(.cat, "Ignoring as not enough time has passed since the last reupload")
            return .success
        }
        
        /// Prepare and upload the display picture
        let preparedAttachment: PreparedAttachment = try await dependencies[singleton: .displayPictureManager]
            .prepareDisplayPicture(attachment: pendingDisplayPicture)
        let result = try await dependencies[singleton: .displayPictureManager]
            .uploadDisplayPicture(preparedAttachment: preparedAttachment)
        try Task.checkCancellation()
        
        /// Update the local state now that the display picture has finished uploading
        try await Profile.updateLocal(
            displayPictureUpdate: .currentUserUpdateTo(
                url: result.downloadUrl,
                key: result.encryptionKey,
                type: .reupload
            ),
            using: dependencies
        )
        
        Log.info(.cat, "Profile successfully updated")
        return .success
    }
}
