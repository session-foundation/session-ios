// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

class NotificationSettingsViewModel: SessionTableViewModel, NavigatableStateHolder, ObservableTableSource {
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
        self.internalState = State.initialState()
        
        bindState()
    }
    
    // MARK: - Config
    
    public enum Section: SessionTableSection {
        case strategy
        case style
        case content
        
        var title: String? {
            switch self {
                case .strategy: return "notificationsStrategy".localized()
                case .style: return "notificationsStyle".localized()
                case .content: return nil
            }
        }
        
        var style: SessionTableSectionStyle {
            switch self {
                case .content: return .padding
                default: return .titleRoundedContent
            }
        }
    }
    
    public enum TableItem: Differentiable {
        case strategyUseFastMode
        case strategyDeviceSettings
        case styleSound
        case styleSoundWhenAppIsOpen
        case content
    }
    
    // MARK: - Content
    
    public struct State: ObservableKeyProvider {
        let isUsingFullAPNs: Bool
        let notificationSound: Preferences.Sound
        let playNotificationSoundInForeground: Bool
        let previewType: Preferences.NotificationPreviewType
        
        @MainActor public func sections(viewModel: NotificationSettingsViewModel, previousState: State) -> [SectionModel] {
            NotificationSettingsViewModel.sections(
                state: self,
                previousState: previousState,
                viewModel: viewModel
            )
        }
        
        public let observedKeys: Set<ObservableKey> = [
            .userDefault(.isUsingFullAPNs),
            .setting(.defaultNotificationSound),
            .setting(.playNotificationSoundInForeground),
            .setting(.preferencesNotificationPreviewType)
        ]
        
        static func initialState() -> State {
            return State(
                isUsingFullAPNs: false,
                notificationSound: .defaultNotificationSound,
                playNotificationSoundInForeground: false,
                previewType: .defaultPreviewType
            )
        }
    }
    
    let title: String = "sessionNotifications".localized()
    
    @MainActor private func bindState() {
        observationTask = ObservationBuilder
            .initialValue(self.internalState)
            .debounce(for: .never)
            .using(dependencies: dependencies)
            .query(NotificationSettingsViewModel.queryState)
            .assign { [weak self] updatedState in
                guard let self = self else { return }
                
                // FIXME: To slightly reduce the size of the changes this new observation mechanism is currently wired into the old SessionTableViewController observation mechanism, we should refactor it so everything uses the new mechanism
                let oldState: State = self.internalState
                self.internalState = updatedState
                self.pendingTableDataSubject.send(updatedState.sections(viewModel: self, previousState: oldState))
            }
    }
    
    @Sendable private static func queryState(
        previousState: State,
        events: [ObservedEvent],
        isInitialQuery: Bool,
        using dependencies: Dependencies
    ) async -> State {
        var isUsingFullAPNs: Bool = previousState.isUsingFullAPNs
        var notificationSound: Preferences.Sound = previousState.notificationSound
        var playNotificationSoundInForeground: Bool = previousState.playNotificationSoundInForeground
        var previewType: Preferences.NotificationPreviewType = previousState.previewType
        
        /// If this is the initial query then we need to fetch the initial state
        if isInitialQuery {
            isUsingFullAPNs = dependencies[defaults: .standard, key: .isUsingFullAPNs]
            
            dependencies.mutate(cache: .libSession) { libSession in
                notificationSound = libSession.get(.defaultNotificationSound)
                    .defaulting(to: Preferences.Sound.defaultNotificationSound)
                playNotificationSoundInForeground = libSession.get(.playNotificationSoundInForeground)
                previewType = libSession.get(.preferencesNotificationPreviewType)
                    .defaulting(to: Preferences.NotificationPreviewType.defaultPreviewType)
            }
        }
        
        /// Process any event changes
        events.forEach { event in
            switch (event.key, event.value) {
                case (.userDefault(.isUsingFullAPNs), let updatedValue as Bool):
                    isUsingFullAPNs = updatedValue
                    
                case (.setting(.defaultNotificationSound), let updatedValue as Preferences.Sound):
                    notificationSound = updatedValue
                    
                case (.setting(.playNotificationSoundInForeground), let updatedValue as Bool):
                    playNotificationSoundInForeground = updatedValue
                    
                case (.setting(.preferencesNotificationPreviewType), let updatedValue as Preferences.NotificationPreviewType):
                    previewType = updatedValue
                    
                default: break
            }
        }
        
        return State(
            isUsingFullAPNs: isUsingFullAPNs,
            notificationSound: notificationSound,
            playNotificationSoundInForeground: playNotificationSoundInForeground,
            previewType: previewType
        )
    }
    
    private static func sections(
        state: State,
        previousState: State,
        viewModel: NotificationSettingsViewModel
    ) -> [SectionModel] {
        return [
            SectionModel(
                model: .strategy,
                elements: [
                    SessionCell.Info(
                        id: .strategyUseFastMode,
                        title: "useFastMode".localized(),
                        subtitle: "notificationsFastModeDescriptionIos".localized(),
                        trailingAccessory: .toggle(
                            state.isUsingFullAPNs,
                            oldValue: previousState.isUsingFullAPNs,
                            accessibility: Accessibility(
                                identifier: "Use Fast Mode - Switch"
                            )
                        ),
                        styling: SessionCell.StyleInfo(
                            allowedSeparators: [.top],
                            customPadding: SessionCell.Padding(bottom: Values.verySmallSpacing)
                        ),
                        onTap: { [dependencies = viewModel.dependencies] in
                            dependencies[defaults: .standard, key: .isUsingFullAPNs] = !state.isUsingFullAPNs

                            // Force sync the push tokens on change
                            Task.detached(priority: .userInitiated) {
                                try? await SyncPushTokensJob.run(uploadOnlyIfStale: false, using: dependencies)
                            }
                        }
                    ),
                    SessionCell.Info(
                        id: .strategyDeviceSettings,
                        title: SessionCell.TextInfo(
                            "notificationsGoToDevice".localized(),
                            font: .subtitleBold
                        ),
                        styling: SessionCell.StyleInfo(
                            tintColor: .settings_tertiaryAction,
                            allowedSeparators: [.bottom],
                            customPadding: SessionCell.Padding(top: Values.verySmallSpacing)
                        ),
                        onTap: { UIApplication.shared.openSystemSettings() }
                    )
                ]
            ),
            SectionModel(
                model: .style,
                elements: [
                    SessionCell.Info(
                        id: .styleSound,
                        title: "notificationsSound".localized(),
                        trailingAccessory: .dropDown { state.notificationSound.displayName },
                        onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                            viewModel?.transitionToScreen(
                                SessionTableViewController(
                                    viewModel: NotificationSoundViewModel(using: dependencies)
                                )
                            )
                        }
                    ),
                    SessionCell.Info(
                        id: .styleSoundWhenAppIsOpen,
                        title: "notificationsSoundDescription".localized(),
                        trailingAccessory: .toggle(
                            state.playNotificationSoundInForeground,
                            oldValue: previousState.playNotificationSoundInForeground,
                            accessibility: Accessibility(
                                identifier: "Sound when App is open - Switch"
                            )
                        ),
                        onTap: { [dependencies = viewModel.dependencies] in
                            let updatedValue: Bool = !state.playNotificationSoundInForeground
                            dependencies.setAsync(.playNotificationSoundInForeground, updatedValue)
                        }
                    )
                ]
            ),
            SectionModel(
                model: .content,
                elements: [
                    SessionCell.Info(
                        id: .content,
                        title: "notificationsContent".localized(),
                        subtitle: "notificationsContentDescription".localized(),
                        trailingAccessory: .dropDown { state.previewType.name },
                        onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                            viewModel?.transitionToScreen(
                                SessionTableViewController(
                                    viewModel: NotificationContentViewModel(using: dependencies)
                                )
                            )
                        }
                    )
                ]
            )
        ]
    }
}
