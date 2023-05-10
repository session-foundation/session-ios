// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

class NotificationSettingsViewModel: SessionTableViewModel<NoNav, NotificationSettingsViewModel.Section, NotificationSettingsViewModel.Setting> {
    // MARK: - Config
    
    public enum Section: SessionTableSection {
        case strategy
        case style
        case content
        
        var title: String? {
            switch self {
                case .strategy: return "NOTIFICATIONS_SECTION_STRATEGY".localized()
                case .style: return "NOTIFICATIONS_SECTION_STYLE".localized()
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
    
    public enum Setting: Differentiable {
        case strategyUseFastMode
        case strategyDeviceSettings
        case styleSound
        case styleSoundWhenAppIsOpen
        case content
    }
    
    // MARK: - Content
    
    override var title: String { "NOTIFICATIONS_TITLE".localized() }
    
    public override var observableTableData: ObservableData { _observableTableData }
    
    /// This is all the data the screen needs to populate itself, please see the following link for tips to help optimise
    /// performance https://github.com/groue/GRDB.swift#valueobservation-performance
    ///
    /// **Note:** This observation will be triggered twice immediately (and be de-duped by the `removeDuplicates`)
    /// this is due to the behaviour of `ValueConcurrentObserver.asyncStartObservation` which triggers it's own
    /// fetch (after the ones in `ValueConcurrentObserver.asyncStart`/`ValueConcurrentObserver.syncStart`)
    /// just in case the database has changed between the two reads - unfortunately it doesn't look like there is a way to prevent this
    private lazy var _observableTableData: ObservableData = ValueObservation
        .trackingConstantRegion { db -> [SectionModel] in
            let notificationSound: Preferences.Sound = db[.defaultNotificationSound]
                .defaulting(to: Preferences.Sound.defaultNotificationSound)
            let previewType: Preferences.NotificationPreviewType = db[.preferencesNotificationPreviewType]
                .defaulting(to: Preferences.NotificationPreviewType.defaultPreviewType)
            
            return [
                SectionModel(
                    model: .strategy,
                    elements: [
                        SessionCell.Info(
                            id: .strategyUseFastMode,
                            title: "NOTIFICATIONS_STRATEGY_FAST_MODE_TITLE".localized(),
                            subtitle: "NOTIFICATIONS_STRATEGY_FAST_MODE_DESCRIPTION".localized(),
                            rightAccessory: .toggle(
                                .userDefaults(UserDefaults.standard, key: "isUsingFullAPNs")
                            ),
                            styling: SessionCell.StyleInfo(
                                allowedSeparators: [.top],
                                customPadding: SessionCell.Padding(bottom: Values.verySmallSpacing)
                            ),
                            onTap: {
                                UserDefaults.standard.set(
                                    !UserDefaults.standard.bool(forKey: "isUsingFullAPNs"),
                                    forKey: "isUsingFullAPNs"
                                )
                                
                                // Force sync the push tokens on change
                                SyncPushTokensJob.run(uploadOnlyIfStale: false)
                            }
                        ),
                        SessionCell.Info(
                            id: .strategyDeviceSettings,
                            title: SessionCell.TextInfo(
                                "NOTIFICATIONS_STRATEGY_FAST_MODE_ACTION".localized(),
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
                            title: "NOTIFICATIONS_STYLE_SOUND_TITLE".localized(),
                            rightAccessory: .dropDown(
                                .dynamicString { notificationSound.displayName }
                            ),
                            onTap: { [weak self] in
                                self?.transitionToScreen(
                                    SessionTableViewController(viewModel: NotificationSoundViewModel())
                                )
                            }
                        ),
                        SessionCell.Info(
                            id: .styleSoundWhenAppIsOpen,
                            title: "NOTIFICATIONS_STYLE_SOUND_WHEN_OPEN_TITLE".localized(),
                            rightAccessory: .toggle(.settingBool(key: .playNotificationSoundInForeground)),
                            onTap: {
                                Storage.shared.write { db in
                                    db[.playNotificationSoundInForeground] = !db[.playNotificationSoundInForeground]
                                }
                            }
                        )
                    ]
                ),
                SectionModel(
                    model: .content,
                    elements: [
                        SessionCell.Info(
                            id: .content,
                            title: "NOTIFICATIONS_STYLE_CONTENT_TITLE".localized(),
                            subtitle: "NOTIFICATIONS_STYLE_CONTENT_DESCRIPTION".localized(),
                            rightAccessory: .dropDown(
                                .dynamicString { previewType.name }
                            ),
                            onTap: { [weak self] in
                                self?.transitionToScreen(
                                    SessionTableViewController(viewModel: NotificationContentViewModel())
                                )
                            }
                        )
                    ]
                )
            ]
        }
        .removeDuplicates()
        .publisher(in: Storage.shared)
        .mapToSessionTableViewData(for: self)
}
