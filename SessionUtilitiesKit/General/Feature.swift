// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

public final class Features {
    public static let legacyGroupDepricationUrl: String = "https://getsession.org/groups"
}

public extension FeatureStorage {
    static let animationsEnabled: FeatureConfig<Bool> = Dependencies.create(
        identifier: "animationsEnabled",
        defaultOption: true
    )
    
    static let showStringKeys: FeatureConfig<Bool> = Dependencies.create(
        identifier: "showStringKeys"
    )
    
    static let truncatePubkeysInLogs: FeatureConfig<Bool> = Dependencies.create(
        identifier: "truncatePubkeysInLogs",
        defaultOption: {
        #if DEBUG
            return false
        #else
            return true
        #endif
        }()
    )
    
    static let forceOffline: FeatureConfig<Bool> = Dependencies.create(
        identifier: "forceOffline"
    )
    
    static let debugDisappearingMessageDurations: FeatureConfig<Bool> = Dependencies.create(
        identifier: "debugDisappearingMessageDurations"
    )
    
    static let forceSlowDatabaseQueries: FeatureConfig<Bool> = Dependencies.create(
        identifier: "forceSlowDatabaseQueries"
    )
    
    static let communityPollLimit: FeatureConfig<Int> = Dependencies.create(
        identifier: "communityPollLimit",
        defaultOption: 100
    )
    
    static let groupsShowPubkeyInConversationSettings: FeatureConfig<Bool> = Dependencies.create(
        identifier: "groupsShowPubkeyInConversationSettings"
    )
    
    static let updatedGroupsDisableAutoApprove: FeatureConfig<Bool> = Dependencies.create(
        identifier: "updatedGroupsDisableAutoApprove"
    )
    
    static let updatedGroupsRemoveMessagesOnKick: FeatureConfig<Bool> = Dependencies.create(
        identifier: "updatedGroupsRemoveMessagesOnKick"
    )
    
    static let updatedGroupsAllowHistoricAccessOnInvite: FeatureConfig<Bool> = Dependencies.create(
        identifier: "updatedGroupsAllowHistoricAccessOnInvite"
    )
    
    static let updatedGroupsAllowDisplayPicture: FeatureConfig<Bool> = Dependencies.create(
        identifier: "updatedGroupsAllowDisplayPicture"
    )
    
    static let updatedGroupsAllowDescriptionEditing: FeatureConfig<Bool> = Dependencies.create(
        identifier: "updatedGroupsAllowDescriptionEditing"
    )
    
    static let updatedGroupsAllowPromotions: FeatureConfig<Bool> = Dependencies.create(
        identifier: "updatedGroupsAllowPromotions"
    )
    
    static let updatedGroupsAllowInviteById: FeatureConfig<Bool> = Dependencies.create(
        identifier: "updatedGroupsAllowInviteById"
    )
    
    static let updatedGroupsDeleteBeforeNow: FeatureConfig<Bool> = Dependencies.create(
        identifier: "updatedGroupsDeleteBeforeNow"
    )
    
    static let updatedGroupsDeleteAttachmentsBeforeNow: FeatureConfig<Bool> = Dependencies.create(
        identifier: "updatedGroupsDeleteAttachmentsBeforeNow"
    )
    
    static let sessionProEnabled: FeatureConfig<Bool> = Dependencies.create(
        identifier: "sessionPro"
    )
    
    static let mockCurrentUserSessionProState: FeatureConfig<SessionProStateMock> = Dependencies.create(
        identifier: "mockCurrentUserSessionProState"
    )
    
    static let mockCurrentUserSessionProExpiry: FeatureConfig<SessionProStateExpiryMock> = Dependencies.create(
        identifier: "mockCurrentUserSessionProExpiry"
    )
    
    static let mockCurrentUserSessionProLoadingState: FeatureConfig<SessionProLoadingState> = Dependencies.create(
        identifier: "mockCurrentUserSessionProLoadingState"
    )
    
    static let proPlanOriginatingPlatform: FeatureConfig<ClientPlatform> = Dependencies.create(
        identifier: "proPlanOriginatingPlatform"
    )
    
    static let mockExpiredOverThirtyDays: FeatureConfig<Bool> = Dependencies.create(
        identifier: "mockExpiredOverThirtyDays",
        defaultOption: false
    )
    
    static let mockInstalledFromIPA: FeatureConfig<Bool> = Dependencies.create(
        identifier: "mockInstalledFromIPA",
        defaultOption: false
    )
    
