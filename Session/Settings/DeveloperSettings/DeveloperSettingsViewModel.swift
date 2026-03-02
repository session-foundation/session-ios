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
        
        case networkConfig
        case resetSnodeCache
        case proConfig
        case groupConfig
        
        case customDateTime
        case fileServerConfig
        case modalsAndBanners
        case animationsEnabled
        case showStringKeys
        case truncatePubkeysInLogs
        case copyDocumentsPath
        case copyAppGroupPath
        case usePngInsteadOfWebPForFallbackImageType
        
        case defaultLogLevel
        case advancedLogging
        case loggingCategory(String)
        
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
                
                case .networkConfig: return "networkConfig"
                case .resetSnodeCache: return "resetSnodeCache"
                case .proConfig: return "proConfig"
                case .groupConfig: return "groupConfig"
                    
                case .customDateTime: return "customDateTime"
                case .fileServerConfig: return "fileServerConfig"
                case .modalsAndBanners: return "modalsAndBanners"
                case .animationsEnabled: return "animationsEnabled"
                case .showStringKeys: return "showStringKeys"
                case .truncatePubkeysInLogs: return "truncatePubkeysInLogs"
                case .copyDocumentsPath: return "copyDocumentsPath"
                case .copyAppGroupPath: return "copyAppGroupPath"
                case .usePngInsteadOfWebPForFallbackImageType: return "usePngInsteadOfWebPForFallbackImageType"
                
                case .defaultLogLevel: return "defaultLogLevel"
                case .advancedLogging: return "advancedLogging"
                case .loggingCategory(let categoryIdentifier): return "loggingCategory-\(categoryIdentifier)"
                
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
                
                case .networkConfig: result.append(.networkConfig); fallthrough
                case .resetSnodeCache: result.append(.resetSnodeCache); fallthrough
                case .proConfig: result.append(.proConfig); fallthrough
                case .groupConfig: result.append(.groupConfig); fallthrough
                    
                case .customDateTime: result.append(.customDateTime); fallthrough
                case .fileServerConfig: result.append(.fileServerConfig); fallthrough
                case .modalsAndBanners: result.append(.modalsAndBanners); fallthrough
                case .animationsEnabled: result.append(.animationsEnabled); fallthrough
                case .showStringKeys: result.append(.showStringKeys); fallthrough
                case .truncatePubkeysInLogs: result.append(.truncatePubkeysInLogs); fallthrough
                case .copyDocumentsPath: result.append(.copyDocumentsPath); fallthrough
                case .copyAppGroupPath: result.append(.copyAppGroupPath); fallthrough
                case .usePngInsteadOfWebPForFallbackImageType:
                    result.append(usePngInsteadOfWebPForFallbackImageType); fallthrough
                
                case .defaultLogLevel: result.append(.defaultLogLevel); fallthrough
                case .advancedLogging: result.append(.advancedLogging); fallthrough
                case .loggingCategory: result.append(.loggingCategory("")); fallthrough
                
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
        
        let customDateTime: TimeInterval?
        let shortenFileTTL: Bool
        let animationsEnabled: Bool
        let showStringKeys: Bool
        let truncatePubkeysInLogs: Bool
        
        let defaultLogLevel: Log.Level
        let advancedLogging: Bool
        let loggingCategories: [Log.Category: Log.Level]
        
        let debugDisappearingMessageDurations: Bool
        
        let communityPollLimit: Int
        
        let forceSlowDatabaseQueries: Bool
        
        let usePngInsteadOfWebPForFallbackImageType: Bool
    }
    
    let title: String = "Developer Settings"
    
    lazy var observation: TargetObservation = ObservationBuilderOld
        .refreshableData(self) { [weak self, dependencies] () -> State in
            let versionBlindedID: String? = {
                guard
                    !dependencies[cache: .general].ed25519SecretKey.isEmpty,
                    let blinded07KeyPair: KeyPair = dependencies[singleton: .crypto].generate(
                        .versionBlinded07KeyPair(
                            ed25519SecretKey: dependencies[cache: .general].ed25519SecretKey
                        )
                    )
                else {
                    return nil
                }
                return SessionId(.versionBlinded07, publicKey: blinded07KeyPair.publicKey).hexString
            }()
            
            let pushNotificationsEnabled: Bool = dependencies[defaults: .standard, key: .isUsingFullAPNs]
            
            return State(
                developerMode: dependencies.mutate(cache: .libSession) { cache in
                    cache.get(.developerModeEnabled)
                },
                versionBlindedID: versionBlindedID,
                customDateTime: dependencies[feature: .customDateTime],
                shortenFileTTL: dependencies[feature: .shortenFileTTL],
                animationsEnabled: dependencies[feature: .animationsEnabled],
                showStringKeys: dependencies[feature: .showStringKeys],
                truncatePubkeysInLogs: dependencies[feature: .truncatePubkeysInLogs],
                
                defaultLogLevel: dependencies[feature: .logLevel(cat: .default)],
                advancedLogging: (self?.showAdvancedLogging == true),
                loggingCategories: dependencies[feature: .allLogLevels].currentValues(using: dependencies),
                
                debugDisappearingMessageDurations: dependencies[feature: .debugDisappearingMessageDurations],
                
                communityPollLimit: dependencies[feature: .communityPollLimit],
                
                forceSlowDatabaseQueries: dependencies[feature: .forceSlowDatabaseQueries],
                usePngInsteadOfWebPForFallbackImageType: dependencies[feature: .usePngInsteadOfWebPForFallbackImageType]
            )
        }
        .compactMapWithPrevious { [weak self] prev, current -> [SectionModel]? in self?.content(prev, current) }
    
    private func content(_ previous: State?, _ current: State) -> [SectionModel] {
        let customDateTime: String = {
            let customDateTimestamp: TimeInterval = dependencies[feature: .customDateTime]
            
            return (customDateTimestamp > 0 ?
                "<span>\(Date(timeIntervalSince1970: customDateTimestamp).formattedForBanner)</span>" :
                "<disabled>None</disabled>"
            )
        }()
        
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
                        
                        Task { [weak self] in await self?.disableDeveloperMode() }
                    }
                )
            ]
        )
        let network: SectionModel = SectionModel(
            model: .network,
            elements: [
                SessionCell.Info(
                    id: .networkConfig,
                    title: "Network Configuration",
                    subtitle: """
                    Configure settings related to how and where network requests are sent.
                    
                    <b>Service Network:</b> <span>\(dependencies[feature: .serviceNetwork].title)</span>
                    <b>Router:</b> <span>\(dependencies[feature: .router].title)</span>
                    <b>PN Service:</b> <span>\(dependencies[feature: .pushNotificationService].title)</span>
                    """,
                    trailingAccessory: .icon(.chevronRight),
                    onTap: { [weak self, dependencies] in
                        self?.transitionToScreen(
                            SessionTableViewController(
                                viewModel: DeveloperSettingsNetworkViewModel(using: dependencies)
                            )
                        )
                    }
                ),
                SessionCell.Info(
                    id: .resetSnodeCache,
                    title: "Reset Service Node Cache",
                    subtitle: """
                    Reset and rebuild the service node cache and rebuild the paths.
                    """,
                    trailingAccessory: .highlightingBackgroundLabel(title: "Reset Cache"),
                    onTap: { [weak self] in self?.resetServiceNodeCache() }
                )
            ]
        )
        
        let sessionProStatus: String = (dependencies[feature: .sessionProEnabled] ? "Enabled" : "Disabled")
        let mockedProStatus: String = {
            switch (dependencies[feature: .sessionProEnabled], dependencies[feature: .mockCurrentUserSessionProBackendStatus]) {
                case (true, .simulate(let status)): return "<span>\(status)</span>"
                case (false, _), (_, .useActual): return "<disabled>None</disabled>"
            }
        }()
        let sessionPro: SectionModel = SectionModel(
            model: .sessionPro,
            elements: [
                SessionCell.Info(
                    id: .proConfig,
                    title: "Session Pro",
                    subtitle: """
                    Configure settings related to Session Pro.
                    
                    <b>Session Pro:</b> <span>\(sessionProStatus)</span>
                    <b>Mock Pro Status:</b> \(mockedProStatus)
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
                    id: .customDateTime,
                    title: "Custom Date/Time",
                    subtitle: """
                    Specify a custom date/time that the app should use.
                    
                    <b>Current Value:</b> \(devValue: dependencies[feature: .customDateTime])
                    
                    <b>Warning:</b>
                    Service nodes require the time to be within 2 minutes of their time so modifying this value will generally result in all network requests failing.
                    """,
                    trailingAccessory: .icon(.squarePen),
                    onTap: { [weak self, dependencies] in
                        DeveloperSettingsViewModel.showModalForMockableDate(
                            title: "Custom Date/Time",
                            explanation: "The custom date/time to use throughout the app.",
                            feature: .customDateTime,
                            navigatableStateHolder: self,
                            onValueChanged: { _ in self?.forceRefresh(type: .databaseQuery) },
                            using: dependencies
                        )
                    }
                ),
                SessionCell.Info(
                    id: .fileServerConfig,
                    title: "File Server Configuration",
                    subtitle: """
                    Configure settings related to the File Server.
                    
                    <b>File TTL:</b> <span>\(dependencies[feature: .shortenFileTTL] ? "60 Seconds" : "14 Days")</span>
                    <b>Stream Encryption:</b> <span>\(dependencies[feature: .useStreamEncryptionForAttachments] ? "Enabled" : "Disabled")</span>
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
                    id: .modalsAndBanners,
                    title: "Modal and Banner Settings",
                    subtitle: """
                    Configure settings related to the modals and banners.
                    """,
                    trailingAccessory: .icon(.chevronRight),
                    onTap: { [weak self, dependencies] in
                        self?.transitionToScreen(
                            SessionTableViewController(
                                viewModel: DeveloperSettingsModalsAndBannersViewModel(using: dependencies)
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
                    
                    <b>Current Value:</b> \(devValue: dependencies[feature: .communityPollLimit])
                    
                    <b>Note:</b> An empty value, or a value of 0 will use the default value: \(dependencies.defaultValue(feature: .communityPollLimit).map { "\($0)"} ?? "N/A").
                    """,
                    trailingAccessory: .icon(.squarePen),
                    onTap: { [weak self, dependencies] in
                        DeveloperSettingsViewModel.showModalForMockableNumber(
                            title: "Comunity Poll Limit",
                            explanation: "The number of messages to try to retrieve when polling a community (up to a maximum of 256).",
                            feature: .communityPollLimit,
                            minValue: 0,
                            maxValue: 256,
                            navigatableStateHolder: self,
                            onValueChanged: { _ in self?.forceRefresh(type: .databaseQuery) },
                            using: dependencies
                        )
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
            network,
            sessionPro,
            groups,
            general,
            logging,
            disappearingMessages,
            communities,
            sessionNetwork,
            database
        ]
    }
    
    // MARK: - Functions
    
    private func disableDeveloperMode() async {
        /// Loop through all of the sections and reset the features back to default for each one as needed (this way if a new section is added
        /// then we will get a compile error if it doesn't get resetting instructions added)
        for item in TableItem.allCases {
            switch item {
                case .developerMode, .versionBlindedID, .customDateTime, .scheduleLocalNotification,
                    .copyDocumentsPath, .copyAppGroupPath, .resetSnodeCache, .createMockContacts,
                    .exportDatabase, .importDatabase, .advancedLogging:
                    break   /// These are actions rather than values stored as "features" so no need to do anything
                    
                case .networkConfig:
                    await DeveloperSettingsNetworkViewModel.disableDeveloperMode(using: dependencies)
                    
                case .groupConfig: DeveloperSettingsGroupsViewModel.disableDeveloperMode(using: dependencies)
                case .proConfig: DeveloperSettingsProViewModel.disableDeveloperMode(using: dependencies)
                
                case .fileServerConfig:
                    DeveloperSettingsFileServerViewModel.disableDeveloperMode(using: dependencies)
                case .modalsAndBanners:
                    DeveloperSettingsModalsAndBannersViewModel.disableDeveloperMode(using: dependencies)
                    
                case .animationsEnabled:
                    guard dependencies.hasSet(feature: .animationsEnabled) else { break }
                    
                    updateFlag(for: .animationsEnabled, to: nil)
                    
                case .showStringKeys:
                    guard dependencies.hasSet(feature: .showStringKeys) else { break }
                    
                    updateFlag(for: .showStringKeys, to: nil)
                    
                case .truncatePubkeysInLogs:
                    guard dependencies.hasSet(feature: .truncatePubkeysInLogs) else { break }
                    
                    updateFlag(for: .truncatePubkeysInLogs, to: nil)
                    
                case .usePngInsteadOfWebPForFallbackImageType:
                    guard dependencies.hasSet(feature: .usePngInsteadOfWebPForFallbackImageType) else {
                        break
                    }
                    
                    updateFlag(for: .usePngInsteadOfWebPForFallbackImageType, to: nil)
                    
                case .defaultLogLevel: updateDefaulLogLevel(to: nil)    // Always reset
                case .loggingCategory: resetLoggingCategories()         // Always reset
                
                case .debugDisappearingMessageDurations:
                    guard dependencies.hasSet(feature: .debugDisappearingMessageDurations) else { break }
                    
                    updateFlag(for: .debugDisappearingMessageDurations, to: nil)                
                    
                case .communityPollLimit:
                    guard dependencies.hasSet(feature: .communityPollLimit) else { break }
                    
                    dependencies.reset(feature: .communityPollLimit)
                    forceRefresh(type: .databaseQuery)
                    
                case .forceSlowDatabaseQueries:
                    guard dependencies.hasSet(feature: .forceSlowDatabaseQueries) else { break }
                    
                    updateFlag(for: .forceSlowDatabaseQueries, to: nil)
            }
        }
        
        /// Disable developer mode
        dependencies.setAsync(.developerModeEnabled, false)
        self.dismissScreen(type: .pop)
    }

    private func updateDefaulLogLevel(to updatedDefaultLogLevel: Log.Level?) {
        Log.setDefaultLogLevel(updatedDefaultLogLevel)
        forceRefresh(type: .databaseQuery)
    }
    
    private func setAdvancedLoggingVisibility(to value: Bool) {
        self.showAdvancedLogging = value
        forceRefresh(type: .databaseQuery)
    }
    
    private func updateLogLevel(of category: Log.Category, to level: Log.Level) {
        Log.setLogLevel(level, for: category)
        forceRefresh(type: .databaseQuery)
    }
    
    private func resetLoggingCategories() {
        Log.resetAllLogLevelsToDefaults()
        forceRefresh(type: .databaseQuery)
    }
    
    private func updateFlag(for feature: FeatureConfig<Bool>, to updatedFlag: Bool?) {
        /// Update to the new flag
        switch updatedFlag {
            case .some(let value): dependencies.set(feature: feature, to: value)
            case .none: dependencies.reset(feature: feature)
        }
        
        forceRefresh(type: .databaseQuery)
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
                        /// Clear the snode cache
                        Task { await dependencies[singleton: .network].clearCache() }
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
                                let timestampMs: Double = dependencies.networkOffsetTimestampMs()
                                let currentUserSessionId: SessionId = dependencies[cache: .general].sessionId
                                
                                Task(priority: .userInitiated) { [weak self] in
                                    try? await dependencies[singleton: .storage].writeAsync { db in
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
                                            _ = try Profile.with(
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
                                    }
                                    
                                    await MainActor.run { [weak self] in
                                        indicator.dismiss {
                                            self?.showToast(
                                                text: "Contacts Created",
                                                backgroundColor: .backgroundSecondary
                                            )
                                        }
                                    }
                                }
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
        
        let indicator: ModalActivityIndicatorViewController = ModalActivityIndicatorViewController(canCancel: false)
        self.transitionToScreen(indicator, transitionType: .present)
        
        Task.detached(priority: .userInitiated) { [weak self, databaseKeyEncryptionPassword, dependencies] in
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
                            indicator.setMessage([
                                "Exporting file: \(fileIndex)/\(totalFiles)",
                                "File encryption progress: \(percentage)%"
                            ].compactMap { $0 }.joined(separator: "\n"))
                        }
                    }
                )
            }
            catch {
                await MainActor.run {
                    indicator.dismiss {
                        showError(error)
                    }
                }
                return
            }
            
            await MainActor.run { [weak self] in
                indicator.dismiss { [weak self] in
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
        }
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
        
        guard databaseKeyEncryptionPassword.count >= 6 else {
            return showError(CryptoKitError.incorrectKeySize)
        }
        
        let documentPickerResult: DocumentPickerResult = DocumentPickerResult { [weak self, password = self.databaseKeyEncryptionPassword, dependencies] url in
            guard let url: URL = url else { return }
            
            Task.detached(priority: .userInitiated) { [weak self] in
                let indicator: ModalActivityIndicatorViewController = await MainActor.run { [weak self] in
                    let indicator: ModalActivityIndicatorViewController = ModalActivityIndicatorViewController(canCancel: false)
                    self?.transitionToScreen(indicator, transitionType: .present)
                    
                    return indicator
                }
                
                do {
                    let tmpUnencryptPath: String = "\(dependencies[singleton: .fileManager].temporaryDirectory)/new_session.bak"
                    let (paths, additionalFilePaths): ([String], [String]) = try DirectoryArchiver
                        .unarchiveDirectory(
                            archivePath: url.path,
                            destinationPath: tmpUnencryptPath,
                            password: password,
                            progressChanged: { [weak indicator] filesSaved, totalFiles, fileProgress, fileSize in
                                let percentage: Int = {
                                    guard fileSize > 0 else { return 0 }
                                    
                                    return Int((Double(fileProgress) / Double(fileSize)) * 100)
                                }()
                                
                                DispatchQueue.main.async { [weak indicator] in
                                    indicator?.setMessage([
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
                    
                    await MainActor.run { [weak indicator] in
                        indicator?.setMessage("Checking for valid database...")
                    }
                    
                    let testStorage: Storage = try Storage(
                        testAccessTo: databasePath,
                        encryptedKeyPath: encKeyPath,
                        encryptedKeyPassword: password,
                        using: dependencies
                    )
                    
                    guard testStorage.hasValidDatabaseConnection else {
                        throw ArchiveError.decryptionFailed(ArchiveError.unarchiveFailed)
                    }
                        
                    /// Now that we have confirmed access to the replacement database we need to
                    /// stop the current account from doing anything
                    await MainActor.run { [weak indicator] in
                        indicator?.setMessage("Clearing current account data...")
                    }
                    await (UIApplication.shared.delegate as? AppDelegate)?.stopPollers()
                        
                    /// Need to shut everything down before the swap out the data to prevent crashes
                    await dependencies[singleton: .jobRunner].stopAndClearJobs()
                    dependencies.remove(cache: .libSession)
                    await dependencies[singleton: .network].suspendNetworkAccess()
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
                    await MainActor.run { [weak indicator] in
                        indicator?.setMessage("Moving imported data...")
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
                    await MainActor.run { [weak self] in
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
                    await MainActor.run { [weak indicator] in
                        indicator?.dismiss {
                            showError(error)
                        }
                    }
                }
            }
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

// MARK: - Convenience

extension DeveloperSettingsViewModel {
    static func showModalForMockableNumber(
        title: String,
        explanation: String,
        feature: FeatureConfig<Int>,
        minValue: Int = Int.min,
        maxValue: Int = Int.max,
        defaultValue: Int? = nil,
        navigatableStateHolder: NavigatableStateHolder?,
        onValueChanged: ((Int?) -> Void)? = nil,
        using dependencies: Dependencies?
    ) {
        guard let dependencies: Dependencies = dependencies else { return }
        
        showModalForMockableNumber(
            title: title,
            explanation: explanation,
            minValue: minValue,
            maxValue: maxValue,
            initialValue: dependencies[feature: feature],
            defaultValue: defaultValue,
            hasSet: dependencies.hasSet(feature: feature),
            navigatableStateHolder: navigatableStateHolder,
            onValueChanged: { newValue in
                switch newValue {
                    case .some(let value): dependencies.set(feature: feature, to: value)
                    case .none: dependencies.reset(feature: feature)
                }
                
                onValueChanged?(newValue)
            }
        )
    }
    
    static func showModalForMockableNumber(
        title: String,
        explanation: String,
        defaults: UserDefaultsConfig,
        key: UserDefaults.IntKey,
        minValue: Int = Int.min,
        maxValue: Int = Int.max,
        defaultValue: Int? = nil,
        navigatableStateHolder: NavigatableStateHolder?,
        onValueChanged: ((Int?) -> Void)? = nil,
        using dependencies: Dependencies?
    ) {
        guard let dependencies: Dependencies = dependencies else { return }
        
        showModalForMockableNumber(
            title: title,
            explanation: explanation,
            minValue: minValue,
            maxValue: maxValue,
            initialValue: dependencies[defaults: defaults, key: key],
            defaultValue: defaultValue,
            hasSet: (dependencies[defaults: defaults].object(forKey: key.rawValue) != nil),
            navigatableStateHolder: navigatableStateHolder,
            onValueChanged: { newValue in
                if let value: Int = newValue {
                    dependencies[defaults: defaults, key: key] = value
                }
                else {
                    dependencies[defaults: defaults].removeObject(forKey: key.rawValue)
                }
                
                onValueChanged?(newValue)
            }
        )
    }
    
    static func showModalForMockableDate(
        title: String,
        explanation: String,
        feature: FeatureConfig<TimeInterval>,
        navigatableStateHolder: NavigatableStateHolder?,
        onValueChanged: ((TimeInterval?) -> Void)? = nil,
        using dependencies: Dependencies?
    ) {
        guard let dependencies: Dependencies = dependencies else { return }
        
        showModalForMockableDate(
            title: title,
            explanation: explanation,
            initialValue: dependencies[feature: feature],
            hasSet: dependencies.hasSet(feature: feature),
            navigatableStateHolder: navigatableStateHolder,
            onValueChanged: { newValue in
                switch newValue {
                    case .some(let value): dependencies.set(feature: feature, to: value)
                    case .none: dependencies.reset(feature: feature)
                }
                
                onValueChanged?(newValue)
            }
        )
    }
    
    static func showModalForMockableDate(
        title: String,
        explanation: String,
        defaults: UserDefaultsConfig,
        key: UserDefaults.DoubleKey,
        navigatableStateHolder: NavigatableStateHolder?,
        onValueChanged: ((TimeInterval?) -> Void)? = nil,
        using dependencies: Dependencies?
    ) {
        guard let dependencies: Dependencies = dependencies else { return }
        
        showModalForMockableDate(
            title: title,
            explanation: explanation,
            initialValue: dependencies[defaults: defaults, key: key],
            hasSet: (dependencies[defaults: defaults].object(forKey: key.rawValue) != nil),
            navigatableStateHolder: navigatableStateHolder,
            onValueChanged: { newValue in
                if let value: TimeInterval = newValue {
                    dependencies[defaults: defaults, key: key] = value
                }
                else {
                    dependencies[defaults: defaults].removeObject(forKey: key.rawValue)
                }
                
                onValueChanged?(newValue)
            }
        )
    }
    
    // MARK: - Actual modals
    
    private static func showModalForMockableNumber(
        title: String,
        explanation: String,
        minValue: Int,
        maxValue: Int,
        initialValue: Int?,
        defaultValue: Int?,
        hasSet: Bool,
        navigatableStateHolder: NavigatableStateHolder?,
        onValueChanged: @escaping ((Int?) -> Void)
    ) {
        var updatedValue: String? = nil
        let range: String? = {
            switch (minValue, maxValue) {
                case (Int.min, Int.max): return nil
                case (0, Int.max): return "0 or higher"
                default: return "\(minValue) - \(maxValue)"
            }
        }()
        
        navigatableStateHolder?.transitionToScreen(
            ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: title,
                    body: .input(
                        explanation: ThemedAttributedString(string: explanation),
                        info: ConfirmationModal.Info.Body.InputInfo(
                            placeholder: (
                                range.map { "Enter Value (\($0))" } ??
                                "Enter Value"
                            ),
                            initialValue: (initialValue.map { "\($0)" } ?? ""),
                            keyboardType: .numberPad
                        ),
                        onChange: { value in updatedValue = value }
                    ),
                    confirmTitle: "save".localized(),
                    confirmEnabled: .afterChange { _ in
                        guard
                            let stringValue: String = updatedValue,
                            let value: Int = Int(stringValue),
                            value >= minValue &&
                            value <= maxValue
                        else { return false }
                        
                        return true
                    },
                    cancelTitle: (defaultValue != nil && hasSet ?
                        "remove".localized() :
                        "cancel".localized()
                    ),
                    cancelStyle: (defaultValue != nil && hasSet ? .danger : .alert_text),
                    hasCloseButton: hasSet,
                    dismissOnConfirm: false,
                    onConfirm: { modal in
                        guard
                            let stringValue: String = updatedValue,
                            let value: Int = Int(stringValue),
                            value >= minValue &&
                            value <= maxValue
                        else {
                            modal.updateContent(
                                withError: (
                                    range.map { "Value must be a number in the range \($0)" } ??
                                    "Value must be a number"
                                )
                            )
                            return
                        }
                        
                        modal.dismiss(animated: true)
                        onValueChanged(value)
                    },
                    onCancel: { modal in
                        modal.dismiss(animated: true)
                        
                        guard defaultValue != nil && hasSet else { return }
                        
                        onValueChanged(defaultValue)
                    }
                )
            ),
            transitionType: .present
        )
    }
    
    private static func showModalForMockableDate(
        title: String,
        explanation: String,
        initialValue: TimeInterval?,
        hasSet: Bool,
        navigatableStateHolder: NavigatableStateHolder?,
        onValueChanged: ((TimeInterval?) -> Void)? = nil
    ) {
        var updatedValue: String? = nil
        let dateFormat: String = "HH:mm dd/MM/yyyy"
        let formatter: DateFormatter = DateFormatter()
        formatter.dateFormat = dateFormat
        let targetInitialValue: String = {
            let value: TimeInterval = (initialValue ?? 0)
            
            guard value > 0 else { return "" }
            
            return formatter.string(from: Date(timeIntervalSince1970: value))
        }()
        
        navigatableStateHolder?.transitionToScreen(
            ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: title,
                    body: .input(
                        explanation: ThemedAttributedString(string: explanation),
                        info: ConfirmationModal.Info.Body.InputInfo(
                            placeholder: "Enter Date/Time (\(dateFormat))",
                            initialValue: targetInitialValue
                        ),
                        onChange: { value in updatedValue = value }
                    ),
                    confirmTitle: "save".localized(),
                    confirmEnabled: .afterChange { _ in
                        guard
                            let value: String = updatedValue,
                            formatter.date(from: value) != nil
                        else { return false }
                        
                        return true
                    },
                    cancelTitle: (hasSet ?
                        "remove".localized() :
                        "cancel".localized()
                    ),
                    cancelStyle: (hasSet ? .danger : .alert_text),
                    hasCloseButton: hasSet,
                    dismissOnConfirm: false,
                    onConfirm: { modal in
                        guard
                            let value: String = updatedValue,
                            let date: Date = formatter.date(from: value)
                        else {
                            modal.updateContent(
                                withError: "Value must be in the format '\(dateFormat)'."
                            )
                            return
                        }
                        
                        modal.dismiss(animated: true)
                        onValueChanged?(date.timeIntervalSince1970)
                    },
                    onCancel: { modal in
                        modal.dismiss(animated: true)
                        
                        guard hasSet else { return }
                        
                        onValueChanged?(nil)
                    }
                )
            ),
            transitionType: .present
        )
    }
    
    static func showModalForMockableState<M>(
        title: String,
        explanation: String,
        feature: FeatureConfig<MockableFeature<M>>,
        currentValue: MockableFeature<M>,
        navigatableStateHolder: NavigatableStateHolder?,
        onMockingRemoved: (() -> Void)? = nil,
        using dependencies: Dependencies?
    ) {
        let allCases: [MockableFeature<M>] = MockableFeature<M>.allCases
    
        navigatableStateHolder?.transitionToScreen(
            ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: title,
                    body: .radio(
                        explanation: ThemedAttributedString(string: explanation),
                        warning: nil,
                        options: {
                            return allCases.enumerated().map { index, feature in
                                ConfirmationModal.Info.Body.RadioOptionInfo(
                                    title: feature.title,
                                    descriptionText: feature.subtitle.map {
                                        ThemedAttributedString(
                                            stringWithHTMLTags: $0,
                                            font: RadioButton.descriptionFont
                                        )
                                    },
                                    enabled: true,
                                    selected: currentValue == feature
                                )
                            }
                        }()
                    ),
                    confirmTitle: "select".localized(),
                    cancelStyle: .alert_text,
                    onConfirm: { [dependencies] modal in
                        let selectedValue: MockableFeature<M>? = {
                            switch modal.info.body {
                                case .radio(_, _, let options):
                                    return options
                                        .enumerated()
                                        .first(where: { _, value in value.selected })
                                        .map { index, _ in
                                            guard index >= 0 && index < allCases.count else {
                                                return nil
                                            }
                                            
                                            return allCases[index]
                                        }
                                
                                default: return nil
                            }
                        }()
                        
                        let finalValue: MockableFeature<M> = (selectedValue ?? .useActual)
                        
                        switch finalValue {
                            case .useActual:
                                dependencies?.reset(feature: feature)
                                onMockingRemoved?()
                                
                            case .simulate: dependencies?.set(feature: feature, to: finalValue)
                        }
                    }
                )
            ),
            transitionType: .present
        )
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

// MARK: - Format Convenience

internal extension String.StringInterpolation {
    mutating func appendInterpolation(devValue: TimeInterval?) {
        guard let value: TimeInterval = devValue, value > 0 else { return appendLiteral("<disabled>None</disabled>") }
        
        appendLiteral("<span>\(Date(timeIntervalSince1970: value).formattedForBanner)</span>")
    }
    
    mutating func appendInterpolation(devValue: Int?) {
        guard let value: Int = devValue else { return appendLiteral("<disabled>None</disabled>") }
        
        appendLiteral("<span>\(value)</span>")
    }
}

// MARK: - Format Convenience

internal extension String.StringInterpolation {
    mutating func appendInterpolation<T: CustomStringConvertible>(devValue: MockableFeature<T>) {
        switch devValue {
            case .useActual: appendLiteral("<disabled>None</disabled>")
            case .simulate(let value): appendLiteral("<span>\(value)</span>")
        }
    }
}

// MARK: - WarningVersion

struct WarningVersion: Listable {
    var version: Int
    
    var id: String { "\(version)" }
    var title: String { "iOS \(version)" }
}

// MARK: - Listable Conformance

extension Log.Level: @retroactive ContentIdentifiable {}
extension Log.Level: @retroactive ContentEquatable {}
extension Log.Level: Listable {}
