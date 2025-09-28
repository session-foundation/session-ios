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
    
    public static func run<S: Scheduler>(
        _ job: Job,
        scheduler: S,
        success: @escaping (Job, Bool) -> Void,
        failure: @escaping (Job, Error, Bool) -> Void,
        deferred: @escaping (Job) -> Void,
        using dependencies: Dependencies
    ) {
        guard
            let threadId: String = job.threadId,
            let detailsData: Data = job.details,
            let groupName: String = dependencies[singleton: .storage].read({ db in
                try ClosedGroup
                    .filter(id: threadId)
                    .select(.name)
                    .asRequest(of: String.self)
                    .fetchOne(db)
            }),
            let details: Details = try? JSONDecoder(using: dependencies).decode(Details.self, from: detailsData)
        else { return failure(job, JobRunnerError.missingRequiredDetails, true) }
        
        let sentTimestampMs: Int64 = dependencies.networkOffsetTimestampMs()
        let adminProfile: Profile = dependencies.mutate(cache: .libSession) { $0.profile }
        
        /// Perform the actual message sending
        dependencies[singleton: .storage]
            .writePublisher { db in
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
            .tryFlatMap { _ -> AnyPublisher<(ResponseInfoType, Message), Error> in
                let groupAuthMethod: AuthenticationMethod = try Authentication.with(
                    swarmPublicKey: threadId,
                    using: dependencies
                )
                let memberAuthMethod: AuthenticationMethod = try Authentication.with(
                    swarmPublicKey: details.memberSessionIdHexString,
                    using: dependencies
                )
                
                return try MessageSender.preparedSend(
                    message: try GroupUpdateInviteMessage(
                        inviteeSessionIdHexString: details.memberSessionIdHexString,
                        groupSessionId: SessionId(.group, hex: threadId),
                        groupName: groupName,
                        memberAuthData: details.memberAuthData,
                        profile: VisibleMessage.VMProfile(
                            displayName: adminProfile.name,
                            profileKey: adminProfile.displayPictureEncryptionKey,
                            profilePictureUrl: adminProfile.displayPictureUrl
                        ),
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
                ).send(using: dependencies)
            }
            .subscribe(on: scheduler, using: dependencies)
            .receive(on: scheduler, using: dependencies)
            .sinkUntilComplete(
                receiveCompletion: { result in
                    switch result {
                        case .finished:
                            dependencies[singleton: .storage].write { db in
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
                            
                            success(job, false)
                            
                        case .failure(let error):
                            Log.error(.cat, "Couldn't send message due to error: \(error).")
                            
                            // Update the invite status of the group member (only if the role is 'standard' and
                            // the role status isn't already 'accepted')
                            dependencies[singleton: .storage].write { db in
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
                            
                            // Notify about the failure
                            dependencies.mutate(cache: .groupInviteMemberJob) { cache in
                                cache.addFailure(groupId: threadId, memberId: details.memberSessionIdHexString)
                            }
                            
                            // Register the failure
                            switch error {
                                case let senderError as MessageSenderError where !senderError.isRetryable:
                                    failure(job, error, true)
                                    
                                case StorageServerError.rateLimited:
                                    failure(job, error, true)
                                    
                                case StorageServerError.clockOutOfSync:
                                    Log.error(.cat, "Permanently Failing to send due to clock out of sync issue.")
                                    failure(job, error, true)
                                    
                                default: failure(job, error, false)
                            }
                    }
                }
            )
    }
    
    public static func failureMessage(groupName: String, memberIds: [String], profileInfo: [String: Profile]) -> ThemedAttributedString {
        let memberZeroName: String = memberIds.first
            .map { profileInfo[$0]?.displayName(for: .group) ?? $0.truncated() }
            .defaulting(to: "anonymous".localized())
        
        switch memberIds.count {
            case 1:
                return "groupInviteFailedUser"
                    .put(key: "name", value: memberZeroName)
                    .put(key: "group_name", value: groupName)
                    .localizedFormatted(baseFont: ToastController.font)

            case 2:
                let memberOneName: String = (
                    profileInfo[memberIds[1]]?.displayName(for: .group) ??
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

// MARK: - GroupInviteMemberJob Cache

public extension GroupInviteMemberJob {
    struct Failure: Hashable {
        let groupId: String
        let memberId: String
    }
    
    class Cache: GroupInviteMemberJobCacheType {
        private static let notificationDebounceDuration: DispatchQueue.SchedulerTimeType.Stride = .milliseconds(3000)
        
        private let dependencies: Dependencies
        private let failedNotificationTrigger: PassthroughSubject<(), Never> = PassthroughSubject()
        private var disposables: Set<AnyCancellable> = Set()
        public private(set) var failures: Set<Failure> = []
        
        // MARK: - Initialiation
        
        init(using dependencies: Dependencies) {
            self.dependencies = dependencies
            
            setupFailureListener()
        }
        
        // MARK: - Functions
        
        public func addFailure(groupId: String, memberId: String) {
            failures.insert(Failure(groupId: groupId, memberId: memberId))
            failedNotificationTrigger.send(())
        }
        
        public func clearPendingFailures(for groupId: String) {
            failures = failures.filter { $0.groupId != groupId }
        }
        
        // MARK: - Internal Functions
        
        private func setupFailureListener() {
            failedNotificationTrigger
                .subscribe(on: DispatchQueue.global(qos: .userInitiated), using: dependencies)
                .debounce(
                    for: Cache.notificationDebounceDuration,
                    scheduler: DispatchQueue.global(qos: .userInitiated)
                )
                .map { [dependencies] _ -> (failures: Set<Failure>, groupId: String) in
                    dependencies.mutate(cache: .groupInviteMemberJob) { cache in
                        guard let targetGroupId: String = cache.failures.first?.groupId else { return ([], "") }
                        
                        let result: Set<Failure> = cache.failures.filter { $0.groupId == targetGroupId }
                        cache.clearPendingFailures(for: targetGroupId)
                        return (result, targetGroupId)
                    }
                }
                .filter { failures, _ in !failures.isEmpty }
                .setFailureType(to: Error.self)
                .flatMapStorageReadPublisher(using: dependencies, value: { db, data -> (maybeName: String?, failedMemberIds: [String], profiles: [Profile]) in
                    let failedMemberIds: [String] = data.failures.map { $0.memberId }
                    
                    return (
                        try ClosedGroup
                            .filter(id: data.groupId)
                            .select(.name)
                            .asRequest(of: String.self)
                            .fetchOne(db),
                        failedMemberIds,
                        try Profile.filter(ids: failedMemberIds).fetchAll(db)
                    )
                })
                .map { maybeName, failedMemberIds, profiles -> (groupName: String, failedIds: [String], profileMap: [String: Profile]) in
                    let profileMap: [String: Profile] = profiles.reduce(into: [:]) { result, next in
                        result[next.id] = next
                    }
                    let sortedFailedMemberIds: [String] = failedMemberIds.sorted { lhs, rhs in
                        // Sort by name, followed by id if names aren't present
                        switch (profileMap[lhs]?.displayName(for: .group), profileMap[rhs]?.displayName(for: .group)) {
                            case (.some(let lhsName), .some(let rhsName)): return lhsName < rhsName
                            case (.some, .none): return true
                            case (.none, .some): return false
                            case (.none, .none): return lhs < rhs
                        }
                    }
                    
                    return (
                        (maybeName ?? "groupUnknown".localized()),
                        sortedFailedMemberIds,
                        profileMap
                    )
                }
                .catch { _ in Just(("", [], [:])).eraseToAnyPublisher() }
                .filter { _, failedIds, _ in !failedIds.isEmpty }
                .receive(on: DispatchQueue.main, using: dependencies)
                .sink(receiveValue: { [dependencies] groupName, failedIds, profileMap in
                    guard let mainWindow: UIWindow = dependencies[singleton: .appContext].mainWindow else { return }
                    
                    let toastController: ToastController = ToastController(
                        text: GroupInviteMemberJob.failureMessage(
                            groupName: groupName,
                            memberIds: failedIds,
                            profileInfo: profileMap
                        ),
                        background: .backgroundSecondary
                    )
                    toastController.presentToastView(fromBottomOfView: mainWindow, inset: Values.largeSpacing)
                })
                .store(in: &disposables)
        }
    }
}

public extension Cache {
    static let groupInviteMemberJob: CacheConfig<GroupInviteMemberJobCacheType, GroupInviteMemberJobImmutableCacheType> = Dependencies.create(
        identifier: "groupInviteMemberJob",
        createInstance: { dependencies, _ in GroupInviteMemberJob.Cache(using: dependencies) },
        mutableInstance: { $0 },
        immutableInstance: { $0 }
    )
}

// MARK: - GroupInviteMemberJobCacheType

/// This is a read-only version of the Cache designed to avoid unintentionally mutating the instance in a non-thread-safe way
public protocol GroupInviteMemberJobImmutableCacheType: ImmutableCacheType {
    var failures: Set<GroupInviteMemberJob.Failure> { get }
}

public protocol GroupInviteMemberJobCacheType: GroupInviteMemberJobImmutableCacheType, MutableCacheType {
    var failures: Set<GroupInviteMemberJob.Failure> { get }
    
    func addFailure(groupId: String, memberId: String)
    func clearPendingFailures(for groupId: String)
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
                default: throw MessageSenderError.invalidMessage
            }
        }
    }
}