    static let proPlanToRecover: FeatureConfig<Bool> = Dependencies.create(
        identifier: "proPlanToRecover"
    )
    
    static let allUsersSessionPro: FeatureConfig<Bool> = Dependencies.create(
        identifier: "allUsersSessionPro"
    )
    
    static let messageFeatureProBadge: FeatureConfig<Bool> = Dependencies.create(
        identifier: "messageFeatureProBadge"
    )
    
    static let messageFeatureLongMessage: FeatureConfig<Bool> = Dependencies.create(
        identifier: "messageFeatureLongMessage"
    )
    
    static let messageFeatureAnimatedAvatar: FeatureConfig<Bool> = Dependencies.create(
        identifier: "messageFeatureAnimatedAvatar"
    )
    
    static let shortenFileTTL: FeatureConfig<Bool> = Dependencies.create(
        identifier: "shortenFileTTL"
    )
    
    static let deterministicAttachmentEncryption: FeatureConfig<Bool> = Dependencies.create(
        identifier: "deterministicAttachmentEncryption"
    )
    
    static let simulateAppReviewLimit: FeatureConfig<Bool> = Dependencies.create(
        identifier: "simulateAppReviewLimit"
    )
    
    static let usePngInsteadOfWebPForFallbackImageType: FeatureConfig<Bool> = Dependencies.create(
        identifier: "usePngInsteadOfWebPForFallbackImageType"
    )
    
    static let versionDeprecationWarning: FeatureConfig<Bool> = Dependencies.create(
        identifier: "versionDeprecationWarning"
    )
    
    static let versionDeprecationMinimum: FeatureConfig<Int> = Dependencies.create(
        identifier: "versionDeprecationMinimum",
        defaultOption: 16
    )
}

// MARK: - FeatureOption

public protocol FeatureOption: RawRepresentable, Equatable, Hashable {
    static var defaultOption: Self { get }
    
    var isValidOption: Bool { get }
    var title: String { get }
    var subtitle: String? { get }
    
    static func validateOptions(defaultOption: Self)
}

public extension FeatureOption {
    var isValidOption: Bool { true }
}

// MARK: - FeatureType

public protocol FeatureType {}

// MARK: - Feature<T>

public struct Feature<T: FeatureOption>: FeatureType {
    public struct ChangeBehaviour {
        let value: T
        let condition: ChangeCondition
    }
    
    public indirect enum ChangeCondition {
        case after(timestamp: TimeInterval)
        case afterFork(hard: Int, soft: Int)
        
        case either(ChangeCondition, ChangeCondition)
        case both(ChangeCondition, ChangeCondition)
        
        static func after(date: Date) -> ChangeCondition { return .after(timestamp: date.timeIntervalSince1970) }
    }
    
    private let identifier: String
    public let defaultOption: T
    public let automaticChangeBehaviour: ChangeBehaviour?
    
    // MARK: - Initialization
    
    public init(
        identifier: String,
        defaultOption: T,
        automaticChangeBehaviour: ChangeBehaviour? = nil
    ) {
        T.validateOptions(defaultOption: defaultOption)
        
        self.identifier = identifier
        self.defaultOption = defaultOption
        self.automaticChangeBehaviour = automaticChangeBehaviour
    }
    
    // MARK: - Functions
    
    internal func hasStoredValue(using dependencies: Dependencies) -> Bool {
        return (dependencies[defaults: .appGroup].object(forKey: identifier) != nil)
    }
    
