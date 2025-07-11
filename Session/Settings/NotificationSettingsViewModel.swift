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
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
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
    
    private struct State: ObservableKeyProvider {
        let isUsingFullAPNs: Bool
        let notificationSound: Preferences.Sound
        let playNotificationSoundInForeground: Bool
        let previewType: Preferences.NotificationPreviewType
        let sections: [SectionModel]
        
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
                previewType: .defaultPreviewType,
                sections: []
            )
        }
    }
    
    let title: String = "sessionNotifications".localized()
    
    /// The new `ObservationBuilder` shouldn't cancel it's observations when leaving the screen (this is handled better when built
    /// around `@Published` but _shouldn't_ have too big of a performance cost using the `SessionTableViewController` either)
    public var shouldCancelPublisherOnLeave: Bool = false
    lazy var tableDataPublisher: TargetPublisher = ObservationBuilder
        .debounce(for: .milliseconds(250))
        .using(manager: dependencies[singleton: .observationManager])
        .query { [dependencies] previousState, events -> State in
            let currentState: State = (previousState ?? State.initialState())
            var isUsingFullAPNs: Bool = currentState.isUsingFullAPNs
            var notificationSound: Preferences.Sound = currentState.notificationSound
            var playNotificationSoundInForeground: Bool = currentState.playNotificationSoundInForeground
            var previewType: Preferences.NotificationPreviewType = currentState.previewType
            
            /// If we have no previous state then we need to fetch the initial state
            if previousState == nil {
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
                switch event.key {
                    case .userDefault(.isUsingFullAPNs):
                        isUsingFullAPNs = ((event.value as? Bool) ?? currentState.isUsingFullAPNs)
                        
                    case .setting(.defaultNotificationSound):
                        notificationSound = (
                            (event.value as? Preferences.Sound) ??
                            currentState.notificationSound
                        )
                        
                    case .setting(.playNotificationSoundInForeground):
                        playNotificationSoundInForeground = (
                            (event.value as? Bool) ??
                            currentState.playNotificationSoundInForeground
                        )
                        
                    case .setting(.preferencesNotificationPreviewType):
                        previewType = (
                            (event.value as? Preferences.NotificationPreviewType) ??
                            currentState.previewType
                        )
                        
                    default: break
                }
            }
            
            return State(
                isUsingFullAPNs: isUsingFullAPNs,
                notificationSound: notificationSound,
                playNotificationSoundInForeground: playNotificationSoundInForeground,
                previewType: previewType,
                sections: []
            )
        }
        .publisher()
        .withPrevious()
        .map { [dependencies] previousState, state -> [SectionModel] in
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
                                oldValue: previousState?.isUsingFullAPNs,
                                accessibility: Accessibility(
                                    identifier: "Use Fast Mode - Switch"
                                )
                            ),
                            styling: SessionCell.StyleInfo(
                                allowedSeparators: [.top],
                                customPadding: SessionCell.Padding(bottom: Values.verySmallSpacing)
                            ),
                            // stringlint:ignore_contents
                            onTap: { [weak self] in
                                dependencies[defaults: .standard, key: .isUsingFullAPNs] = !state.isUsingFullAPNs
                                dependencies.notifyAsync(.isUsingFullAPNs, value: !state.isUsingFullAPNs)

                                // Force sync the push tokens on change
                                SyncPushTokensJob
                                    .run(uploadOnlyIfStale: false, using: dependencies)
                                    .sinkUntilComplete()
                                self?.forceRefresh(type: .postDatabaseQuery)
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
                            onTap: { [weak self] in
                                self?.transitionToScreen(
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
                                oldValue: previousState?.playNotificationSoundInForeground,
                                accessibility: Accessibility(
                                    identifier: "Sound when App is open - Switch"
                                )
                            ),
                            onTap: {
                                dependencies.setAsync(
                                    .playNotificationSoundInForeground,
                                    !state.playNotificationSoundInForeground
                                )
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
                            onTap: { [weak self] in
                                self?.transitionToScreen(
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
        .setFailureType(to: Error.self)
        .mapToSessionTableViewData(for: self)
}
