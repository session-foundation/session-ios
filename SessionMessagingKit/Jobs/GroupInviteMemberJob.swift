// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUIKit
import SessionUtilitiesKit
import SessionNetworkingKit

// MARK: - Log.Category

private extension Log.Category {
    static let cat: Log.Category = .create("GroupInviteMemberJob", defaultLevel: .info)
}

// MARK: - GroupInviteMemberJob

public enum GroupInviteMemberJob: JobExecutor {
    public static var maxFailureCount: Int = 1
    public static var requiresThreadId: Bool = true
    public static var requiresInteractionId: Bool = false
    
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
            let groupName: String = try await dependencies[singleton: .storage].readAsync(value: { db in
                try ClosedGroup
                    .filter(id: threadId)
                    .select(.name)
                    .asRequest(of: String.self)
                    .fetchOne(db)
            }),
            let details: Details = try? JSONDecoder(using: dependencies).decode(Details.self, from: detailsData)
        else { throw JobRunnerError.missingRequiredDetails }
        
        let sentTimestampMs: Int64 = await dependencies.networkOffsetTimestampMs()
        let adminProfile: Profile = dependencies.mutate(cache: .libSession) { $0.profile }
        
        do {
            let groupAuthMethod: AuthenticationMethod = try Authentication.with(
                swarmPublicKey: threadId,
                using: dependencies
            )
            let memberAuthMethod: AuthenticationMethod = try Authentication.with(
                swarmPublicKey: details.memberSessionIdHexString,
                using: dependencies
            )
            try Task.checkCancellation()
            
            /// Update member state
            try await dependencies[singleton: .storage].writeAsync { db in
                _ = try? GroupMember
                    .filter(GroupMember.Columns.groupId == threadId)
                    .filter(GroupMember.Columns.profileId == details.memberSessionIdHexString)
                    .filter(GroupMember.Columns.role == GroupMember.Role.standard)
                    .updateAllAndConfig(
                        db,
                        GroupMember.Columns.roleStatus.set(to: GroupMember.RoleStatus.sending),
                        using: dependencies
                    )
            }
            try Task.checkCancellation()
            
            /// Perform the actual message sending
            try await MessageSender.send(
                message: try GroupUpdateInviteMessage(
                    inviteeSessionIdHexString: details.memberSessionIdHexString,
                    groupSessionId: SessionId(.group, hex: threadId),
                    groupName: groupName,
                    memberAuthData: details.memberAuthData,
                    profile: VisibleMessage.VMProfile(profile: adminProfile),
                    sentTimestampMs: UInt64(sentTimestampMs),
                    authMethod: groupAuthMethod,
                    using: dependencies
                ),
                to: .contact(publicKey: details.memberSessionIdHexString),
                namespace: .default,
                interactionId: nil,
                attachments: nil,
                authMethod: memberAuthMethod,
                onEvent: MessageSender.standardEventHandling(using: dependencies),
                using: dependencies
            )
            try Task.checkCancellation()
            
            _ = try? await dependencies[singleton: .storage].writeAsync { db in
                try GroupMember
                    .filter(
                        GroupMember.Columns.groupId == threadId &&
                        GroupMember.Columns.profileId == details.memberSessionIdHexString &&
                        GroupMember.Columns.role == GroupMember.Role.standard &&
                        GroupMember.Columns.roleStatus != GroupMember.RoleStatus.accepted
                    )
                    .updateAllAndConfig(
                        db,
                        GroupMember.Columns.roleStatus.set(to: GroupMember.RoleStatus.pending),
                        using: dependencies
                    )
            }
            try Task.checkCancellation()
            
            return .success
        }
        catch {
            Log.error(.cat, "Couldn't send message due to error: \(error).")
            
            /// Update the invite status of the group member (only if the role is 'standard' and the role status isn't already 'accepted')
            _ = try? await dependencies[singleton: .storage].writeAsync { db in
                try GroupMember
                    .filter(
                        GroupMember.Columns.groupId == threadId &&
                        GroupMember.Columns.profileId == details.memberSessionIdHexString &&
                        GroupMember.Columns.role == GroupMember.Role.standard &&
                        GroupMember.Columns.roleStatus != GroupMember.RoleStatus.accepted
                    )
                    .updateAllAndConfig(
                        db,
                        GroupMember.Columns.roleStatus.set(to: GroupMember.RoleStatus.failed),
                        using: dependencies
                    )
            }
            try Task.checkCancellation()
            
            /// Notify about the failure
            await dependencies[singleton: .groupInviteMemberJobNotifier].addFailure(
                groupId: threadId,
                memberId: details.memberSessionIdHexString
            )
            
            /// Throw the error
            switch error {
                case is MessageError: throw error
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
                return "groupInviteFailedUser"
                    .put(key: "name", value: memberZeroName)
                    .put(key: "group_name", value: groupName)
                    .localizedFormatted(baseFont: ToastController.font)

            case 2:
                let memberOneName: String = (
                    profileInfo[memberIds[1]]?.displayName() ??
                    memberIds[1].truncated()
                )
                
                return "groupInviteFailedTwo"
                    .put(key: "name", value: memberZeroName)
                    .put(key: "other_name", value: memberOneName)
                    .put(key: "group_name", value: groupName)
                    .localizedFormatted(baseFont: ToastController.font)

            default:
                return "groupInviteFailedMultiple"
                    .put(key: "name", value: memberZeroName)
                    .put(key: "count", value: memberIds.count - 1)
                    .put(key: "group_name", value: groupName)
                    .localizedFormatted(baseFont: ToastController.font)
        }
    }
}

// MARK: - GroupInviteMemberJob Notifier

public extension GroupInviteMemberJob {
    actor Notifier: GroupInviteMemberJobNotifierType {
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
            
            let info: Info? = try? await dependencies[singleton: .storage].readAsync { db in
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
                    text: GroupInviteMemberJob.failureMessage(
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
    static let groupInviteMemberJobNotifier: SingletonConfig<GroupInviteMemberJobNotifierType> = Dependencies.create(
        identifier: "groupInviteMemberJobNotifier",
        createInstance: { dependencies, _ in GroupInviteMemberJob.Notifier(using: dependencies) }
    )
}

// MARK: - GroupInviteMemberJobNotifierType

public protocol GroupInviteMemberJobNotifierType: Actor {
    func addFailure(groupId: String, memberId: String)
}

// MARK: - GroupInviteMemberJob.Details

extension GroupInviteMemberJob {
    public struct Details: Codable {
        public let memberSessionIdHexString: String
        public let memberAuthData: Data
        
        public init(
            memberSessionIdHexString: String,
            authInfo: Authentication.Info
        ) throws {
            self.memberSessionIdHexString = memberSessionIdHexString
            
            switch authInfo {
                case .groupMember(_, let authData): self.memberAuthData = authData
                default: throw MessageError.requiredSignatureMissing
            }
        }
    }
}
