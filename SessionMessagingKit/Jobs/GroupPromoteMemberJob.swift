// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Combine
import GRDB
import SessionUIKit
import SessionUtilitiesKit
import SessionNetworkingKit

// MARK: - Log.Category

private extension Log.Category {
    static let cat: Log.Category = .create("GroupPromoteMemberJob", defaultLevel: .info)
}

// MARK: - GroupPromoteMemberJob

public enum GroupPromoteMemberJob: JobExecutor {
    public static var maxFailureCount: Int = 1
    public static var requiresThreadId: Bool = true
    public static var requiresInteractionId: Bool = false
    
    private struct GroupInfo: Codable, FetchableRecord {
        let name: String
        let groupIdentityPrivateKey: Data
    }
    
    public static func canRunConcurrentlyWith(
        runningJobs: [JobState],
        jobState: JobState,
        using dependencies: Dependencies
    ) -> Bool {
        return true
    }
    
    public static func run(_ job: Job, using dependencies: Dependencies) async throws -> JobExecutionResult {
        guard
            let threadId: String = job.threadId,
            let detailsData: Data = job.details,
            let groupInfo: GroupInfo = try await dependencies[singleton: .storage].read(value: { db in
                try ClosedGroup
                    .filter(id: threadId)
                    .select(.name, .groupIdentityPrivateKey)
                    .asRequest(of: GroupInfo.self)
                    .fetchOne(db)
            }),
            let details: Details = try? JSONDecoder(using: dependencies).decode(Details.self, from: detailsData)
        else { throw JobRunnerError.missingRequiredDetails }
        
        /// The first 32 bytes of a 64 byte ed25519 private key are the seed which can be used to generate the `KeyPair` so extract
        /// those and send along with the promotion message
        let sentTimestampMs: Int64 = await dependencies.networkOffsetTimestampMs()
        let message: GroupUpdatePromoteMessage = GroupUpdatePromoteMessage(
            groupIdentitySeed: groupInfo.groupIdentityPrivateKey.prefix(32),
            groupName: groupInfo.name,
            sentTimestampMs: UInt64(sentTimestampMs)
        )
        
        /// Perform the actual message sending
        try await dependencies[singleton: .storage].write { db in
            _ = try? GroupMember
                .filter(GroupMember.Columns.groupId == threadId)
                .filter(GroupMember.Columns.profileId == details.memberSessionIdHexString)
                .filter(GroupMember.Columns.role == GroupMember.Role.admin)
                .updateAllAndConfig(
                    db,
                    GroupMember.Columns.roleStatus.set(to: GroupMember.RoleStatus.sending),
                    using: dependencies
                )
            
            return try Authentication.with(swarmPublicKey: details.memberSessionIdHexString, using: dependencies)
        }
        try Task.checkCancellation()
        
        do {
            let authMethod: AuthenticationMethod = try Authentication.with(
                swarmPublicKey: details.memberSessionIdHexString,
                using: dependencies
            )
            try await MessageSender.send(
                message: message,
                to: .contact(publicKey: details.memberSessionIdHexString),
                namespace: .default,
                interactionId: nil,
                attachments: nil,
                authMethod: authMethod,
                onEvent: MessageSender.standardEventHandling(using: dependencies),
                using: dependencies
            )
            try Task.checkCancellation()
            
            try await dependencies[singleton: .storage].write { db in
                try GroupMember
                    .filter(
                        GroupMember.Columns.groupId == threadId &&
                        GroupMember.Columns.profileId == details.memberSessionIdHexString &&
                        GroupMember.Columns.role == GroupMember.Role.admin &&
                        GroupMember.Columns.roleStatus != GroupMember.RoleStatus.accepted
                    )
                    .updateAllAndConfig(
                        db,
                        GroupMember.Columns.roleStatus.set(to: GroupMember.RoleStatus.pending),
                        using: dependencies
                    )
            }
            
            return .success
        }
        catch {
            Log.error(.cat, "Couldn't send message due to error: \(error).")
            
            // Update the promotion status of the group member (only if the role is 'admin' and
            // the role status isn't already 'accepted')
            try await dependencies[singleton: .storage].write { db in
                try GroupMember
                    .filter(
                        GroupMember.Columns.groupId == threadId &&
                        GroupMember.Columns.profileId == details.memberSessionIdHexString &&
                        GroupMember.Columns.role == GroupMember.Role.admin &&
                        GroupMember.Columns.roleStatus != GroupMember.RoleStatus.accepted
                    )
                    .updateAllAndConfig(
                        db,
                        GroupMember.Columns.roleStatus.set(to: GroupMember.RoleStatus.failed),
                        using: dependencies
                    )
            }
            
            // Notify about the failure
            await dependencies[singleton: .groupPromoteMemberJobNotifier].addFailure(
                groupId: threadId,
                memberId: details.memberSessionIdHexString
            )
            
            // Register the failure
            switch error {
                case is MessageError: throw JobRunnerError.permanentFailure(error)
                case StorageServerError.rateLimited: throw JobRunnerError.permanentFailure(error)
                case StorageServerError.clockOutOfSync:
                    Log.error(.cat, "Permanently Failing to send due to clock out of sync issue.")
                    throw JobRunnerError.permanentFailure(error)
                    
                default: throw error
            }
        }
    }
    
