// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import CryptoKit
import Compression
import GRDB
import DifferenceKit
import SessionUIKit
import SessionNetworkingKit
import SessionMessagingKit
import SessionUtilitiesKit
import SignalUtilitiesKit

class DeveloperSettingsViewModel: SessionTableViewModel, NavigatableStateHolder, ObservableTableSource {
    public let dependencies: Dependencies
    public let navigatableState: NavigatableState = NavigatableState()
    public let state: TableDataState<Section, TableItem> = TableDataState()
    public let observableState: ObservableTableSourceState<Section, TableItem> = ObservableTableSourceState()
    
    private var showAdvancedLogging: Bool = false
    private var contactPrefix: String = ""
    private var numberOfContacts: Int = 0
    private var databaseKeyEncryptionPassword: String = ""
    private var documentPickerResult: DocumentPickerResult?
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
    }
    
    // MARK: - Section
    
    public enum Section: SessionTableSection {
        case developerMode
        case sessionNetwork
        case sessionPro
        case groups
        case general
        case logging
        case network
        case disappearingMessages
        case communities
        case database
        
        var title: String? {
            switch self {
                case .developerMode: return nil
                case .sessionNetwork: return "Session Network"
                case .sessionPro: return "Session Pro"
                case .groups: return "Groups"
                case .general: return "General"
                case .logging: return "Logging"
                case .network: return "Network"
                case .disappearingMessages: return "Disappearing Messages"
                case .communities: return "Communities"
                case .database: return "Database"
            }
        }
        
        var style: SessionTableSectionStyle {
            switch self {
                case .developerMode: return .padding
                default: return .titleRoundedContent
            }
        }
    }
    
    public enum TableItem: Hashable, Differentiable, CaseIterable {
        case developerMode
        
        case proConfig
        case groupConfig
        
        case fileServerConfig
        case animationsEnabled
        case showStringKeys
        case truncatePubkeysInLogs
        case copyDocumentsPath
        case copyAppGroupPath
        case resetAppReviewPrompt
        case simulateAppReviewLimit
        case usePngInsteadOfWebPForFallbackImageType
        case versionDeprecationWarning
        case versionDeprecationMinimum
        
        case defaultLogLevel
        case advancedLogging
        case loggingCategory(String)
        
        case serviceNetwork
        case forceOffline
        case resetSnodeCache
        case pushNotificationService
        
        case debugDisappearingMessageDurations
        
        case communityPollLimit
        
        case versionBlindedID
        case scheduleLocalNotification
        
        case createMockContacts
        case forceSlowDatabaseQueries
        case exportDatabase
        case importDatabase
        
        // MARK: - Conformance
        
        public typealias DifferenceIdentifier = String
        
        public var differenceIdentifier: String {
            switch self {
                case .developerMode: return "developerMode"
                    
                case .proConfig: return "proConfig"
                case .groupConfig: return "groupConfig"
                
                case .fileServerConfig: return "fileServerConfig"
                case .animationsEnabled: return "animationsEnabled"
                case .showStringKeys: return "showStringKeys"
                case .truncatePubkeysInLogs: return "truncatePubkeysInLogs"
                case .copyDocumentsPath: return "copyDocumentsPath"
                case .copyAppGroupPath: return "copyAppGroupPath"
                case .resetAppReviewPrompt: return "resetAppReviewPrompt"
                case .simulateAppReviewLimit: return "simulateAppReviewLimit"
                case .usePngInsteadOfWebPForFallbackImageType: return "usePngInsteadOfWebPForFallbackImageType"
                case .versionDeprecationWarning: return "versionDeprecationWarning"
                case .versionDeprecationMinimum: return "versionDeprecationMinimum"
                
                case .defaultLogLevel: return "defaultLogLevel"
                case .advancedLogging: return "advancedLogging"
                case .loggingCategory(let categoryIdentifier): return "loggingCategory-\(categoryIdentifier)"
                
                case .serviceNetwork: return "serviceNetwork"
                case .forceOffline: return "forceOffline"
                case .resetSnodeCache: return "resetSnodeCache"
                case .pushNotificationService: return "pushNotificationService"
                
                case .debugDisappearingMessageDurations: return "debugDisappearingMessageDurations"
                    
                case .communityPollLimit: return "communityPollLimit"
                
                case .versionBlindedID: return "versionBlindedID"
                case .scheduleLocalNotification: return "scheduleLocalNotification"

                case .createMockContacts: return "createMockContacts"
                case .forceSlowDatabaseQueries: return "forceSlowDatabaseQueries"
                case .exportDatabase: return "exportDatabase"
                case .importDatabase: return "importDatabase"
            }
        }
        
        public func isContentEqual(to source: TableItem) -> Bool {
            self.differenceIdentifier == source.differenceIdentifier
        }
        
        public static var allCases: [TableItem] {
            var result: [TableItem] = []
            switch TableItem.developerMode {
                case .developerMode: result.append(.developerMode); fallthrough
                    
                case .proConfig: result.append(.proConfig); fallthrough
                case .groupConfig: result.append(.groupConfig); fallthrough
                    
                case .fileServerConfig: result.append(.fileServerConfig); fallthrough
                case .animationsEnabled: result.append(.animationsEnabled); fallthrough
                case .showStringKeys: result.append(.showStringKeys); fallthrough
                case .truncatePubkeysInLogs: result.append(.truncatePubkeysInLogs); fallthrough
                case .copyDocumentsPath: result.append(.copyDocumentsPath); fallthrough
                case .copyAppGroupPath: result.append(.copyAppGroupPath); fallthrough
                case .resetAppReviewPrompt: result.append(.resetAppReviewPrompt); fallthrough
                case .simulateAppReviewLimit: result.append(.simulateAppReviewLimit); fallthrough
                case .usePngInsteadOfWebPForFallbackImageType:
                    result.append(usePngInsteadOfWebPForFallbackImageType); fallthrough
                case .versionDeprecationWarning: result.append(.versionDeprecationWarning); fallthrough
                case .versionDeprecationMinimum: result.append(.versionDeprecationMinimum); fallthrough
                
                case .defaultLogLevel: result.append(.defaultLogLevel); fallthrough
                case .advancedLogging: result.append(.advancedLogging); fallthrough
                case .loggingCategory: result.append(.loggingCategory("")); fallthrough
                
                case .serviceNetwork: result.append(.serviceNetwork); fallthrough
                case .forceOffline: result.append(.forceOffline); fallthrough
                case .resetSnodeCache: result.append(.resetSnodeCache); fallthrough
                case .pushNotificationService: result.append(.pushNotificationService); fallthrough
                
                case .debugDisappearingMessageDurations: result.append(.debugDisappearingMessageDurations); fallthrough
                
                case .communityPollLimit: result.append(.communityPollLimit); fallthrough
                
                case .versionBlindedID: result.append(.versionBlindedID); fallthrough
                case .scheduleLocalNotification: result.append(.scheduleLocalNotification); fallthrough
                
                case .createMockContacts: result.append(.createMockContacts); fallthrough
                case .forceSlowDatabaseQueries: result.append(.forceSlowDatabaseQueries); fallthrough
                case .exportDatabase: result.append(.exportDatabase); fallthrough
                case .importDatabase: result.append(.importDatabase)
            }
            
            return result
        }
    }
    
    // MARK: - Content
    
    private struct State: Equatable {
        let developerMode: Bool
        let versionBlindedID: String?
        
        let shortenFileTTL: Bool
        let animationsEnabled: Bool
        let showStringKeys: Bool
        let truncatePubkeysInLogs: Bool
        
        let defaultLogLevel: Log.Level
        let advancedLogging: Bool
        let loggingCategories: [Log.Category: Log.Level]
        
        let serviceNetwork: ServiceNetwork
        let forceOffline: Bool
        let pushNotificationService: Network.PushNotification.Service
        
        let debugDisappearingMessageDurations: Bool
        
        let communityPollLimit: Int
        
        let forceSlowDatabaseQueries: Bool
        
        let updateSimulateAppReviewLimit: Bool
        let usePngInsteadOfWebPForFallbackImageType: Bool
        
        let versionDeprecationWarning: Bool
        let versionDeprecationMinimum: Int
    }
    
    let title: String = "Developer Settings"
    
    lazy var observation: TargetObservation = ObservationBuilderOld
        .refreshableData(self) { [weak self, dependencies] () -> State in
            let versionBlindedID: String? = {
                guard
                    let userEdKeyPair: KeyPair = dependencies[singleton: .storage].read({ Identity.fetchUserEd25519KeyPair($0) }),
                    let blinded07KeyPair: KeyPair = dependencies[singleton: .crypto].generate(
                        .versionBlinded07KeyPair(ed25519SecretKey: userEdKeyPair.secretKey)
                    )
                else {
                    return nil
                }
                return SessionId(.versionBlinded07, publicKey: blinded07KeyPair.publicKey).hexString
            }()
            

            return State(
                developerMode: dependencies.mutate(cache: .libSession) { cache in
                    cache.get(.developerModeEnabled)
                },
                versionBlindedID: versionBlindedID,
                shortenFileTTL: dependencies[feature: .shortenFileTTL],
                animationsEnabled: dependencies[feature: .animationsEnabled],
                showStringKeys: dependencies[feature: .showStringKeys],
                truncatePubkeysInLogs: dependencies[feature: .truncatePubkeysInLogs],
                
                defaultLogLevel: dependencies[feature: .logLevel(cat: .default)],
                advancedLogging: (self?.showAdvancedLogging == true),
                loggingCategories: dependencies[feature: .allLogLevels].currentValues(using: dependencies),
                
                serviceNetwork: dependencies[feature: .serviceNetwork],
                forceOffline: dependencies[feature: .forceOffline],
                pushNotificationService: dependencies[feature: .pushNotificationService],
                
                debugDisappearingMessageDurations: dependencies[feature: .debugDisappearingMessageDurations],
                
                communityPollLimit: dependencies[feature: .communityPollLimit],
                
                forceSlowDatabaseQueries: dependencies[feature: .forceSlowDatabaseQueries],
                updateSimulateAppReviewLimit: dependencies[feature: .simulateAppReviewLimit],
                usePngInsteadOfWebPForFallbackImageType: dependencies[feature: .usePngInsteadOfWebPForFallbackImageType],
                
                versionDeprecationWarning: dependencies[feature: .versionDeprecationWarning],
                versionDeprecationMinimum: dependencies[feature: .versionDeprecationMinimum]
            )
        }
        .compactMapWithPrevious { [weak self] prev, current -> [SectionModel]? in self?.content(prev, current) }
    
    private func content(_ previous: State?, _ current: State) -> [SectionModel] {
        let developerMode: SectionModel = SectionModel(
            model: .developerMode,
            elements: [
                SessionCell.Info(
                    id: .developerMode,
                    title: "Developer Mode",
                    subtitle: """
                    Grants access to this screen.
                    
                    Disabling this setting will:
                    • Reset all the below settings to default (removing data as described below)
                    • Revoke access to this screen unless Developer Mode is re-enabled
                    """,
                    trailingAccessory: .toggle(
                        current.developerMode,
                        oldValue: previous?.developerMode
                    ),
                    onTap: { [weak self] in
                        guard current.developerMode else { return }
                        
                        self?.disableDeveloperMode()
                    }
                )
            ]
        )
        let sessionPro: SectionModel = SectionModel(
            model: .sessionPro,
            elements: [
                SessionCell.Info(
                    id: .proConfig,
                    title: "Session Pro",
                    subtitle: """
                    Configure settings related to Session Pro.
                    
                    <b>Session Pro:</b> <span>\(dependencies[feature: .sessionProEnabled] ? "Enabled" : "Disabled")</span>
                    """,
                    trailingAccessory: .icon(.chevronRight),
                    onTap: { [weak self, dependencies] in
                        self?.transitionToScreen(
                            SessionTableViewController(
                                viewModel: DeveloperSettingsProViewModel(using: dependencies)
                            )
                        )
                    }
                )
            ]
        )
        let groups: SectionModel = SectionModel(
            model: .groups,
            elements: [
                SessionCell.Info(
                    id: .groupConfig,
                    title: "Group Configuration",
                    subtitle: """
                    Configure settings related to Groups.
                    """,
                    trailingAccessory: .icon(.chevronRight),
                    onTap: { [weak self, dependencies] in
                        self?.transitionToScreen(
                            SessionTableViewController(
                                viewModel: DeveloperSettingsGroupsViewModel(using: dependencies)
                            )
                        )
                    }
                )
            ]
        )
        let general: SectionModel = SectionModel(
            model: .general,
            elements: [
                SessionCell.Info(
                    id: .fileServerConfig,
                    title: "File Server Configuration",
                    subtitle: """
                    Configure settings related to the File Server.
                    
                    <b>File TTL:</b> <span>\(dependencies[feature: .shortenFileTTL] ? "60 Seconds" : "14 Days")</span>
                    <b>Deterministic Encryption:</b> <span>\(dependencies[feature: .deterministicAttachmentEncryption] ? "Enabled" : "Disabled")</span>
                    <b>File Server:</b> <span>\(Network.FileServer.server(using: dependencies))</span>
                    """,
                    trailingAccessory: .icon(.chevronRight),
                    onTap: { [weak self, dependencies] in
                        self?.transitionToScreen(
                            SessionTableViewController(
                                viewModel: DeveloperSettingsFileServerViewModel(using: dependencies)
                            )
                        )
                    }
                ),
                SessionCell.Info(
                    id: .animationsEnabled,
                    title: "Animations Enabled",
                    subtitle: """
                    Controls whether animations are enabled throughout the app
                    
                    Note: There may be some custom or low-level animations which can't be disabled via this setting
                    """,
                    trailingAccessory: .toggle(
                        current.animationsEnabled,
                        oldValue: previous?.animationsEnabled
                    ),
                    onTap: { [weak self] in
                        self?.updateFlag(
                            for: .animationsEnabled,
                            to: !current.animationsEnabled
                        )
                    }
                ),
                SessionCell.Info(
                    id: .showStringKeys,
                    title: "Show String Keys",
                    subtitle: """
                    Controls whether localised strings should render using their keys rather than the localised value (strings will be rendered as "[{key}]")
                    
                    Notes:
                    • This change will only apply to newly created screens (eg. the Settings screen will need to be closed and reopened before it gets updated
                    • The "Home" screen won't update as it never gets recreated
                    """,
                    trailingAccessory: .toggle(
                        current.showStringKeys,
                        oldValue: previous?.showStringKeys
                    ),
                    onTap: { [weak self] in
                        self?.updateFlag(
                            for: .showStringKeys,
                            to: !current.showStringKeys
                        )
                    }
                ),
                SessionCell.Info(
                    id: .truncatePubkeysInLogs,
                    title: "Truncate Public Keys in Logs",
                    subtitle: """
                    Controls whether public keys in logs should automatically be truncated (to the form "1234...abcd") when included in logs"
                    """,
                    trailingAccessory: .toggle(
                        current.truncatePubkeysInLogs,
                        oldValue: previous?.truncatePubkeysInLogs
                    ),
                    onTap: { [weak self] in
                        self?.updateFlag(
                            for: .truncatePubkeysInLogs,
                            to: !current.truncatePubkeysInLogs
                        )
                    }
                ),
                SessionCell.Info(
                    id: .copyDocumentsPath,
                    title: "Copy Documents Path",
                    subtitle: """
                    Copies the path to the Documents directory (quick way to access it for the simulator for debugging)
                    """,
                    trailingAccessory: .highlightingBackgroundLabel(title: "Copy"),
                    onTap: { [weak self] in
                        self?.copyDocumentsPath()
                    }
                ),
                SessionCell.Info(
                    id: .copyAppGroupPath,
                    title: "Copy AppGroup Path",
                    subtitle: """
                    Copies the path to the AppGroup directory (quick way to access it for the simulator for debugging)
                    """,
                    trailingAccessory: .highlightingBackgroundLabel(title: "Copy"),
                    onTap: { [weak self] in
                        self?.copyAppGroupPath()
                    }
                ),
                SessionCell.Info(
                    id: .resetAppReviewPrompt,
                    title: "Reset App Review Prompt",
                    subtitle: """
                    Clears user default settings for the app review prompt, enabling quicker testing of various display conditions.
                    """,
                    trailingAccessory: .highlightingBackgroundLabel(title: "Reset"),
                    onTap: { [weak self] in
                        self?.resetAppReviewPrompt()
                    }
                ),
                SessionCell.Info(
                    id: .simulateAppReviewLimit,
                    title: "Simulate App Review Limit",
                    subtitle: """
                    Controls whether the in-app rating prompt is displayed. This can will simulate a rate limit, preventing the prompt from appearing.
                    """,
                    trailingAccessory: .toggle(
                        current.updateSimulateAppReviewLimit,
                        oldValue: previous?.updateSimulateAppReviewLimit
                    ),
                    onTap: { [weak self] in
                        self?.updateFlag(
                            for: .simulateAppReviewLimit,
                            to: !current.updateSimulateAppReviewLimit
                        )
                    }
                ),
                SessionCell.Info(
                    id: .usePngInsteadOfWebPForFallbackImageType,
                    title: "Use PNG instead of WebP for fallback image type",
                    subtitle: """
                    Controls whether we should encode to PNG and GIF when sending less common image types (eg. HEIC/HEIF).
                    
                    This is beneficial to enable when testing Debug builds as the WebP encoding is an order of magnitude slower than in Release builds.
                    """,
                    trailingAccessory: .toggle(
                        current.usePngInsteadOfWebPForFallbackImageType,
                        oldValue: previous?.usePngInsteadOfWebPForFallbackImageType
                    ),
                    onTap: { [weak self] in
                        self?.updateFlag(
                            for: .usePngInsteadOfWebPForFallbackImageType,
                            to: !current.usePngInsteadOfWebPForFallbackImageType
                        )
                    }
                ),
                SessionCell.Info(
                    id: .versionDeprecationWarning,
                    title: "Version Deprecation Banner",
                    subtitle: """
                    Enable the banner that warns users when their operating system (iOS 15.x or earlier) is nearing the end of support or cannot access the latest features.
                    """,
                    trailingAccessory: .toggle(
                        current.versionDeprecationWarning,
                        oldValue: previous?.versionDeprecationWarning
                    ),
                    onTap: { [weak self] in
                        self?.updateFlag(
                            for: .versionDeprecationWarning,
                            to: !current.versionDeprecationWarning
                        )
                    }
                ),
                SessionCell.Info(
                    id: .versionDeprecationMinimum,
                    title: "Version Deprecation Minimum Version",
                    subtitle: """
                    The minimum version allowed before showing version deprecation warning.
                    """,
                    trailingAccessory: .dropDown { "iOS \(current.versionDeprecationMinimum)" },
                    onTap: { [weak self, dependencies] in
                        self?.transitionToScreen(
                            SessionTableViewController(
                                viewModel: SessionListViewModel<WarningVersion>(
                                    title: "Minimum iOS Version",
                                    options: [
                                        WarningVersion(version: 16),
                                        WarningVersion(version: 17),
                                        WarningVersion(version: 18)
                                    ],
                                    behaviour: .autoDismiss(
                                        initialSelection: WarningVersion(version: current.versionDeprecationMinimum),
                                        onOptionSelected: { [weak self] selected in
                                            dependencies.set(feature: .versionDeprecationMinimum, to: selected.version)
                                        }
                                    ),
                                    using: dependencies
                                )
                            )
                        )
                    }
                )
            ]
        )
        let logging: SectionModel = SectionModel(
            model: .logging,
            elements: [
                SessionCell.Info(
                    id: .defaultLogLevel,
                    title: "Default Log Level",
                    subtitle: """
                    Sets the default log level
                    
                    All logging categories which don't have a custom level set below will use this value
                    """,
                    trailingAccessory: .dropDown { current.defaultLogLevel.title },
                    onTap: { [weak self, dependencies] in
                        self?.transitionToScreen(
                            SessionTableViewController(
                                viewModel: SessionListViewModel<Log.Level>(
                                    title: "Default Log Level",
                                    options: Log.Level.allCases.filter { $0 != .default },
                                    behaviour: .autoDismiss(
                                        initialSelection: current.defaultLogLevel,
                                        onOptionSelected: self?.updateDefaulLogLevel
                                    ),
                                    using: dependencies
                                )
                            )
                        )
                    }
                ),
                SessionCell.Info(
                    id: .advancedLogging,
                    title: "Advanced Logging",
                    subtitle: "Show per-category log levels",
                    trailingAccessory: .toggle(
                        current.advancedLogging,
                        oldValue: previous?.advancedLogging
                    ),
                    onTap: { [weak self] in
                        self?.setAdvancedLoggingVisibility(to: !current.advancedLogging)
                    }
                )
            ].appending(
                contentsOf: !current.advancedLogging ? nil : current.loggingCategories
                    .sorted(by: { lhs, rhs in lhs.key.rawValue < rhs.key.rawValue })
                    .map { category, level in
                        SessionCell.Info(
                            id: .loggingCategory(category.rawValue),
                            title: category.rawValue,
                            subtitle: "Sets the log level for the \(category.rawValue) category",
                            trailingAccessory: .dropDown { level.title },
                            onTap: { [weak self, dependencies] in
                                self?.transitionToScreen(
                                    SessionTableViewController(
                                        viewModel: SessionListViewModel<Log.Level>(
                                            title: "\(category.rawValue) Log Level",
                                            options: [Log.Level.default]    // Move 'default' to the top
                                                .appending(contentsOf: Log.Level.allCases.filter { $0 != .default }),
                                            behaviour: .autoDismiss(
                                                initialSelection: level,
                                                onOptionSelected: { updatedLevel in
                                                    self?.updateLogLevel(of: category, to: updatedLevel)
                                                }
                                            ),
                                            using: dependencies
                                        )
                                    )
                                )
                            }
                        )
                    }
            )
        )
        let network: SectionModel = SectionModel(
            model: .network,
            elements: [
                SessionCell.Info(
                    id: .serviceNetwork,
                    title: "Environment",
                    subtitle: """
                    The environment used for sending requests and storing messages.
                    
                    <b>Warning:</b>
                    Changing between some of these options can result in all conversation and snode data being cleared and any pending network requests being cancelled.
                    """,
                    trailingAccessory: .dropDown { current.serviceNetwork.title },
                    onTap: { [weak self, dependencies] in
                        self?.transitionToScreen(
                            SessionTableViewController(
                                viewModel: SessionListViewModel<ServiceNetwork>(
                                    title: "Environment",
                                    options: ServiceNetwork.allCases,
                                    behaviour: .autoDismiss(
                                        initialSelection: current.serviceNetwork,
                                        onOptionSelected: self?.updateServiceNetwork
                                    ),
                                    using: dependencies
                                )
                            )
                        )
                    }
                ),
                SessionCell.Info(
                    id: .forceOffline,
                    title: "Force Offline",
                    subtitle: """
                    Shut down the current network and cause all future network requests to fail after a 1 second delay with a 'serviceUnavailable' error.
                    """,
                    trailingAccessory: .toggle(
                        current.forceOffline,
                        oldValue: previous?.forceOffline
                    ),
                    onTap: { [weak self] in self?.updateForceOffline(current: current.forceOffline) }
                ),
                SessionCell.Info(
                    id: .resetSnodeCache,
                    title: "Reset Service Node Cache",
                    subtitle: """
                    Reset and rebuild the service node cache and rebuild the paths.
                    """,
                    trailingAccessory: .highlightingBackgroundLabel(title: "Reset Cache"),
                    onTap: { [weak self] in self?.resetServiceNodeCache() }
                ),
                SessionCell.Info(
                    id: .pushNotificationService,
                    title: "Push Notification Service",
                    subtitle: """
                    The service used for subscribing for push notifications. The production service only works for production builds and neither service work in the Simulator. 
                    
                    <b>Warning:</b>
                    Changing this option will result in unsubscribing from the current service and subscribing to the new service which may take a few minutes.
                    """,
                    trailingAccessory: .dropDown { current.pushNotificationService.title },
                    onTap: { [weak self, dependencies] in
                        self?.transitionToScreen(
                            SessionTableViewController(
                                viewModel: SessionListViewModel<Network.PushNotification.Service>(
                                    title: "Push Notification Service",
                                    options: Network.PushNotification.Service.allCases,
                                    behaviour: .autoDismiss(
                                        initialSelection: current.pushNotificationService,
                                        onOptionSelected: self?.updatePushNotificationService
                                    ),
                                    using: dependencies
                                )
                            )
                        )
                    }
                )
            ]
        )
        let disappearingMessages: SectionModel = SectionModel(
            model: .disappearingMessages,
            elements: [
                SessionCell.Info(
                    id: .debugDisappearingMessageDurations,
                    title: "Debug Durations",
                    subtitle: """
                    Adds 10, 30 and 60 second durations for Disappearing Message settings.
                    
                    These should only be used for debugging purposes and will likely result in odd behaviours.
                    """,
                    trailingAccessory: .toggle(
                        current.debugDisappearingMessageDurations,
                        oldValue: previous?.debugDisappearingMessageDurations
                    ),
                    onTap: { [weak self] in
                        self?.updateFlag(
                            for: .debugDisappearingMessageDurations,
                            to: !current.debugDisappearingMessageDurations
                        )
                    }
                )
            ]
        )
        
        let communities: SectionModel = SectionModel(
            model: .communities,
            elements: [
                SessionCell.Info(
                    id: .communityPollLimit,
                    title: "Community Poll Limit",
                    subtitle: """
                    The number of messages to try to retrieve when polling a community (up to a maximum of 256).
                    
                    <b>Note:</b> An empty value, or a value of 0 will use the default value: \(dependencies.defaultValue(feature: .communityPollLimit).map { "\($0)"} ?? "N/A").
                    """,
                    trailingAccessory: .custom(info: PollLimitInputView.Info(
                        limit: dependencies[feature: .communityPollLimit],
                        onChange: { [dependencies] value in
                            dependencies.set(feature: .communityPollLimit, to: value)
                        }
                    )),
                    onTapView: { view in
                        view?.subviews
                            .flatMap { $0.subviews }
                            .first(where: { $0 is UITextField })?
                            .becomeFirstResponder()
                    }
                )
            ]
        )
        let database: SectionModel = SectionModel(
            model: .database,
            elements: [
                SessionCell.Info(
                    id: .createMockContacts,
                    title: "Create Mock Contacts",
                    subtitle: """
                    Creates the specified number of contacts and adds them to the Contacts config message.
                    
                    <b>Note:</b> Some of these may be real contacts so best not to message them
                    """,
                    trailingAccessory: .highlightingBackgroundLabel(title: "Create"),
                    onTap: { [weak self] in
                        self?.createContacts()
                    }
                ),
                SessionCell.Info(
                    id: .forceSlowDatabaseQueries,
                    title: "Force slow database queries",
                    subtitle: """
                    Controls whether we artificially add an initial 1s delay to all database queries.
                    
                    <b>Note:</b> This is generally not desired (as it'll make things run slowly) but can be beneficial for testing to track down database queries which are running on the main thread when they shouldn't be.
                    """,
                    trailingAccessory: .toggle(
                        current.forceSlowDatabaseQueries,
                        oldValue: previous?.forceSlowDatabaseQueries
                    ),
                    onTap: { [weak self] in
                        self?.updateFlag(
                            for: .forceSlowDatabaseQueries,
                            to: !current.forceSlowDatabaseQueries
                        )
                    }
                ),
                SessionCell.Info(
                    id: .exportDatabase,
                    title: "Export App Data",
                    trailingAccessory: .icon(
                        UIImage(systemName: "square.and.arrow.up.trianglebadge.exclamationmark")?
                            .withRenderingMode(.alwaysTemplate),
                        size: .small
                    ),
                    styling: SessionCell.StyleInfo(
                        tintColor: .danger
                    ),
                    onTapView: { [weak self] view in self?.exportDatabase(view) }
                ),
                SessionCell.Info(
                    id: .importDatabase,
                    title: "Import App Data",
                    trailingAccessory: .icon(
                        UIImage(systemName: "square.and.arrow.down")?
                            .withRenderingMode(.alwaysTemplate),
                        size: .small
                    ),
                    styling: SessionCell.StyleInfo(
                        tintColor: .danger
                    ),
                    onTapView: { [weak self] view in self?.importDatabase(view) }
                )
            ]
        )
        let sessionNetwork: SectionModel = SectionModel(
            model: .sessionNetwork,
            elements: [
                (current.versionBlindedID == nil ? nil :
                    SessionCell.Info(
                        id: .versionBlindedID,
                        title: "Version Blinded ID",
                        subtitle: current.versionBlindedID!,
                        trailingAccessory: .button(
                            style: .bordered,
                            title: "copy".localized(),
                            run: { [weak self] button in
                                self?.copyVersionBlindedID(current.versionBlindedID!, button: button)
                            }
                        )
                    )
                ),
                SessionCell.Info(
                    id: .scheduleLocalNotification,
                    title: "Schedule Local Notification",
                    subtitle: """
                    Schedule a local notifcation in 10 seconds from click
                    
                    Note: local scheduled notifcations are not reliable on Simulators
                    """,
                    trailingAccessory: .button(
                        style: .bordered,
                        title: "Fire",
                        run: { [weak self] button in
                            self?.scheduleLocalNotification(button: button)
                        }
                    )
                )
            ].compactMap { $0 }
        )
        
        return [
            developerMode,
            sessionPro,
            groups,
            general,
            logging,
            network,
            disappearingMessages,
            communities,
            sessionNetwork,
            database
        ]
    }
    
    // MARK: - Functions
    
    private func disableDeveloperMode() {
        /// Loop through all of the sections and reset the features back to default for each one as needed (this way if a new section is added
        /// then we will get a compile error if it doesn't get resetting instructions added)
        TableItem.allCases.forEach { item in
            switch item {
                case .developerMode, .versionBlindedID, .scheduleLocalNotification, .copyDocumentsPath,
                    .copyAppGroupPath, .resetSnodeCache, .createMockContacts, .exportDatabase,
                    .importDatabase, .advancedLogging, .resetAppReviewPrompt:
                    break   /// These are actions rather than values stored as "features" so no need to do anything
                
                case .groupConfig: DeveloperSettingsGroupsViewModel.disableDeveloperMode(using: dependencies)
                case .proConfig: DeveloperSettingsProViewModel.disableDeveloperMode(using: dependencies)
                case .fileServerConfig:
                    DeveloperSettingsFileServerViewModel.disableDeveloperMode(using: dependencies)
                    
                case .animationsEnabled:
                    guard dependencies.hasSet(feature: .animationsEnabled) else { return }
                    
                    updateFlag(for: .animationsEnabled, to: nil)
                    
                case .showStringKeys:
                    guard dependencies.hasSet(feature: .showStringKeys) else { return }
                    
                    updateFlag(for: .showStringKeys, to: nil)
                    
                case .truncatePubkeysInLogs:
                    guard dependencies.hasSet(feature: .truncatePubkeysInLogs) else { return }
                    
                    updateFlag(for: .truncatePubkeysInLogs, to: nil)
                    
                case .simulateAppReviewLimit:
                    guard dependencies.hasSet(feature: .simulateAppReviewLimit) else { return }
                    
                    updateFlag(for: .simulateAppReviewLimit, to: nil)
                    
                case .usePngInsteadOfWebPForFallbackImageType:
                    guard dependencies.hasSet(feature: .usePngInsteadOfWebPForFallbackImageType) else { return }
                    
                    updateFlag(for: .usePngInsteadOfWebPForFallbackImageType, to: nil)
                    
                case .defaultLogLevel: updateDefaulLogLevel(to: nil)    // Always reset
                case .loggingCategory: resetLoggingCategories()         // Always reset
                
                case .serviceNetwork:
                    guard dependencies.hasSet(feature: .serviceNetwork) else { return }
                    
                    updateServiceNetwork(to: nil)
                    
                case .forceOffline:
                    guard dependencies.hasSet(feature: .forceOffline) else { return }
                    
                    updateFlag(for: .forceOffline, to: nil)
                    
                case .pushNotificationService:
                    guard dependencies.hasSet(feature: .pushNotificationService) else { return }
                    
                    updatePushNotificationService(to: nil)
                    
                case .debugDisappearingMessageDurations:
                    guard dependencies.hasSet(feature: .debugDisappearingMessageDurations) else { return }
                    
                    updateFlag(for: .debugDisappearingMessageDurations, to: nil)
                
                case .versionDeprecationWarning:
                    guard dependencies.hasSet(feature: .versionDeprecationWarning) else { return }
                    
                    updateFlag(for: .versionDeprecationWarning, to: nil)
                case .versionDeprecationMinimum:
                    guard dependencies.hasSet(feature: .versionDeprecationMinimum) else { return }
                    
                    dependencies.set(feature: .versionDeprecationMinimum, to: nil)
                    
                case .communityPollLimit:
                    guard dependencies.hasSet(feature: .communityPollLimit) else { return }
                    
                    dependencies.set(feature: .communityPollLimit, to: nil)
                    forceRefresh(type: .databaseQuery)
                    
                case .forceSlowDatabaseQueries:
                    guard dependencies.hasSet(feature: .forceSlowDatabaseQueries) else { return }
                    
                    updateFlag(for: .forceSlowDatabaseQueries, to: nil)
            }
        }
        
        /// Disable developer mode
        dependencies.setAsync(.developerModeEnabled, false)
        self.dismissScreen(type: .pop)
    }

    private func updateDefaulLogLevel(to updatedDefaultLogLevel: Log.Level?) {
        dependencies.set(feature: .logLevel(cat: .default), to: updatedDefaultLogLevel)
        forceRefresh(type: .databaseQuery)
    }
    
    private func setAdvancedLoggingVisibility(to value: Bool) {
        self.showAdvancedLogging = value
        forceRefresh(type: .databaseQuery)
    }
    
    private func updateLogLevel(of category: Log.Category, to level: Log.Level) {
        switch (level, category.defaultLevel) {
            case (.default, category.defaultLevel): dependencies.reset(feature: .logLevel(cat: category))
            default: dependencies.set(feature: .logLevel(cat: category), to: level)
        }
        forceRefresh(type: .databaseQuery)
    }
    
    private func resetLoggingCategories() {
        dependencies[feature: .allLogLevels].currentValues(using: dependencies).forEach { category, _ in
            dependencies.reset(feature: .logLevel(cat: category))
        }
        forceRefresh(type: .databaseQuery)
    }
    
    private func updateServiceNetwork(to updatedNetwork: ServiceNetwork?) {
        DeveloperSettingsViewModel.updateServiceNetwork(to: updatedNetwork, using: dependencies)
        forceRefresh(type: .databaseQuery)
    }
    
    private func updatePushNotificationService(to updatedService: Network.PushNotification.Service?) {
        guard
            dependencies[defaults: .standard, key: .isUsingFullAPNs],
            updatedService != dependencies[feature: .pushNotificationService]
        else {
            forceRefresh(type: .databaseQuery)
            return
        }
        
        /// Disable push notifications to trigger the unsubscribe, then re-enable them after updating the feature setting
        dependencies[defaults: .standard, key: .isUsingFullAPNs] = false
        
        SyncPushTokensJob
            .run(uploadOnlyIfStale: false, using: dependencies)
            .handleEvents(
                receiveOutput: { [weak self, dependencies] _ in
                    dependencies.set(feature: .pushNotificationService, to: updatedService)
                    dependencies[defaults: .standard, key: .isUsingFullAPNs] = true
                    
                    self?.forceRefresh(type: .databaseQuery)
                }
            )
            .flatMap { [dependencies] _ in SyncPushTokensJob.run(uploadOnlyIfStale: false, using: dependencies) }
            .sinkUntilComplete()
    }
    
    internal static func updateServiceNetwork(
        to updatedNetwork: ServiceNetwork?,
        using dependencies: Dependencies
    ) {
        struct IdentityData {
            let ed25519KeyPair: KeyPair
            let x25519KeyPair: KeyPair
        }
        
        /// Make sure we are actually changing the network before clearing all of the data
        guard
            updatedNetwork != dependencies[feature: .serviceNetwork],
            let identityData: IdentityData = dependencies[singleton: .storage].read({ db in
                IdentityData(
                    ed25519KeyPair: KeyPair(
                        publicKey: Array(try Identity
                            .filter(Identity.Columns.variant == Identity.Variant.ed25519PublicKey)
                            .fetchOne(db, orThrow: StorageError.objectNotFound)
                            .data),
                        secretKey: Array(try Identity
                            .filter(Identity.Columns.variant == Identity.Variant.ed25519SecretKey)
                            .fetchOne(db, orThrow: StorageError.objectNotFound)
                            .data)
                    ),
                    x25519KeyPair: KeyPair(
                        publicKey: Array(try Identity
                            .filter(Identity.Columns.variant == Identity.Variant.x25519PublicKey)
                            .fetchOne(db, orThrow: StorageError.objectNotFound)
                            .data),
                        secretKey: Array(try Identity
                            .filter(Identity.Columns.variant == Identity.Variant.x25519PrivateKey)
                            .fetchOne(db, orThrow: StorageError.objectNotFound)
                            .data)
                    )
                )
            })
        else { return }
        
        Log.info("[DevSettings] Swapping to \(String(describing: updatedNetwork)), clearing data")
        
        /// Stop all pollers
        dependencies[singleton: .currentUserPoller].stop()
        dependencies.remove(cache: .groupPollers)
        dependencies.remove(cache: .communityPollers)
        
        /// Reset the network
        ///
        /// **Note:** We need to store the current `libSessionNetwork` cache until after we swap the `serviceNetwork`
        /// and start warming the new cache, otherwise it's destruction can result in automatic recreation due to path and network
        /// status observers
        dependencies.mutate(cache: .libSessionNetwork) {
            $0.setPaths(paths: [])
            $0.setNetworkStatus(status: .unknown)
            $0.suspendNetworkAccess()
            $0.clearSnodeCache()
            $0.clearCallbacks()
        }
        var oldNetworkCache: LibSession.NetworkImmutableCacheType? = dependencies[cache: .libSessionNetwork]
        dependencies.remove(cache: .libSessionNetwork)
        
        /// Unsubscribe from push notifications (do this after resetting the network as they are server requests so aren't dependant on a service
        /// layer and we don't want these to be cancelled)
        if let existingToken: String = dependencies[singleton: .storage].read({ db in db[.lastRecordedPushToken] }) {
            Network.PushNotification
                .unsubscribeAll(token: Data(hex: existingToken), using: dependencies)
                .sinkUntilComplete()
        }
        
        /// Clear the snodeAPI  caches
        dependencies.remove(cache: .snodeAPI)
        
        /// Remove the libSession state (store the profile locally to maintain the name between environments)
        let existingProfile: Profile = dependencies.mutate(cache: .libSession) { $0.profile }
        dependencies.remove(cache: .libSession)
        
        /// Remove any network-specific data
        dependencies[singleton: .storage].write { [dependencies] db in
            let userSessionId: SessionId = dependencies[cache: .general].sessionId
            
            _ = try SnodeReceivedMessageInfo.deleteAll(db)
            _ = try SessionThread.deleteAll(db)
            _ = try MessageDeduplication.deleteAll(db)
            _ = try ClosedGroup.deleteAll(db)
            _ = try OpenGroup.deleteAll(db)
            _ = try Capability.deleteAll(db)
            _ = try GroupMember.deleteAll(db)
            _ = try Contact
                .filter(Contact.Columns.id != userSessionId.hexString)
                .deleteAll(db)
            _ = try Profile
                .filter(Profile.Columns.id != userSessionId.hexString)
                .deleteAll(db)
            _ = try BlindedIdLookup.deleteAll(db)
            _ = try ConfigDump.deleteAll(db)
        }
        
        /// Remove the `ExtensionHelper` cache
        dependencies[singleton: .extensionHelper].deleteCache()
        
        Log.info("[DevSettings] Reloading state for \(String(describing: updatedNetwork))")
        
        /// Update to the new `ServiceNetwork`
        dependencies.set(feature: .serviceNetwork, to: updatedNetwork)
        
        /// Start the new network cache and clear out the old one
        dependencies.warmCache(cache: .libSessionNetwork)
        
        /// Free the `oldNetworkCache` so it can be destroyed(the 'if' is only there to prevent the "variable never read" warning)
        if oldNetworkCache != nil { oldNetworkCache = nil }
        
        /// Run the onboarding process as if we are recovering an account (will setup the device in it's proper state)
        Onboarding.Cache(
            ed25519KeyPair: identityData.ed25519KeyPair,
            x25519KeyPair: identityData.x25519KeyPair,
            displayName: existingProfile.name
                .nullIfEmpty
                .defaulting(to: "anonymous".localized()),
            using: dependencies
        ).completeRegistration { [dependencies] in
            /// Re-enable developer mode
            dependencies.setAsync(.developerModeEnabled, true)
            
            /// Restart the current user poller (there won't be any other pollers though)
            Task { @MainActor [currentUserPoller = dependencies[singleton: .currentUserPoller]] in
                currentUserPoller.startIfNeeded()
            }
            
            /// Re-sync the push tokens (if there are any)
            SyncPushTokensJob.run(uploadOnlyIfStale: false, using: dependencies).sinkUntilComplete()
            
            Log.info("[DevSettings] Completed swap to \(String(describing: updatedNetwork))")
        }
    }
    
    private func updateFlag(for feature: FeatureConfig<Bool>, to updatedFlag: Bool?) {
        /// Update to the new flag
        dependencies.set(feature: feature, to: updatedFlag)
        forceRefresh(type: .databaseQuery)
    }
    
    private func updateForceOffline(current: Bool) {
        updateFlag(for: .forceOffline, to: !current)
        
        // Reset the network cache
        dependencies.mutate(cache: .libSessionNetwork) {
            $0.setPaths(paths: [])
            $0.setNetworkStatus(status: current ? .unknown : .disconnected)
        }
        dependencies.remove(cache: .libSessionNetwork)
    }
    
    private func resetServiceNodeCache() {
        self.transitionToScreen(
            ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: "Reset Service Node Cache",
                    body: .text("The device will need to fetch a new cache and rebuild it's paths"),
                    confirmTitle: "Reset Cache",
                    confirmStyle: .danger,
                    cancelStyle: .alert_text,
                    dismissOnConfirm: true,
                    onConfirm: { [dependencies] _ in
                        /// Clear the snodeAPI cache
                        dependencies.remove(cache: .snodeAPI)
                        
                        /// Clear the snode cache
                        dependencies.mutate(cache: .libSessionNetwork) { $0.clearSnodeCache() }
                    }
                )
            ),
            transitionType: .present
        )
    }
    
    private func createContacts() {
        self.transitionToScreen(
            ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: "Create Mock Contacts",
                    body: .dualInput(
                        explanation: ThemedAttributedString(string: "How many contacts should be created?"),
                        firstInfo: ConfirmationModal.Info.Body.InputInfo(
                            placeholder: "Prefix",
                            initialValue: "Contact",
                            clearButton: true
                        ),
                        secondInfo: ConfirmationModal.Info.Body.InputInfo(
                            placeholder: "Number of contacts",
                            initialValue: "100",
                            clearButton: true
                        ),
                        onChange: { [weak self] prefix, numberString in
                            guard let number: Int = Int(numberString) else { return }
                            
                            self?.contactPrefix = prefix
                            self?.numberOfContacts = number
                        }
                    ),
                    confirmTitle: "Create",
                    confirmStyle: .alert_text,
                    cancelTitle: "Cancel",
                    cancelStyle: .alert_text,
                    hasCloseButton: true,
                    dismissOnConfirm: false,
                    onConfirm: { [weak self, dependencies] modal in
                        guard
                            let numberOfContacts: Int = self?.numberOfContacts,
                            numberOfContacts > 0
                        else { return }
                        
                        modal.dismiss(animated: true) {
                            let viewController: UIViewController = ModalActivityIndicatorViewController(canCancel: false) { indicator in
                                let timestampMs: Double = dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
                                let currentUserSessionId: SessionId = dependencies[cache: .general].sessionId
                                
                                dependencies[singleton: .storage].writeAsync(
                                    updates: { db in
                                        try (0..<numberOfContacts).forEach { index in
                                            guard
                                                let x25519KeyPair: KeyPair = dependencies[singleton: .crypto].generate(
                                                    .x25519KeyPair()
                                                )
                                            else { return }
                                            
                                            let sessionId = SessionId(.standard, publicKey: x25519KeyPair.publicKey)
                                            
                                            _ = try Contact(
                                                id: sessionId.hexString,
                                                isApproved: true,
                                                currentUserSessionId: currentUserSessionId
                                            ).upserted(db)
                                            _ = try Profile(
                                                id: sessionId.hexString,
                                                name: String(format: "\(self?.contactPrefix ?? "")%04d", index + 1)
                                            ).upserted(db)
                                            _ = try SessionThread.upsert(
                                                db,
                                                id: sessionId.hexString,
                                                variant: .contact,
                                                values: SessionThread.TargetValues(
                                                    creationDateTimestamp: .setTo(timestampMs / 1000),
                                                    shouldBeVisible: .setTo(true)
                                                ),
                                                using: dependencies
                                            )
                                            
                                            try Contact
                                                .filter(id: sessionId.hexString)
                                                .updateAllAndConfig(
                                                    db,
                                                    Contact.Columns.isApproved.set(to: true),
                                                    using: dependencies
                                                )
                                            db.addContactEvent(
                                                id: sessionId.hexString,
                                                change: .isApproved(true)
                                            )
                                        }
                                    },
                                    completion: { _ in
                                        indicator.dismiss {
                                            self?.showToast(
                                                text: "Contacts Created",
                                                backgroundColor: .backgroundSecondary
                                            )
                                        }
                                    }
                                )
                            }
                            
                            self?.transitionToScreen(viewController, transitionType: .present)
                        }
                    },
                    onCancel: { modal in
                        modal.dismiss(animated: true)
                    }
                )
            ),
            transitionType: .present
        )
    }
    
    private func copyDocumentsPath() {
        UIPasteboard.general.string = dependencies[singleton: .fileManager].documentsDirectoryPath
        
        showToast(
            text: "copied".localized(),
            backgroundColor: .backgroundSecondary
        )
    }
    
    private func copyAppGroupPath() {
        UIPasteboard.general.string = dependencies[singleton: .fileManager].appSharedDataDirectoryPath
        
        showToast(
            text: "copied".localized(),
            backgroundColor: .backgroundSecondary
        )
    }
    
    private func resetAppReviewPrompt() {
        dependencies[defaults: .standard, key: .didShowAppReviewPrompt] = false
        dependencies[defaults: .standard, key: .hasVisitedPathScreen] = false
        dependencies[defaults: .standard, key: .hasPressedDonateButton] = false
        dependencies[defaults: .standard, key: .hasChangedTheme] = false
        dependencies[defaults: .standard, key: .rateAppRetryDate] = nil
        dependencies[defaults: .standard, key: .rateAppRetryAttemptCount] = 0
        
        showToast(
            text: "Cleared",
            backgroundColor: .backgroundSecondary
        )
    }
    
    // MARK: - SESH
    
    private func scheduleLocalNotification(button: SessionButton?) {
        dependencies[singleton: .notificationsManager].scheduleSessionNetworkPageLocalNotifcation(force: true)
        
        guard let button: SessionButton = button else { return }
        
        // Ensure we are on the main thread just in case
        DispatchQueue.main.async {
            button.isUserInteractionEnabled = false
            
            UIView.transition(
                with: button,
                duration: 0.25,
                options: .transitionCrossDissolve,
                animations: {
                    button.setTitle("Fired", for: .normal)
                },
                completion: { _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(12)) {
                        button.isUserInteractionEnabled = true
                    
                        UIView.transition(
                            with: button,
                            duration: 0.25,
                            options: .transitionCrossDissolve,
                            animations: {
                                button.setTitle("Fire", for: .normal)
                            },
                            completion: nil
                        )
                    }
                }
            )
        }
    }
        
    private func copyVersionBlindedID(_ versionBlindedID: String, button: SessionButton?) {
        UIPasteboard.general.string = versionBlindedID
        
        guard let button: SessionButton = button else { return }
        
        // Ensure we are on the main thread just in case
        DispatchQueue.main.async {
            button.isUserInteractionEnabled = false
            
            UIView.transition(
                with: button,
                duration: 0.25,
                options: .transitionCrossDissolve,
                animations: {
                    button.setTitle("copied".localized(), for: .normal)
                },
                completion: { _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(4)) {
                        button.isUserInteractionEnabled = true
                    
                        UIView.transition(
                            with: button,
                            duration: 0.25,
                            options: .transitionCrossDissolve,
                            animations: {
                                button.setTitle("copy".localized(), for: .normal)
                            },
                            completion: nil
                        )
                    }
                }
            )
        }
    }
    
    // MARK: - Export and Import
    
    private func exportDatabase(_ targetView: UIView?) {
        let generatedPassword: String = UUID().uuidString
        self.databaseKeyEncryptionPassword = generatedPassword
        
        self.transitionToScreen(
            ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: "Export App Data",
                    body: .input(
                        explanation: ThemedAttributedString(
                            string: """
                            This will generate a file encrypted using the provided password includes all app data, attachments, settings and keys.
                            
                            This exported file can only be imported by Session iOS. 
                            
                            Use at your own risk!

                            We've generated a secure password for you but feel free to provide your own.
                            """
                        ),
                        info: ConfirmationModal.Info.Body.InputInfo(
                            placeholder: "Enter a password",
                            initialValue: generatedPassword,
                            clearButton: true
                        ),
                        onChange: { [weak self] value in self?.databaseKeyEncryptionPassword = value }
                    ),
                    confirmTitle: "save".localized(),
                    confirmStyle: .alert_text,
                    cancelTitle: "share".localized(),
                    cancelStyle: .alert_text,
                    hasCloseButton: true,
                    dismissOnConfirm: false,
                    onConfirm: { [weak self] modal in
                        modal.dismiss(animated: true) {
                            self?.performExport(viaShareSheet: false, targetView: targetView)
                        }
                    },
                    onCancel: { [weak self] modal in
                        modal.dismiss(animated: true) {
                            self?.performExport(viaShareSheet: true, targetView: targetView)
                        }
                    }
                )
            ),
            transitionType: .present
        )
    }
    
    private func importDatabase(_ targetView: UIView?) {
        self.databaseKeyEncryptionPassword = ""
        self.transitionToScreen(
            ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: "Import App Data",
                    body: .input(
                        explanation: ThemedAttributedString(
                            string: """
                            Importing a database will result in the loss of all data stored locally.
                            
                            This can only import backup files exported by Session iOS.

                            Use at your own risk!
                            """
                        ),
                        info: ConfirmationModal.Info.Body.InputInfo(
                            placeholder: "Enter a password",
                            initialValue: "",
                            clearButton: true
                        ),
                        onChange: { [weak self] value in self?.databaseKeyEncryptionPassword = value }
                    ),
                    confirmTitle: "Import",
                    confirmStyle: .danger,
                    cancelStyle: .alert_text,
                    dismissOnConfirm: false,
                    onConfirm: { [weak self] modal in
                        modal.dismiss(animated: true) {
                            self?.performImport()
                        }
                    }
                )
            ),
            transitionType: .present
        )
    }
    
    @MainActor private func performExport(
        viaShareSheet: Bool,
        targetView: UIView?
    ) {
        func showError(_ error: Error) {
            self.transitionToScreen(
                ConfirmationModal(
                    info: ConfirmationModal.Info(
                        title: "theError".localized(),
                        body: {
                            switch error {
                                case CryptoKitError.incorrectKeySize:
                                    return .text("The password must be between 6 and 32 characters (padded to 32 bytes)")
                                case is DatabaseError:
                                    return .text("An error occurred finalising pending changes in the database")
                                
                                default: return .text("Failed to export database")
                            }
                        }()
                    )
                ),
                transitionType: .present
            )
        }
        guard databaseKeyEncryptionPassword.count >= 6 else { return showError(CryptoKitError.incorrectKeySize) }
        
        let viewController: UIViewController = ModalActivityIndicatorViewController(canCancel: false) { [weak self, databaseKeyEncryptionPassword, dependencies] modalActivityIndicator in
            let backupFile: String = "\(dependencies[singleton: .fileManager].temporaryDirectory)/session.bak"
            
            do {
                /// Perform a full checkpoint to ensure any pending changes are written to the main database file
                try dependencies[singleton: .storage].checkpoint(.truncate)
                
                let secureDbKey: String = try dependencies[singleton: .storage].secureExportKey(
                    password: databaseKeyEncryptionPassword
                )
                
                try DirectoryArchiver.archiveDirectory(
                    sourcePath: dependencies[singleton: .fileManager].appSharedDataDirectoryPath,
                    destinationPath: backupFile,
                    filenamesToExclude: [
                        "\(Storage.dbFileName)-wal",
                        "\(Storage.dbFileName)-shm"
                    ],
                    additionalPaths: [secureDbKey],
                    password: databaseKeyEncryptionPassword,
                    progressChanged: { fileIndex, totalFiles, currentFileProgress, currentFileSize in
                        let percentage: Int = {
                            guard currentFileSize > 0 else { return 100 }
                            
                            let percentage: Int = Int((Double(currentFileProgress) / Double(currentFileSize)) * 100)
                            
                            guard percentage > 0 else { return 100 }
                            
                            return percentage
                        }()
                        
                        DispatchQueue.main.async {
                            modalActivityIndicator.setMessage([
                                "Exporting file: \(fileIndex)/\(totalFiles)",
                                "File encryption progress: \(percentage)%"
                            ].compactMap { $0 }.joined(separator: "\n"))
                        }
                    }
                )
            }
            catch {
                modalActivityIndicator.dismiss {
                    showError(error)
                }
                return
            }
            
            modalActivityIndicator.dismiss {
                switch viaShareSheet {
                    case true:
                        let shareVC: UIActivityViewController = UIActivityViewController(
                            activityItems: [ URL(fileURLWithPath: backupFile) ],
                            applicationActivities: nil
                        )
                        shareVC.completionWithItemsHandler = { _, success, _, _ in
                            UIActivityViewController.notifyIfNeeded(success, using: dependencies)
                        }
                        
                        if UIDevice.current.isIPad {
                            shareVC.excludedActivityTypes = []
                            shareVC.popoverPresentationController?.permittedArrowDirections = (targetView != nil ? [.up] : [])
                            shareVC.popoverPresentationController?.sourceView = targetView
                            shareVC.popoverPresentationController?.sourceRect = (targetView?.bounds ?? .zero)
                        }
                        
                        self?.transitionToScreen(shareVC, transitionType: .present)
                        
                    case false:
                        // Create and present the document picker
                        let documentPickerResult: DocumentPickerResult = DocumentPickerResult { _ in }
                        self?.documentPickerResult = documentPickerResult
                        
                        let documentPicker: UIDocumentPickerViewController = UIDocumentPickerViewController(
                            forExporting: [URL(fileURLWithPath: backupFile)]
                        )
                        documentPicker.delegate = documentPickerResult
                        documentPicker.modalPresentationStyle = .formSheet
                        self?.transitionToScreen(documentPicker, transitionType: .present)
                }
            }
        }
        
        self.transitionToScreen(viewController, transitionType: .present)
    }
    
    private func performImport() {
        func showError(_ error: Error) {
            self.transitionToScreen(
                ConfirmationModal(
                    info: ConfirmationModal.Info(
                        title: "theError".localized(),
                        body: {
                            switch error {
                                case CryptoKitError.incorrectKeySize:
                                    return .text("The password must be between 6 and 32 characters (padded to 32 bytes)")
                                
                                case is DatabaseError: return .text("Database key in backup file was invalid.")
                                default: return .text("\(error)")
                            }
                        }()
                    )
                ),
                transitionType: .present
            )
        }
        
        guard databaseKeyEncryptionPassword.count >= 6 else { return showError(CryptoKitError.incorrectKeySize) }
        
        let documentPickerResult: DocumentPickerResult = DocumentPickerResult { url in
            guard let url: URL = url else { return }

            let viewController: UIViewController = ModalActivityIndicatorViewController(canCancel: false) { [weak self, password = self.databaseKeyEncryptionPassword, dependencies = self.dependencies] modalActivityIndicator in
                do {
                    let tmpUnencryptPath: String = "\(dependencies[singleton: .fileManager].temporaryDirectory)/new_session.bak"
                    let (paths, additionalFilePaths): ([String], [String]) = try DirectoryArchiver.unarchiveDirectory(
                        archivePath: url.path,
                        destinationPath: tmpUnencryptPath,
                        password: password,
                        progressChanged: { filesSaved, totalFiles, fileProgress, fileSize in
                            let percentage: Int = {
                                guard fileSize > 0 else { return 0 }
                                
                                return Int((Double(fileProgress) / Double(fileSize)) * 100)
                            }()
                            
                            DispatchQueue.main.async {
                                modalActivityIndicator.setMessage([
                                    "Decryption progress: \(percentage)%",
                                    "Files imported: \(filesSaved)/\(totalFiles)"
                                ].compactMap { $0 }.joined(separator: "\n"))
                            }
                        }
                    )
                    
                    /// Test that we actually have valid access to the database
                    guard
                        let encKeyPath: String = additionalFilePaths
                            .first(where: { $0.hasSuffix(Storage.encKeyFilename) }),
                        let databasePath: String = paths
                            .first(where: { $0.hasSuffix(Storage.dbFileName) })
                    else { throw ArchiveError.unableToFindDatabaseKey }
                    
                    DispatchQueue.main.async {
                        modalActivityIndicator.setMessage(
                            "Checking for valid database..."
                        )
                    }
                    
                    let testStorage: Storage = try Storage(
                        testAccessTo: databasePath,
                        encryptedKeyPath: encKeyPath,
                        encryptedKeyPassword: password,
                        using: dependencies
                    )
                    
                    guard testStorage.isValid else {
                        throw ArchiveError.decryptionFailed(ArchiveError.unarchiveFailed)
                    }
                    
                    /// Now that we have confirmed access to the replacement database we need to
                    /// stop the current account from doing anything
                    DispatchQueue.main.async {
                        modalActivityIndicator.setMessage(
                            "Clearing current account data..."
                        )
                        
                        (UIApplication.shared.delegate as? AppDelegate)?.stopPollers()
                    }
                    
                    /// Need to shut everything down before the swap out the data to prevent crashes
                    dependencies[singleton: .jobRunner].stopAndClearPendingJobs()
                    dependencies.remove(cache: .libSession)
                    dependencies.mutate(cache: .libSessionNetwork) { $0.suspendNetworkAccess() }
                    dependencies[singleton: .storage].suspendDatabaseAccess()
                    try dependencies[singleton: .storage].closeDatabase()
                    LibSession.clearLoggers()
                    
                    let deleteEnumerator: FileManager.DirectoryEnumerator? = FileManager.default.enumerator(
                        at: URL(
                            fileURLWithPath: dependencies[singleton: .fileManager].appSharedDataDirectoryPath
                        ),
                        includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey]
                    )
                    let fileUrls: [URL] = (deleteEnumerator?.allObjects
                        .compactMap { $0 as? URL }
                        .filter { url -> Bool in
                            guard let resourceValues = try? url.resourceValues(forKeys: [.isHiddenKey]) else {
                                return true
                            }
                            
                            return (resourceValues.isHidden != true)
                        })
                        .defaulting(to: [])
                    try fileUrls.forEach { url in
                        /// The database `wal` and `shm` files might not exist anymore at this point
                        /// so we should only remove files which exist to prevent errors
                        guard FileManager.default.fileExists(atPath: url.path) else { return }
                        
                        try FileManager.default.removeItem(atPath: url.path)
                    }
                    
                    /// Current account data has been removed, we now need to copy over the
                    /// newly imported data
                    DispatchQueue.main.async {
                        modalActivityIndicator.setMessage(
                            "Moving imported data..."
                        )
                    }
                    
                    try paths.forEach { path in
                        /// Need to ensure the destination directry
                        let targetPath: String = [
                            dependencies[singleton: .fileManager].appSharedDataDirectoryPath,
                            path.replacingOccurrences(of: tmpUnencryptPath, with: "")
                        ].joined()  // Already has '/' after 'appSharedDataDirectoryPath'
                        
                        try FileManager.default.createDirectory(
                            atPath: URL(fileURLWithPath: targetPath)
                                .deletingLastPathComponent()
                                .path,
                            withIntermediateDirectories: true
                        )
                        try FileManager.default.moveItem(atPath: path, toPath: targetPath)
                    }
                    
                    /// All of the main files have been moved across, we now need to replace the current database key with
                    /// the one included in the backup
                    try dependencies[singleton: .storage].replaceDatabaseKey(path: encKeyPath, password: password)
                    
                    /// The import process has completed so we need to restart the app
                    DispatchQueue.main.async {
                        self?.transitionToScreen(
                            ConfirmationModal(
                                info: ConfirmationModal.Info(
                                    title: "Import Complete",
                                    body: .text("The import completed successfully, Session must be reopened in order to complete the process."),
                                    cancelTitle: "Exit",
                                    cancelStyle: .alert_text,
                                    onCancel: { _ in exit(0) }
                                )
                            ),
                            transitionType: .present
                        )
                    }
                }
                catch {
                    modalActivityIndicator.dismiss {
                        showError(error)
                    }
                }
            }
            
            self.transitionToScreen(viewController, transitionType: .present)
        }
        self.documentPickerResult = documentPickerResult
        
        // UIDocumentPickerModeImport copies to a temp file within our container.
        // It uses more memory than "open" but lets us avoid working with security scoped URLs.
        let documentPickerVC = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        documentPickerVC.delegate = documentPickerResult
        documentPickerVC.modalPresentationStyle = .fullScreen
        
        self.transitionToScreen(documentPickerVC, transitionType: .present)
    }
}

