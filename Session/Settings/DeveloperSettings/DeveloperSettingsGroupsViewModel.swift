// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SwiftUI
import Combine
import GRDB
import DifferenceKit
import SessionUIKit
import SessionNetworkingKit
import SessionMessagingKit
import SessionUtilitiesKit

class DeveloperSettingsGroupsViewModel: SessionListScreenContent.ViewModelType, NavigatableStateHolder {
    public let dependencies: Dependencies
    public let navigatableState: NavigatableState = NavigatableState()
    public let state: SessionListScreenContent.ListItemDataState<Section, ListItem> = SessionListScreenContent.ListItemDataState()
    public var imageDataManager: ImageDataManagerType { dependencies[singleton: .imageDataManager] }
    
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
            .using(dependencies: dependencies)
            .query(DeveloperSettingsGroupsViewModel.queryState)
            .assign { [weak self] updatedState in
                guard let self = self else { return }
                
                let oldState: State = self.internalState
                self.internalState = updatedState
                self.state.updateTableData(updatedState.sections(viewModel: self, previousState: oldState))
            }
    }
    
    // MARK: - Config
    
    public enum Section: SessionListScreenContent.ListSection {
        case general
        
        public var title: String? {
            switch self {
                case .general: return nil
            }
        }
        
        public var style: SessionListScreenContent.ListSectionStyle {
            switch self {
                case .general: return .padding
            }
        }
        
        public var divider: Bool { return true }
        public var footer: String? { return nil }
        public var extraVerticalPadding: CGFloat { return 0 }
        public var shadow: Bool { return false }
    }
    
    public enum ListItem: Hashable, Differentiable, CaseIterable {
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
        
        public func isContentEqual(to source: ListItem) -> Bool {
            self.differenceIdentifier == source.differenceIdentifier
        }
        
        public static var allCases: [ListItem] {
            var result: [ListItem] = []
            switch ListItem.groupsShowPubkeyInConversationSettings {
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
                SessionListScreenContent.ListItemInfo(
                    id: .groupsShowPubkeyInConversationSettings,
                    variant: .cell(
                        info: ListItemCell.Info(
                            title: SessionListScreenContent.TextInfo("Show Group Pubkey in Conversation Settings", font: .Body.largeBold),
                            description: .htmlTagged("""
                            Makes the group identity public key appear in the conversation settings screen.
                            """),
                            trailingAccessory: .toggle(
                                state.groupsShowPubkeyInConversationSettings,
                                oldValue: previousState.groupsShowPubkeyInConversationSettings
                            )
                        )
                    ),
                    onTap: { [dependencies = viewModel.dependencies] in
                        dependencies.set(
                            feature: .groupsShowPubkeyInConversationSettings,
                            to: !state.groupsShowPubkeyInConversationSettings
                        )
                    }
                ),
                SessionListScreenContent.ListItemInfo(
                    id: .updatedGroupsDisableAutoApprove,
                    variant: .cell(
                        info: ListItemCell.Info(
                            title: SessionListScreenContent.TextInfo("Disable Auto Approve", font: .Body.largeBold),
                            description: .htmlTagged("""
                            Prevents a group from automatically getting approved if the admin is already approved.
                            
                            <b>Note:</b> The default behaviour is to automatically approve new groups if the admin that sent the invitation is an approved contact.
                            """),
                            trailingAccessory: .toggle(
                                state.updatedGroupsDisableAutoApprove,
                                oldValue: previousState.updatedGroupsDisableAutoApprove
                            )
                        )
                    ),
                    onTap: { [dependencies = viewModel.dependencies] in
                        dependencies.set(
                            feature: .updatedGroupsDisableAutoApprove,
                            to: !state.updatedGroupsDisableAutoApprove
                        )
                    }
                ),
                SessionListScreenContent.ListItemInfo(
                    id: .updatedGroupsRemoveMessagesOnKick,
                    variant: .cell(
                        info: ListItemCell.Info(
                            title: SessionListScreenContent.TextInfo("Remove Messages on Kick", font: .Body.largeBold),
                            description: .htmlTagged("""
                            Controls whether a group members messages should be removed when they are kicked from an updated group.
                            
                            <b>Note:</b> In a future release we will offer this as an option when removing members but for the initial release it can be controlled via this flag for testing purposes.
                            """),
                            trailingAccessory: .toggle(
                                state.updatedGroupsRemoveMessagesOnKick,
                                oldValue: previousState.updatedGroupsRemoveMessagesOnKick
                            )
                        )
                    ),
                    onTap: { [dependencies = viewModel.dependencies] in
                        dependencies.set(
                            feature: .updatedGroupsRemoveMessagesOnKick,
                            to: !state.updatedGroupsRemoveMessagesOnKick
                        )
                    }
                ),
                SessionListScreenContent.ListItemInfo(
                    id: .updatedGroupsAllowHistoricAccessOnInvite,
                    variant: .cell(
                        info: ListItemCell.Info(
                            title: SessionListScreenContent.TextInfo("Allow Historic Message Access", font: .Body.largeBold),
                            description: .htmlTagged("""
                            Controls whether members should be granted access to historic messages when invited to an updated group.
                            
                            <b>Note:</b> In a future release we will offer this as an option when inviting members but for the initial release it can be controlled via this flag for testing purposes.
                            """),
                            trailingAccessory: .toggle(
                                state.updatedGroupsAllowHistoricAccessOnInvite,
                                oldValue: previousState.updatedGroupsAllowHistoricAccessOnInvite
                            )
                        )
                    ),
                    onTap: { [dependencies = viewModel.dependencies] in
                        dependencies.set(
                            feature: .updatedGroupsAllowHistoricAccessOnInvite,
                            to: !state.updatedGroupsAllowHistoricAccessOnInvite
                        )
                    }
                ),
                SessionListScreenContent.ListItemInfo(
                    id: .updatedGroupsAllowDisplayPicture,
                    variant: .cell(
                        info: ListItemCell.Info(
                            title: SessionListScreenContent.TextInfo("Custom Display Pictures", font: .Body.largeBold),
                            description: .htmlTagged("""
                            Controls whether the UI allows group admins to set a custom display picture for a group.
                            
                            <b>Note:</b> In a future release we will offer this functionality but for the initial release it may not be fully supported across platforms so can be controlled via this flag for testing purposes.
                            """),
                            trailingAccessory: .toggle(
                                state.updatedGroupsAllowDisplayPicture,
                                oldValue: previousState.updatedGroupsAllowDisplayPicture
                            )
                        )
                    ),
                    onTap: { [dependencies = viewModel.dependencies] in
                        dependencies.set(
                            feature: .updatedGroupsAllowDisplayPicture,
                            to: !state.updatedGroupsAllowDisplayPicture
                        )
                    }
                ),
                SessionListScreenContent.ListItemInfo(
                    id: .updatedGroupsAllowDescriptionEditing,
                    variant: .cell(
                        info: ListItemCell.Info(
                            title: SessionListScreenContent.TextInfo("Edit Group Descriptions", font: .Body.largeBold),
                            description: .htmlTagged("""
                            Controls whether the UI allows group admins to modify the descriptions of updated groups.
                            
                            <b>Note:</b> In a future release we will offer this functionality but for the initial release it may not be fully supported across platforms so can be controlled via this flag for testing purposes.
                            """),
                            trailingAccessory: .toggle(
                                state.updatedGroupsAllowDescriptionEditing,
                                oldValue: previousState.updatedGroupsAllowDescriptionEditing
                            )
                        )
                    ),
                    onTap: { [dependencies = viewModel.dependencies] in
                        dependencies.set(
                            feature: .updatedGroupsAllowDescriptionEditing,
                            to: !state.updatedGroupsAllowDescriptionEditing
                        )
                    }
                ),
                SessionListScreenContent.ListItemInfo(
                    id: .updatedGroupsAllowPromotions,
                    variant: .cell(
                        info: ListItemCell.Info(
                            title: SessionListScreenContent.TextInfo("Allow Group Promotions", font: .Body.largeBold),
                            description: .htmlTagged("""
                            Controls whether the UI allows group admins to promote other group members to admin within an updated group.
                            
                            <b>Note:</b> In a future release we will offer this functionality but for the initial release it may not be fully supported across platforms so can be controlled via this flag for testing purposes.
                            """),
                            trailingAccessory: .toggle(
                                state.updatedGroupsAllowPromotions,
                                oldValue: previousState.updatedGroupsAllowPromotions
                            )
                        )
                    ),
                    onTap: { [dependencies = viewModel.dependencies] in
                        dependencies.set(
                            feature: .updatedGroupsAllowPromotions,
                            to: !state.updatedGroupsAllowPromotions
                        )
                    }
                ),
                SessionListScreenContent.ListItemInfo(
                    id: .updatedGroupsAllowInviteById,
                    variant: .cell(
                        info: ListItemCell.Info(
                            title: SessionListScreenContent.TextInfo("Allow Invite by ID", font: .Body.largeBold),
                            description: .htmlTagged("""
                            Controls whether the UI allows group admins to invite other group members directly by their Account ID.
                            
                            <b>Note:</b> In a future release we will offer this functionality but it's not included in the initial release.
                            """),
                            trailingAccessory: .toggle(
                                state.updatedGroupsAllowInviteById,
                                oldValue: previousState.updatedGroupsAllowInviteById
                            )
                        )
                    ),
                    onTap: { [dependencies = viewModel.dependencies] in
                        dependencies.set(
                            feature: .updatedGroupsAllowInviteById,
                            to: !state.updatedGroupsAllowInviteById
                        )
                    }
                ),
                SessionListScreenContent.ListItemInfo(
                    id: .updatedGroupsDeleteBeforeNow,
                    variant: .cell(
                        info: ListItemCell.Info(
                            title: SessionListScreenContent.TextInfo("Show button to delete messages before now", font: .Body.largeBold),
                            description: .htmlTagged("""
                            Controls whether the UI allows group admins to delete all messages in the group that were sent before the button was pressed.
                            
                            <b>Note:</b> In a future release we will offer this functionality but it's not included in the initial release.
                            """),
                            trailingAccessory: .toggle(
                                state.updatedGroupsDeleteBeforeNow,
                                oldValue: previousState.updatedGroupsDeleteBeforeNow
                            )
                        )
                    ),
                    onTap: { [dependencies = viewModel.dependencies] in
                        dependencies.set(
                            feature: .updatedGroupsDeleteBeforeNow,
                            to: !state.updatedGroupsDeleteBeforeNow
                        )
                    }
                ),
                SessionListScreenContent.ListItemInfo(
                    id: .updatedGroupsDeleteAttachmentsBeforeNow,
                    variant: .cell(
                        info: ListItemCell.Info(
                            title: SessionListScreenContent.TextInfo("Show button to delete attachments before now", font: .Body.largeBold),
                            description: .htmlTagged("""
                            Controls whether the UI allows group admins to delete all attachments (and their associated messages) in the group that were sent before the button was pressed.
                            
                            <b>Note:</b> In a future release we will offer this functionality but it's not included in the initial release.
                            """),
                            trailingAccessory: .toggle(
                                state.updatedGroupsDeleteAttachmentsBeforeNow,
                                oldValue: previousState.updatedGroupsDeleteAttachmentsBeforeNow
                            )
                        )
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