    public static func failureMessage(groupName: String, memberIds: [String], profileInfo: [String: Profile]) -> ThemedAttributedString {
        let memberZeroName: String = memberIds.first
            .map { profileInfo[$0]?.displayName() ?? $0.truncated() }
            .defaulting(to: "anonymous".localized())
        
        switch memberIds.count {
            case 1:
                return "adminPromotionFailedDescription"
                    .put(key: "name", value: memberZeroName)
                    .put(key: "group_name", value: groupName)
                    .localizedFormatted(baseFont: ToastController.font)
                
            case 2:
                let memberOneName: String = (
                    profileInfo[memberIds[1]]?.displayName() ??
                    memberIds[1].truncated()
                )
                
                return "adminPromotionFailedDescriptionTwo"
                    .put(key: "name", value: memberZeroName)
                    .put(key: "other_name", value: memberOneName)
                    .put(key: "group_name", value: groupName)
                    .localizedFormatted(baseFont: ToastController.font)
                
            default:
                return "adminPromotionFailedDescriptionMultiple"
                    .put(key: "name", value: memberZeroName)
                    .put(key: "count", value: memberIds.count - 1)
                    .put(key: "group_name", value: groupName)
                    .localizedFormatted(baseFont: ToastController.font)
        }
    }
}

// MARK: - GroupPromoteMemberJob Cache

public extension GroupPromoteMemberJob {
    actor Notifier: GroupPromoteMemberJobNotifierType {
        private let dependencies: Dependencies
        private var notificationTasks: [String: Task<Void, Never>] = [:]
        private var failures: [String: Set<String>] = [:]
        
        // MARK: - Initialiation
        
        init(using dependencies: Dependencies) {
            self.dependencies = dependencies
        }
        
        // MARK: - Functions
        
        public func addFailure(groupId: String, memberId: String) {
            failures[groupId, default: []].insert(memberId)
            
            guard notificationTasks[groupId] == nil else { return }
            
            notificationTasks[groupId] = Task.detached(priority: .medium) { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                await self?.sendFailureNotifications(groupId)
            }
        }
        
        // MARK: - Internal Functions
        
        private func sendFailureNotifications(_ groupId: String) async {
            typealias Info = (name: String?, profiles: [Profile])
            
            let memberIdsToFail: Set<String> = failures[groupId, default: []]
            failures.removeValue(forKey: groupId)
            notificationTasks[groupId]?.cancel()
            notificationTasks.removeValue(forKey: groupId)
            
            guard !memberIdsToFail.isEmpty else { return }
            
            let info: Info? = try? await dependencies[singleton: .storage].read { db in
                return (
                    try ClosedGroup
                        .filter(id: groupId)
                        .select(.name)
                        .asRequest(of: String.self)
                        .fetchOne(db),
                    try Profile.filter(ids: memberIdsToFail).fetchAll(db)
                )
            }
            
            guard let info else { return }
            
            let profileMap: [String: Profile] = info.profiles.reduce(into: [:]) { result, next in
                result[next.id] = next
            }
            let sortedFailedMemberIds: [String] = memberIdsToFail.sorted { lhs, rhs in
                /// Sort by name, followed by id if names aren't present
                switch (profileMap[lhs]?.displayName(), profileMap[rhs]?.displayName()) {
                    case (.some(let lhsName), .some(let rhsName)): return lhsName < rhsName
                    case (.some, .none): return true
                    case (.none, .some): return false
                    case (.none, .none): return lhs < rhs
                }
            }
            
            /// Show the toast
            await MainActor.run { [info, sortedFailedMemberIds, profileMap] in
                guard let mainWindow: UIWindow = dependencies[singleton: .appContext].mainWindow else {
                    return
                }
                
                let toastController: ToastController = ToastController(
                    text: GroupPromoteMemberJob.failureMessage(
                        groupName: (info.name ?? "groupUnknown".localized()),
                        memberIds: sortedFailedMemberIds,
                        profileInfo: profileMap
                    ),
                    background: .backgroundSecondary
                )
                toastController.presentToastView(fromBottomOfView: mainWindow, inset: Values.largeSpacing)
            }
        }
    }
}

public extension Singleton {
    static let groupPromoteMemberJobNotifier: SingletonConfig<GroupPromoteMemberJobNotifierType> = Dependencies.create(
        identifier: "groupPromoteMemberJobNotifier",
        createInstance: { dependencies, _ in GroupPromoteMemberJob.Notifier(using: dependencies) }
    )
}

// MARK: - GroupPromoteMemberJobNotifierType

public protocol GroupPromoteMemberJobNotifierType: Actor {
    func addFailure(groupId: String, memberId: String)
}

// MARK: - GroupPromoteMemberJob.Details

extension GroupPromoteMemberJob {
    public struct Details: Codable {
        public let memberSessionIdHexString: String
    }
}