// MARK: - DocumentPickerResult

private class DocumentPickerResult: NSObject, UIDocumentPickerDelegate {
    private let onResult: (URL?) -> Void
    
    init(onResult: @escaping (URL?) -> Void) {
        self.onResult = onResult
    }
    
    // MARK: - UIDocumentPickerDelegate
    
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url: URL = urls.first else {
            self.onResult(nil)
            return
        }
        
        self.onResult(url)
    }
    
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        self.onResult(nil)
    }
}

// MARK: - PollLimitInputView

final class PollLimitInputView: UIView, UITextFieldDelegate, SessionCell.Accessory.CustomView {
    struct Info: Equatable, SessionCell.Accessory.CustomViewInfo {
        typealias View = PollLimitInputView
        
        let limit: Int
        let onChange: (Int?) -> Void
        
        public static func ==(lhs: Info, rhs: Info) -> Bool {
            return lhs.limit == rhs.limit
        }
        
        public func hash(into hasher: inout Hasher) {
            limit.hash(into: &hasher)
        }
    }
    
    static func create(maxContentWidth: CGFloat, using dependencies: Dependencies) -> PollLimitInputView {
        return PollLimitInputView()
    }
    
    public static let size: SessionCell.Accessory.Size = .fillWidthWrapHeight
    private var onChange: ((Int?) -> Void)?

