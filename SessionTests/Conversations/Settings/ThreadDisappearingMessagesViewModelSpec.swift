// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Combine
import GRDB
import Quick
import Nimble

@testable import Session

class ThreadDisappearingMessagesSettingsViewModelSpec: QuickSpec {
    typealias ParentType = SessionTableViewModel<ThreadDisappearingMessagesSettingsViewModel.NavButton, ThreadDisappearingMessagesSettingsViewModel.Section, ThreadDisappearingMessagesSettingsViewModel.Item>
    
    // MARK: - Spec

    override func spec() {
        var mockStorage: Storage!
        var cancellables: [AnyCancellable] = []
        var dependencies: Dependencies!
        var viewModel: ThreadDisappearingMessagesSettingsViewModel!
        
        describe("a ThreadDisappearingMessagesSettingsViewModel") {
            // MARK: - Configuration
            
            beforeEach {
                mockStorage = Storage(
                    customWriter: try! DatabaseQueue(),
                    customMigrations: [
                        SNUtilitiesKit.migrations(),
                        SNSnodeKit.migrations(),
                        SNMessagingKit.migrations(),
                        SNUIKit.migrations()
                    ]
                )
                dependencies = Dependencies(
                    storage: mockStorage,
                    scheduler: .immediate
                )
                mockStorage.write { db in
                    try SessionThread(
                        id: "TestId",
                        variant: .contact
                    ).insert(db)
                }
                viewModel = ThreadDisappearingMessagesSettingsViewModel(
                    dependencies: dependencies,
                    threadId: "TestId",
                    threadVariant: .contact,
                    currentUserIsClosedGroupMember: nil,
                    currentUserIsClosedGroupAdmin: nil,
                    config: DisappearingMessagesConfiguration.defaultWith("TestId")
                )
                cancellables.append(
                    viewModel.observableTableData
                        .receiveOnMain(immediately: true)
                        .sink(
                            receiveCompletion: { _ in },
                            receiveValue: { viewModel.updateTableData($0.0) }
                        )
                )
            }
            
            afterEach {
                cancellables.forEach { $0.cancel() }
                
                mockStorage = nil
                cancellables = []
                dependencies = nil
                viewModel = nil
            }
            
            // MARK: - Basic Tests
            
            it("has the correct title") {
                expect(viewModel.title).to(equal("DISAPPEARING_MESSAGES".localized()))
            }
            
            it("has the correct number of items") {
                expect(viewModel.tableData.count)
                    .to(equal(1))
                expect(viewModel.tableData.first?.elements.count)
                    .to(equal(12))
            }
            
            it("has the correct default state") {
                expect(viewModel.tableData.first?.elements.first)
                    .to(
                        equal(
                            SessionCell.Info(
                                id: ThreadDisappearingMessagesSettingsViewModel.Item(
                                    title: "DISAPPEARING_MESSAGES_OFF".localized()
                                ),
                                position: .top,
                                title: "DISAPPEARING_MESSAGES_OFF".localized(),
                                rightAccessory: .radio(
                                    isSelected: { true }
                                ),
                                accessibilityIdentifier: "Off option",
                                accessibilityLabel: "Off option"
                            )
                        )
                    )
                
                let title: String = (DisappearingMessagesConfiguration.validDurationsSeconds.last?
                    .formatted(format: .long))
                    .defaulting(to: "")
                expect(viewModel.tableData.first?.elements.last)
                    .to(
                        equal(
                            SessionCell.Info(
                                id: ThreadDisappearingMessagesSettingsViewModel.Item(title: title),
                                position: .bottom,
                                title: title,
                                rightAccessory: .radio(
                                    isSelected: { false }
                                )
                            )
                        )
                    )
                expect(viewModel.settingsData.count)
                    .to(equal(1))
            }
            
            it("starts with the correct item active if not default") {
                let config: DisappearingMessagesConfiguration = DisappearingMessagesConfiguration
                    .defaultWith("TestId")
                    .with(
                        isEnabled: true,
                        durationSeconds: DisappearingMessagesConfiguration.validDurationsSeconds(.disappearAfterSend).last,
                        type: .disappearAfterSend
                    )
                mockStorage.write { db in
                    _ = try config.saved(db)
                }
                viewModel = ThreadDisappearingMessagesSettingsViewModel(
                    dependencies: dependencies,
                    threadId: "TestId",
                    threadVariant: .contact,
                    currentUserIsClosedGroupMember: nil,
                    currentUserIsClosedGroupAdmin: nil,
                    config: config
                )
                cancellables.append(
                    viewModel.observableTableData
                        .receiveOnMain(immediately: true)
                        .sink(
                            receiveCompletion: { _ in },
                            receiveValue: { viewModel.updateTableData($0.0) }
                        )
                )
                
                expect(viewModel.tableData.first?.elements.first)
                    .to(
                        equal(
                            SessionCell.Info(
                                id: ThreadDisappearingMessagesSettingsViewModel.Item(
                                    title: "DISAPPEARING_MESSAGES_OFF".localized()
                                ),
                                position: .top,
                                title: "DISAPPEARING_MESSAGES_OFF".localized(),
                                rightAccessory: .radio(
                                    isSelected: { false }
                                ),
                                accessibilityIdentifier: "Off option",
                                accessibilityLabel: "Off option"
                            )
                        )
                    )
                
                expect(viewModel.settingsData.first?.elements.last)
                    .to(
                        equal(
                            SessionCell.Info(
                                id: ThreadDisappearingMessagesViewModel.Item(
                                    title: "DISAPPERING_MESSAGES_TYPE_AFTER_SEND_TITLE".localized()
                                ),
                                title: "DISAPPERING_MESSAGES_TYPE_AFTER_SEND_TITLE".localized(),
                                subtitle: "DISAPPERING_MESSAGES_TYPE_AFTER_SEND_DESCRIPTION".localized(),
                                rightAccessory: .radio(
                                    isSelected: { true }
                                )
                            )
                        )
                    )
                
                expect(viewModel.settingsData.count)
                    .to(equal(2))
                
                let title: String = (DisappearingMessagesConfiguration.validDurationsSeconds(.disappearAfterSend).last?
                    .formatted(format: .long))
                    .defaulting(to: "")
                expect(viewModel.tableData.first?.elements.last)
                    .to(
                        equal(
                            SessionCell.Info(
                                id: ThreadDisappearingMessagesSettingsViewModel.Item(title: title),
                                position: .bottom,
                                title: title,
                                rightAccessory: .radio(
                                    isSelected: { true }
                                ),
                                accessibilityIdentifier: "Time option",
                                accessibilityLabel: "Time option"
                            )
                        )
                    )
                
            }
            
            it("has no footer button") {
                var footerButtonInfo: SessionButton.Info?
                
                cancellables.append(
                    viewModel.footerButtonInfo
                        .receiveOnMain(immediately: true)
                        .sink(
                            receiveCompletion: { _ in },
                            receiveValue: { info in footerButtonInfo = info }
                        )
                )
                
                expect(footerButtonInfo).to(beNil())
            }
            
            context("when changed from the previous setting") {
                var footerButtonInfo: SessionButton.Info?
                
                beforeEach {
                    cancellables.append(
                        viewModel.footerButtonInfo
                            .receiveOnMain(immediately: true)
                            .sink(
                                receiveCompletion: { _ in },
                                receiveValue: { info in footerButtonInfo = info }
                            )
                    )
                    
                    viewModel.tableData.first?.elements.last?.onTap?()
                }
                
                it("shows the set button") {
                    expect(footerButtonInfo)
                        .to(
                            equal(
                                SessionButton.Info(
                                    style: .bordered,
                                    title: "DISAPPERING_MESSAGES_SAVE_TITLE".localized(),
                                    isEnabled: true,
                                    accessibilityIdentifier: "Set button",
                                    minWidth: 110,
                                    onTap: {}
                                )
                            )
                        )
                }
                
                context("and saving") {
                    it("dismisses the screen") {
                        var didDismissScreen: Bool = false
                        
                        cancellables.append(
                            viewModel.dismissScreen
                                .receiveOnMain(immediately: true)
                                .sink(
                                    receiveCompletion: { _ in },
                                    receiveValue: { _ in didDismissScreen = true }
                                )
                        )
                        
                        footerButtonInfo?.onTap()
                        
                        expect(didDismissScreen)
                            .toEventually(
                                beTrue(),
                                timeout: .milliseconds(100)
                            )
                    }
                    
                    it("saves the updated config") {
                        footerButtonInfo?.onTap()
                        
                        let updatedConfig: DisappearingMessagesConfiguration? = mockStorage.read { db in
                            try DisappearingMessagesConfiguration.fetchOne(db, id: "TestId")
                        }
                        
                        expect(updatedConfig?.isEnabled)
                            .toEventually(
                                beTrue(),
                                timeout: .milliseconds(100)
                            )
                        expect(updatedConfig?.durationSeconds)
                            .toEventually(
                                equal(DisappearingMessagesConfiguration.validDurationsSeconds(.disappearAfterSend).last ?? -1),
                                timeout: .milliseconds(100)
                            )
                        expect(updatedConfig?.type)
                            .toEventually(
                                equal(.disappearAfterSend),
                                timeout: .milliseconds(100)
                            )
                    }
                }
            }
        }
    }
}
