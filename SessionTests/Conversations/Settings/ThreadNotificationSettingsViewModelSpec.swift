// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Combine
import GRDB
import Quick
import Nimble
import SessionUIKit
import SessionSnodeKit
import SessionMessagingKit
import SessionUtilitiesKit

@testable import Session

class ThreadNotificationSettingsViewModelSpec: QuickSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies { dependencies in
            dependencies.forceSynchronous = true
            dependencies[singleton: .scheduler] = .immediate
        }
        @TestState(singleton: .storage, in: dependencies) var mockStorage: Storage! = SynchronousStorage(
            customWriter: try! DatabaseQueue(),
            migrationTargets: [
                SNUtilitiesKit.self,
                SNSnodeKit.self,
                SNMessagingKit.self,
                DeprecatedUIKitMigrationTarget.self
            ],
            using: dependencies,
            initialData: { db in
                try SessionThread(
                    id: "TestId",
                    variant: .contact,
                    creationDateTimestamp: 0,
                    using: dependencies
                ).insert(db)
            }
        )
        @TestState(singleton: .jobRunner, in: dependencies) var mockJobRunner: MockJobRunner! = MockJobRunner(
            initialSetup: { jobRunner in
                jobRunner
                    .when { $0.add(.any, job: .any, dependantJob: .any, canStartJob: .any) }
                    .thenReturn(nil)
                jobRunner
                    .when { $0.upsert(.any, job: .any, canStartJob: .any) }
                    .thenReturn(nil)
            }
        )
        @TestState var viewModel: ThreadNotificationSettingsViewModel! = ThreadNotificationSettingsViewModel(
            threadId: "TestId",
            threadNotificationSettings: .init(
                threadOnlyNotifyForMentions: nil,
                threadMutedUntilTimestamp: nil
            ),
            using: dependencies
        )
        
        @TestState var cancellables: [AnyCancellable]! = [
            viewModel.tableDataPublisher
                .receive(on: ImmediateScheduler.shared)
                .sink(
                    receiveCompletion: { _ in },
                    receiveValue: { viewModel.updateTableData($0) }
                )
        ]
        
        // MARK: - a ThreadNotificationSettingsViewModel
        describe("a ThreadNotificationSettingsViewModel") {
            // MARK: -- has the correct title
            it("has the correct title") {
                expect(viewModel.title).to(equal("sessionNotifications".localized()))
            }
            
            // MARK: -- has the correct number of items
            it("has the correct number of items") {
                // The default disappearing messages configure is Off
                // Should only show one section of Disappearing Messages Type
                expect(viewModel.tableData.count).to(equal(1))
                
                // All Messages
                // Mentions Only
                // Mute
                expect(viewModel.tableData.first?.elements.count).to(equal(3))
            }
            
            // MARK: -- has the correct default state
            it("has the correct default state") {
                // First option is always All Messages
                expect(viewModel.tableData.first?.elements.first)
                    .to(
                        equal(
                            SessionCell.Info(
                                id: .allMessages,
                                position: .top,
                                leadingAccessory: .icon(.volume2),
                                title: "notificationsAllMessages".localized(),
                                trailingAccessory: .radio(
                                    isSelected: true,
                                    accessibility: Accessibility(
                                        identifier: "All messages - Radio"
                                    )
                                ),
                                accessibility: Accessibility(
                                    identifier: "All messages notification setting",
                                    label: "All messages"
                                ),
                                onTap: {}
                            )
                        )
                    )
                // Last option is always Mute
                expect(viewModel.tableData.first?.elements.last)
                    .to(
                        equal(
                            SessionCell.Info(
                                id: .mute,
                                position: .bottom,
                                leadingAccessory: .icon(.volumeOff),
                                title: "notificationsMute".localized(),
                                trailingAccessory: .radio(
                                    isSelected: false,
                                    accessibility: Accessibility(
                                        identifier: "Mute - Radio"
                                    )
                                ),
                                accessibility: Accessibility(
                                    identifier: "\(ThreadSettingsViewModel.self).mute",
                                    label: "Mute notifications"
                                ),
                                onTap: {}
                            )
                        )
                    )
            }
            
            // MARK: -- starts with the correct item active if not default
            it("starts with the correct item active if not default") {
                // Test settings: Mute
                mockStorage.write { db in
                    try SessionThread
                        .filter(id: "TestId")
                        .updateAll(
                            db,
                            SessionThread.Columns.mutedUntilTimestamp.set(to: Date.distantFuture.timeIntervalSince1970)
                        )
                }
                viewModel = ThreadNotificationSettingsViewModel(
                    threadId: "TestId",
                    threadNotificationSettings: .init(
                        threadOnlyNotifyForMentions: false,
                        threadMutedUntilTimestamp: Date.distantFuture.timeIntervalSince1970
                    ),
                    using: dependencies
                )
                cancellables.append(
                    viewModel.tableDataPublisher
                        .receive(on: ImmediateScheduler.shared)
                        .sink(
                            receiveCompletion: { _ in },
                            receiveValue: { viewModel.updateTableData($0) }
                        )
                )
                
                expect(viewModel.tableData.first?.elements.first)
                    .to(
                        equal(
                            SessionCell.Info(
                                id: .allMessages,
                                position: .top,
                                leadingAccessory: .icon(.volume2),
                                title: "notificationsAllMessages".localized(),
                                trailingAccessory: .radio(
                                    isSelected: false,
                                    accessibility: Accessibility(
                                        identifier: "All messages - Radio"
                                    )
                                ),
                                accessibility: Accessibility(
                                    identifier: "All messages notification setting",
                                    label: "All messages"
                                ),
                                onTap: {}
                            )
                        )
                    )
                
                expect(viewModel.tableData.first?.elements.last)
                    .to(
                        equal(
                            SessionCell.Info(
                                id: .mute,
                                position: .bottom,
                                leadingAccessory: .icon(.volumeOff),
                                title: "notificationsMute".localized(),
                                trailingAccessory: .radio(
                                    isSelected: true,
                                    accessibility: Accessibility(
                                        identifier: "Mute - Radio"
                                    )
                                ),
                                accessibility: Accessibility(
                                    identifier: "\(ThreadSettingsViewModel.self).mute",
                                    label: "Mute notifications"
                                ),
                                onTap: {}
                            )
                        )
                    )
            }
            
            // MARK: -- has a disabled footer button
            it("has a disabled footer button") {
                var footerButtonInfo: SessionButton.Info?
                
                cancellables.append(
                    viewModel.footerButtonInfo
                        .receive(on: ImmediateScheduler.shared)
                        .sink(
                            receiveCompletion: { _ in },
                            receiveValue: { info in footerButtonInfo = info }
                        )
                )
                
                expect(footerButtonInfo).to(equal(
                    SessionButton.Info(
                        style: .bordered,
                        title: "set".localized(),
                        isEnabled: false,
                        accessibility: Accessibility(
                            identifier: "Set button",
                            label: "Set button"
                        ),
                        minWidth: 110,
                        onTap: {}
                    )
                ))
            }
            
            // MARK: -- can change to another setting and change back
            it("can change to another setting and change back") {
                var footerButtonInfo: SessionButton.Info?
                
                // Test settings: Mute
                mockStorage.write { db in
                    try SessionThread
                        .filter(id: "TestId")
                        .updateAll(
                            db,
                            SessionThread.Columns.mutedUntilTimestamp.set(to: Date.distantFuture.timeIntervalSince1970)
                        )
                }
                viewModel = ThreadNotificationSettingsViewModel(
                    threadId: "TestId",
                    threadNotificationSettings: .init(
                        threadOnlyNotifyForMentions: false,
                        threadMutedUntilTimestamp: Date.distantFuture.timeIntervalSince1970
                    ),
                    using: dependencies
                )
                cancellables.append(
                    viewModel.tableDataPublisher
                        .receive(on: ImmediateScheduler.shared)
                        .sink(
                            receiveCompletion: { _ in },
                            receiveValue: { viewModel.updateTableData($0) }
                        )
                )
                
                // Change to another setting
                viewModel.tableData.first?.elements.first?.onTap?()
                
                cancellables.append(
                    viewModel.footerButtonInfo
                        .receive(on: ImmediateScheduler.shared)
                        .sink(
                            receiveCompletion: { _ in },
                            receiveValue: { info in footerButtonInfo = info }
                        )
                )
                
                // Gets enabled
                expect(footerButtonInfo).to(equal(
                    SessionButton.Info(
                        style: .bordered,
                        title: "set".localized(),
                        isEnabled: true,
                        accessibility: Accessibility(
                            identifier: "Set button",
                            label: "Set button"
                        ),
                        minWidth: 110,
                        onTap: {}
                    )
                ))
                
                // Change back
                viewModel.tableData.first?.elements.last?.onTap?()
                
                expect(viewModel.tableData.first?.elements.last)
                    .to(
                        equal(
                            SessionCell.Info(
                                id: .mute,
                                position: .bottom,
                                leadingAccessory: .icon(.volumeOff),
                                title: "notificationsMute".localized(),
                                trailingAccessory: .radio(
                                    isSelected: true,
                                    accessibility: Accessibility(
                                        identifier: "Mute - Radio"
                                    )
                                ),
                                accessibility: Accessibility(
                                    identifier: "\(ThreadSettingsViewModel.self).mute",
                                    label: "Mute notifications"
                                )
                            )
                        )
                    )
                
                cancellables.append(
                    viewModel.footerButtonInfo
                        .receive(on: ImmediateScheduler.shared)
                        .sink(
                            receiveCompletion: { _ in },
                            receiveValue: { info in footerButtonInfo = info }
                        )
                )
                
                // Disabled again
                expect(footerButtonInfo).to(equal(
                    SessionButton.Info(
                        style: .bordered,
                        title: "set".localized(),
                        isEnabled: false,
                        accessibility: Accessibility(
                            identifier: "Set button",
                            label: "Set button"
                        ),
                        minWidth: 110,
                        onTap: {}
                    )
                ))
            }
            
            // MARK: -- when changed from the previous setting
            context("when changed from the previous setting") {
                @TestState var footerButtonInfo: SessionButton.Info?
                
                beforeEach {
                    cancellables.append(
                        viewModel.footerButtonInfo
                            .receive(on: ImmediateScheduler.shared)
                            .sink(
                                receiveCompletion: { _ in },
                                receiveValue: { info in footerButtonInfo = info }
                            )
                    )
                    
                    viewModel.tableData.first?.elements.last?.onTap?()
                }
                
                // MARK: ---- shows the set button
                it("shows the set button") {
                    expect(footerButtonInfo)
                        .to(
                            equal(
                                SessionButton.Info(
                                    style: .bordered,
                                    title: "set".localized(),
                                    isEnabled: true,
                                    accessibility: Accessibility(
                                        identifier: "Set button",
                                        label: "Set button"
                                    ),
                                    minWidth: 110,
                                    onTap: {}
                                )
                            )
                        )
                }
                
                // MARK: ---- and saving
                context("and saving") {
                    // MARK: ------ dismisses the screen
                    it("dismisses the screen") {
                        var didDismissScreen: Bool = false
                        
                        cancellables.append(
                            viewModel.navigatableState.dismissScreen
                                .receive(on: ImmediateScheduler.shared)
                                .sink(
                                    receiveCompletion: { _ in },
                                    receiveValue: { _ in didDismissScreen = true }
                                )
                        )
                        
                        footerButtonInfo?.onTap()
                        
                        expect(didDismissScreen).to(beTrue())
                    }
                    
                    // MARK: ------ saves the updated settings
                    it("saves the updated settings") {
                        footerButtonInfo?.onTap()
                        
                        let updatedSettings: TimeInterval? = mockStorage.read { db in
                            try SessionThread
                                .select(SessionThread.Columns.mutedUntilTimestamp)
                                .filter(id: "TestId")
                                .asRequest(of: TimeInterval.self)
                                .fetchOne(db)
                        }
                        
                        expect(updatedSettings).to(beGreaterThan(0))
                    }
                }
            }
        }
    }
}