    // MARK: - Components

    private lazy var textField: UITextField = {
        let result = UITextField()
        result.font = .systemFont(ofSize: Values.mediumFontSize)
        result.textAlignment = .center
        result.delegate = self

        return result
    }()

    // MARK: - Initializtion

    init() {
        super.init(frame: .zero)

        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("Use init(color:) instead")
    }

    // MARK: - Layout

    private func setupUI() {
        layer.borderWidth = 1
        layer.cornerRadius = 8
        themeBackgroundColor = .backgroundPrimary
        themeBorderColor = .borderSeparator
        
        addSubview(textField)
        textField.pin(to: self, withInset: Values.verySmallSpacing)
    }

    // MARK: - Content

    func update(with info: Info) {
        onChange = info.onChange
        textField.text = "\(info.limit)"
    }
    
    // MARK: - UITextFieldDelegate
    
    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        let currentText: String = (textField.text ?? "")
        
        guard let textRange: Range = Range(range, in: currentText) else { return false }
        
        let updatedText: String = currentText.replacingCharacters(in: textRange, with: string)
        
        // Allow an empty string (revert to the default in this case)
        guard !updatedText.isEmpty else {
            onChange?(nil)
            return true
        }
        guard let value: Int = Int(updatedText) else { return false }
        guard value >= 0 && value < 256 else { return false }
        
        onChange?(value)
        return true
    }
}

// MARK: - WarningVersion
struct WarningVersion: Listable {
    var version: Int
    
    var id: String { "\(version)" }
    var title: String { "iOS \(version)" }
}

// MARK: - Listable Conformance

extension ServiceNetwork: @retroactive ContentIdentifiable {}
extension ServiceNetwork: @retroactive ContentEquatable {}
extension ServiceNetwork: Listable {}
extension Network.PushNotification.Service: @retroactive ContentIdentifiable {}
extension Network.PushNotification.Service: @retroactive ContentEquatable {}
extension Network.PushNotification.Service: Listable {}
extension Log.Level: @retroactive ContentIdentifiable {}
extension Log.Level: @retroactive ContentEquatable {}
extension Log.Level: Listable {}
