// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import GRDB
import DifferenceKit
import SessionUIKit
import SessionNetworkingKit
import SessionMessagingKit
import SessionUtilitiesKit

class DeveloperSettingsGroupsViewModel: SessionTableViewModel, NavigatableStateHolder, ObservableTableSource {
    public let dependencies: Dependencies
    public let navigatableState: NavigatableState = NavigatableState()
    public let state: TableDataState<Section, TableItem> = TableDataState()
    public let observableState: ObservableTableSourceState<Section, TableItem> = ObservableTableSourceState()
    
    /// This value is the current state of the view
    @MainActor @Published private(set) var internalState: State
    private var observationTask: Task<Void, Never>?
    
    // MARK: - Initialization
    
    @MainActor init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.internalState = State.initialState(using: dependencies)
        
        /// Bind the state
        self.observationTask = ObservationBuilder
            .initialValue(self.internalState)
            .debounce(for: .never)
            .using(dependencies: dependencies)
            .query(DeveloperSettingsGroupsViewModel.queryState)
            .assign { [weak self] updatedState in
                guard let self = self else { return }
                
                // FIXME: To slightly reduce the size of the changes this new observation mechanism is currently wired into the old SessionTableViewController observation mechanism, we should refactor it so everything uses the new mechanism
                let oldState: State = self.internalState
                self.internalState = updatedState
                self.pendingTableDataSubject.send(updatedState.sections(viewModel: self, previousState: oldState))
            }
    }
    
    // MARK: - Config
    
    public enum Section: SessionTableSection {
        case general
        
        var title: String? {
            switch self {
                case .general: return nil
            }
        }
        
        var style: SessionTableSectionStyle {
            switch self {
                case .general: return .padding
            }
        }
    }
    
    public enum TableItem: Hashable, Differentiable, CaseIterable {
        case groupsShowPubkeyInConversationSettings
        case updatedGroupsDisableAutoApprove
        case updatedGroupsRemoveMessagesOnKick
        case updatedGroupsAllowHistoricAccessOnInvite
        case updatedGroupsAllowDisplayPicture
        case updatedGroupsAllowDescriptionEditing
        case updatedGroupsAllowPromotions
        case updatedGroupsAllowInviteById
        case updatedGroupsDeleteBeforeNow
        case updatedGroupsDeleteAttachmentsBeforeNow
        
        // MARK: - Conformance
        
        public typealias DifferenceIdentifier = String
        
        public var differenceIdentifier: String {
            switch self {
                case .groupsShowPubkeyInConversationSettings: return "groupsShowPubkeyInConversationSettings"
                case .updatedGroupsDisableAutoApprove: return "updatedGroupsDisableAutoApprove"
                case .updatedGroupsRemoveMessagesOnKick: return "updatedGroupsRemoveMessagesOnKick"
                case .updatedGroupsAllowHistoricAccessOnInvite: return "updatedGroupsAllowHistoricAccessOnInvite"
                case .updatedGroupsAllowDisplayPicture: return "updatedGroupsAllowDisplayPicture"
                case .updatedGroupsAllowDescriptionEditing: return "updatedGroupsAllowDescriptionEditing"
                case .updatedGroupsAllowPromotions: return "updatedGroupsAllowPromotions"
                case .updatedGroupsAllowInviteById: return "updatedGroupsAllowInviteById"
                case .updatedGroupsDeleteBeforeNow: return "updatedGroupsDeleteBeforeNow"
                case .updatedGroupsDeleteAttachmentsBeforeNow: return "updatedGroupsDeleteAttachmentsBeforeNow"
            }
        }
        
        public func isContentEqual(to source: TableItem) -> Bool {
            self.differenceIdentifier == source.differenceIdentifier
        }
        
        public static var allCases: [TableItem] {
            var result: [TableItem] = []
            switch TableItem.groupsShowPubkeyInConversationSettings {
                case .groupsShowPubkeyInConversationSettings: result.append(groupsShowPubkeyInConversationSettings); fallthrough
                case .updatedGroupsDisableAutoApprove: result.append(.updatedGroupsDisableAutoApprove); fallthrough
                case .updatedGroupsRemoveMessagesOnKick: result.append(.updatedGroupsRemoveMessagesOnKick); fallthrough
                case .updatedGroupsAllowHistoricAccessOnInvite:
                    result.append(.updatedGroupsAllowHistoricAccessOnInvite); fallthrough
                case .updatedGroupsAllowDisplayPicture: result.append(.updatedGroupsAllowDisplayPicture); fallthrough
                case .updatedGroupsAllowDescriptionEditing: result.append(.updatedGroupsAllowDescriptionEditing); fallthrough
                case .updatedGroupsAllowPromotions: result.append(.updatedGroupsAllowPromotions); fallthrough
                case .updatedGroupsAllowInviteById: result.append(.updatedGroupsAllowInviteById); fallthrough
                case .updatedGroupsDeleteBeforeNow: result.append(.updatedGroupsDeleteBeforeNow); fallthrough
                case .updatedGroupsDeleteAttachmentsBeforeNow: result.append(.updatedGroupsDeleteAttachmentsBeforeNow)
            }
            
            return result
        }
    }
    
    // MARK: - Content
    
    public struct State: Equatable, ObservableKeyProvider {
        let groupsShowPubkeyInConversationSettings: Bool
        let updatedGroupsDisableAutoApprove: Bool
        let updatedGroupsRemoveMessagesOnKick: Bool
        let updatedGroupsAllowHistoricAccessOnInvite: Bool
        let updatedGroupsAllowDisplayPicture: Bool
        let updatedGroupsAllowDescriptionEditing: Bool
        let updatedGroupsAllowPromotions: Bool
        let updatedGroupsAllowInviteById: Bool
        let updatedGroupsDeleteBeforeNow: Bool
        let updatedGroupsDeleteAttachmentsBeforeNow: Bool
        
        @MainActor public func sections(viewModel: DeveloperSettingsGroupsViewModel, previousState: State) -> [SectionModel] {
            DeveloperSettingsGroupsViewModel.sections(
                state: self,
                previousState: previousState,
                viewModel: viewModel
            )
        }
        
        public let observedKeys: Set<ObservableKey> = [
            .feature(.groupsShowPubkeyInConversationSettings),
            .feature(.updatedGroupsDisableAutoApprove),
            .feature(.updatedGroupsRemoveMessagesOnKick),
            .feature(.updatedGroupsAllowHistoricAccessOnInvite),
            .feature(.updatedGroupsAllowDisplayPicture),
            .feature(.updatedGroupsAllowDescriptionEditing),
            .feature(.updatedGroupsAllowPromotions),
            .feature(.updatedGroupsAllowInviteById),
            .feature(.updatedGroupsDeleteBeforeNow),
            .feature(.updatedGroupsDeleteAttachmentsBeforeNow)
        ]
        
        static func initialState(using dependencies: Dependencies) -> State {
            return State(
                groupsShowPubkeyInConversationSettings: dependencies[feature: .groupsShowPubkeyInConversationSettings],
                updatedGroupsDisableAutoApprove: dependencies[feature: .updatedGroupsDisableAutoApprove],
                updatedGroupsRemoveMessagesOnKick: dependencies[feature: .updatedGroupsRemoveMessagesOnKick],
                updatedGroupsAllowHistoricAccessOnInvite: dependencies[feature: .updatedGroupsAllowHistoricAccessOnInvite],
                updatedGroupsAllowDisplayPicture: dependencies[feature: .updatedGroupsAllowDisplayPicture],
                updatedGroupsAllowDescriptionEditing: dependencies[feature: .updatedGroupsAllowDescriptionEditing],
                updatedGroupsAllowPromotions: dependencies[feature: .updatedGroupsAllowPromotions],
                updatedGroupsAllowInviteById: dependencies[feature: .updatedGroupsAllowInviteById],
                updatedGroupsDeleteBeforeNow: dependencies[feature: .updatedGroupsDeleteBeforeNow],
                updatedGroupsDeleteAttachmentsBeforeNow: dependencies[feature: .updatedGroupsDeleteAttachmentsBeforeNow]
            )
        }
    }
    
    let title: String = "Developer Group Settings"
    
    @Sendable private static func queryState(
        previousState: State,
        events: [ObservedEvent],
        isInitialQuery: Bool,
        using dependencies: Dependencies
    ) async -> State {
        return State(
            groupsShowPubkeyInConversationSettings: dependencies[feature: .groupsShowPubkeyInConversationSettings],
            updatedGroupsDisableAutoApprove: dependencies[feature: .updatedGroupsDisableAutoApprove],
            updatedGroupsRemoveMessagesOnKick: dependencies[feature: .updatedGroupsRemoveMessagesOnKick],
            updatedGroupsAllowHistoricAccessOnInvite: dependencies[feature: .updatedGroupsAllowHistoricAccessOnInvite],
            updatedGroupsAllowDisplayPicture: dependencies[feature: .updatedGroupsAllowDisplayPicture],
            updatedGroupsAllowDescriptionEditing: dependencies[feature: .updatedGroupsAllowDescriptionEditing],
            updatedGroupsAllowPromotions: dependencies[feature: .updatedGroupsAllowPromotions],
            updatedGroupsAllowInviteById: dependencies[feature: .updatedGroupsAllowInviteById],
            updatedGroupsDeleteBeforeNow: dependencies[feature: .updatedGroupsDeleteBeforeNow],
            updatedGroupsDeleteAttachmentsBeforeNow: dependencies[feature: .updatedGroupsDeleteAttachmentsBeforeNow]
        )
    }
    
    private static func sections(
        state: State,
        previousState: State,
        viewModel: DeveloperSettingsGroupsViewModel
    ) -> [SectionModel] {
        let general: SectionModel = SectionModel(
            model: .general,
            elements: [
                SessionCell.Info(
                    id: .groupsShowPubkeyInConversationSettings,
                    title: "Show Group Pubkey in Conversation Settings",
                    subtitle: """
                    Makes the group identity public key appear in the conversation settings screen.
                    """,
                    trailingAccessory: .toggle(
                        state.groupsShowPubkeyInConversationSettings,
                        oldValue: previousState.groupsShowPubkeyInConversationSettings
                    ),
                    onTap: { [dependencies = viewModel.dependencies] in
                        dependencies.set(
                            feature: .groupsShowPubkeyInConversationSettings,
                            to: !state.groupsShowPubkeyInConversationSettings
                        )
                    }
                ),
                SessionCell.Info(
                    id: .updatedGroupsDisableAutoApprove,
                    title: "Disable Auto Approve",
                    subtitle: """
                    Prevents a group from automatically getting approved if the admin is already approved.
                    
                    <b>Note:</b> The default behaviour is to automatically approve new groups if the admin that sent the invitation is an approved contact.
                    """,
                    trailingAccessory: .toggle(
                        state.updatedGroupsDisableAutoApprove,
                        oldValue: previousState.updatedGroupsDisableAutoApprove
                    ),
                    onTap: { [dependencies = viewModel.dependencies] in
                        dependencies.set(
                            feature: .updatedGroupsDisableAutoApprove,
                            to: !state.updatedGroupsDisableAutoApprove
                        )
                    }
                ),
                SessionCell.Info(
                    id: .updatedGroupsRemoveMessagesOnKick,
                    title: "Remove Messages on Kick",
                    subtitle: """
                    Controls whether a group members messages should be removed when they are kicked from an updated group.
                    
                    <b>Note:</b> In a future release we will offer this as an option when removing members but for the initial release it can be controlled via this flag for testing purposes.
                    """,
                    trailingAccessory: .toggle(
                        state.updatedGroupsRemoveMessagesOnKick,
                        oldValue: previousState.updatedGroupsRemoveMessagesOnKick
                    ),
                    onTap: { [dependencies = viewModel.dependencies] in
                        dependencies.set(
                            feature: .updatedGroupsRemoveMessagesOnKick,
                            to: !state.updatedGroupsRemoveMessagesOnKick
                        )
                    }
                ),
                SessionCell.Info(
                    id: .updatedGroupsAllowHistoricAccessOnInvite,
                    title: "Allow Historic Message Access",
                    subtitle: """
                    Controls whether members should be granted access to historic messages when invited to an updated group.
                    
                    <b>Note:</b> In a future release we will offer this as an option when inviting members but for the initial release it can be controlled via this flag for testing purposes.
                    """,
                    trailingAccessory: .toggle(
                        state.updatedGroupsAllowHistoricAccessOnInvite,
                        oldValue: previousState.updatedGroupsAllowHistoricAccessOnInvite
                    ),
                    onTap: { [dependencies = viewModel.dependencies] in
                        dependencies.set(
                            feature: .updatedGroupsAllowHistoricAccessOnInvite,
                            to: !state.updatedGroupsAllowHistoricAccessOnInvite
                        )
                    }
                ),
                SessionCell.Info(
                    id: .updatedGroupsAllowDisplayPicture,
                    title: "Custom Display Pictures",
                    subtitle: """
                    Controls whether the UI allows group admins to set a custom display picture for a group.
                    
                    <b>Note:</b> In a future release we will offer this functionality but for the initial release it may not be fully supported across platforms so can be controlled via this flag for testing purposes.
                    """,
                    trailingAccessory: .toggle(
                        state.updatedGroupsAllowDisplayPicture,
                        oldValue: previousState.updatedGroupsAllowDisplayPicture
                    ),
                    onTap: { [dependencies = viewModel.dependencies] in
                        dependencies.set(
                            feature: .updatedGroupsAllowDisplayPicture,
                            to: !state.updatedGroupsAllowDisplayPicture
                        )
                    }
                ),
                SessionCell.Info(
                    id: .updatedGroupsAllowDescriptionEditing,
                    title: "Edit Group Descriptions",
                    subtitle: """
                    Controls whether the UI allows group admins to modify the descriptions of updated groups.
                    
                    <b>Note:</b> In a future release we will offer this functionality but for the initial release it may not be fully supported across platforms so can be controlled via this flag for testing purposes.
                    """,
                    trailingAccessory: .toggle(
                        state.updatedGroupsAllowDescriptionEditing,
                        oldValue: previousState.updatedGroupsAllowDescriptionEditing
                    ),
                    onTap: { [dependencies = viewModel.dependencies] in
                        dependencies.set(
                            feature: .updatedGroupsAllowDescriptionEditing,
                            to: !state.updatedGroupsAllowDescriptionEditing
                        )
                    }
                ),
                SessionCell.Info(
                    id: .updatedGroupsAllowPromotions,
                    title: "Allow Group Promotions",
                    subtitle: """
                    Controls whether the UI allows group admins to promote other group members to admin within an updated group.
                    
                    <b>Note:</b> In a future release we will offer this functionality but for the initial release it may not be fully supported across platforms so can be controlled via this flag for testing purposes.
                    """,
                    trailingAccessory: .toggle(
                        state.updatedGroupsAllowPromotions,
                        oldValue: previousState.updatedGroupsAllowPromotions
                    ),
                    onTap: { [dependencies = viewModel.dependencies] in
                        dependencies.set(
                            feature: .updatedGroupsAllowPromotions,
                            to: !state.updatedGroupsAllowPromotions
                        )
                    }
                ),
                SessionCell.Info(
                    id: .updatedGroupsAllowInviteById,
                    title: "Allow Invite by ID",
                    subtitle: """
                    Controls whether the UI allows group admins to invite other group members directly by their Account ID.
                    
                    <b>Note:</b> In a future release we will offer this functionality but it's not included in the initial release.
                    """,
                    trailingAccessory: .toggle(
                        state.updatedGroupsAllowInviteById,
                        oldValue: previousState.updatedGroupsAllowInviteById
                    ),
                    onTap: { [dependencies = viewModel.dependencies] in
                        dependencies.set(
                            feature: .updatedGroupsAllowInviteById,
                            to: !state.updatedGroupsAllowInviteById
                        )
                    }
                ),
                SessionCell.Info(
                    id: .updatedGroupsDeleteBeforeNow,
                    title: "Show button to delete messages before now",
                    subtitle: """
                    Controls whether the UI allows group admins to delete all messages in the group that were sent before the button was pressed.
                    
                    <b>Note:</b> In a future release we will offer this functionality but it's not included in the initial release.
                    """,
                    trailingAccessory: .toggle(
                        state.updatedGroupsDeleteBeforeNow,
                        oldValue: previousState.updatedGroupsDeleteBeforeNow
                    ),
                    onTap: { [dependencies = viewModel.dependencies] in
                        dependencies.set(
                            feature: .updatedGroupsDeleteBeforeNow,
                            to: !state.updatedGroupsDeleteBeforeNow
                        )
                    }
                ),
                SessionCell.Info(
                    id: .updatedGroupsDeleteAttachmentsBeforeNow,
                    title: "Show button to delete attachments before now",
                    subtitle: """
                    Controls whether the UI allows group admins to delete all attachments (and their associated messages) in the group that were sent before the button was pressed.
                    
                    <b>Note:</b> In a future release we will offer this functionality but it's not included in the initial release.
                    """,
                    trailingAccessory: .toggle(
                        state.updatedGroupsDeleteAttachmentsBeforeNow,
                        oldValue: previousState.updatedGroupsDeleteAttachmentsBeforeNow
                    ),
                    onTap: { [dependencies = viewModel.dependencies] in
                        dependencies.set(
                            feature: .updatedGroupsDeleteAttachmentsBeforeNow,
                            to: !state.updatedGroupsDeleteAttachmentsBeforeNow
                        )
                    }
                )
            ]
        )
        
        return [general]
    }
    
    // MARK: - Functions
    
    public static func disableDeveloperMode(using dependencies: Dependencies) {
        let features: [FeatureConfig<Bool>] = [
            .updatedGroupsDisableAutoApprove,
            .updatedGroupsRemoveMessagesOnKick,
            .updatedGroupsAllowHistoricAccessOnInvite,
            .updatedGroupsAllowDisplayPicture,
            .updatedGroupsAllowDescriptionEditing,
            .updatedGroupsAllowPromotions,
            .updatedGroupsAllowInviteById,
            .updatedGroupsDeleteBeforeNow,
            .updatedGroupsDeleteAttachmentsBeforeNow
        ]
        
        features.forEach { feature in
            guard dependencies.hasSet(feature: feature) else { return }
            
            dependencies.reset(feature: feature)
        }
    }
}