    internal func currentValue(using dependencies: Dependencies) -> T {
        let maybeSelectedOption: T? = {
            // `Int` defaults to `0` and `Bool` defaults to `false` so rather than those (in case we want
            // a default value that isn't `0` or `false` which might be considered valid cases) we check
            // if an entry exists and return `nil` if not before retrieving an `Int` representation of
            // the value and converting to the desired type
            guard dependencies[defaults: .appGroup].object(forKey: identifier) != nil else { return nil }
            guard let selectedOption: T.RawValue = dependencies[defaults: .appGroup].object(forKey: identifier) as? T.RawValue else {
                Log.error("Unable to retrieve feature option for \(identifier) due to incorrect storage type")
                return nil
            }
            
            return T(rawValue: selectedOption)
        }()
        
        /// If we have an explicitly set `selectedOption` then we should use that, otherwise we should check if any of the
        /// `automaticChangeBehaviour` conditions have been met, and if so use the specified value
        guard let selectedOption: T = maybeSelectedOption, selectedOption.isValidOption else {
            func automaticChangeConditionMet(_ condition: ChangeCondition) -> Bool {
                switch condition {
                    case .after(let timestamp): return (dependencies.dateNow.timeIntervalSince1970 >= timestamp)
                    
                    case .afterFork(let hard, let soft):
                        let currentHardFork: Int = dependencies[defaults: .standard, key: .hardfork]
                        let currentSoftFork: Int = dependencies[defaults: .standard, key: .softfork]
                        let currentVersion: Version = Version(major: currentHardFork, minor: currentSoftFork, patch: 0)
                        let requiredVersion: Version = Version(major: hard, minor: soft, patch: 0)
                        
                        return (requiredVersion >= currentVersion)

                    case .either(let firstCondition, let secondCondition):
                        return (
                            automaticChangeConditionMet(firstCondition) ||
                            automaticChangeConditionMet(secondCondition)
                        )
                        
                    case .both(let firstCondition, let secondCondition):
                        return (
                            automaticChangeConditionMet(firstCondition) &&
                            automaticChangeConditionMet(secondCondition)
                        )
                }
            }
            
            /// If the change conditions have been met then use the automatic value, otherwise use the default value
            guard
                let automaticChangeBehaviour: ChangeBehaviour = automaticChangeBehaviour,
                automaticChangeConditionMet(automaticChangeBehaviour.condition)
            else { return defaultOption }
            
            return automaticChangeBehaviour.value
        }
        
        /// We had an explicitly selected option so return that
        return selectedOption
    }
    
    internal func setValue(to updatedValue: T?, using dependencies: Dependencies) {
        dependencies[defaults: .appGroup].set(updatedValue?.rawValue, forKey: identifier)
    }
}

// MARK: - Convenience

public struct FeatureValue<R> {
    private let valueGenerator: (Dependencies) -> R
    
    public init<F: FeatureOption>(feature: FeatureConfig<F>, _ valueGenerator: @escaping (F) -> R) {
        self.valueGenerator = { [feature] dependencies in
            valueGenerator(dependencies[feature: feature])
        }
    }
    
    // MARK: - Functions
    
    public func value(using dependencies: Dependencies) -> R {
        return valueGenerator(dependencies)
    }
}

// MARK: - Bool FeatureOption

extension Bool: @retroactive CaseIterable {}
extension Bool: @retroactive RawRepresentable {}
extension Bool: FeatureOption {
    public static let allCases: [Bool] = [false, true]
    
    // MARK: - Initialization
    
    public var rawValue: Int { return (self ? 1 : 0) }
    
    public init?(rawValue: Int) {
        self = (rawValue != 0)
    }
    
    // MARK: - Feature Option
    
    public static var defaultOption: Bool = false
    
    public var title: String {
        return (self ? "Enabled" : "Disabled")
    }
    
    public var subtitle: String? {
        return (self ? "Enabled" : "Disabled")
    }
}

// MARK: - Int FeatureOption

extension Int: @retroactive RawRepresentable {}
extension Int: FeatureOption {
    // MARK: - Initialization
    
    public var rawValue: Int { return self }
    
    public init?(rawValue: Int) {
        self = rawValue
    }
    
    // MARK: - Feature Option
    
    public static var defaultOption: Int = 0
    
    public var title: String {
        return "\(self)"
    }
    
    public var subtitle: String? {
        return "\(self)"
    }
}

// MARK: - FeatureOption Validation

extension FeatureOption {
    public static func validateOptions(defaultOption: Self) {
        guard (defaultOption.rawValue as? Int) != 0 else {
            preconditionFailure("A rawValue of '0' is a protected value (it indicates unset)")
        }
    }
}

extension FeatureOption where Self == Bool {
    /// A `Bool` feature is always valid
    public static func validateOptions(defaultOption: Bool) {}
}

extension FeatureOption where Self == Int {
    public static func validateOptions(defaultOption: Int) {
        guard defaultOption != 0 else {
            preconditionFailure("A rawValue of '0' is a protected value (it indicates unset)")
        }
    }
}

extension FeatureOption where Self: CaseIterable {
    public static func validateOptions(defaultOption: Self) {
        guard !Array(Self.allCases).appending(defaultOption).contains(where: { ($0.rawValue as? Int) == 0 }) else {
            preconditionFailure("A rawValue of '0' is a protected value (it indicates unset)")
        }
    }
}
