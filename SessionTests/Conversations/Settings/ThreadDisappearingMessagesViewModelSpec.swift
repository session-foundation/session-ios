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
                // The default disappearing messages configure is Off
                // Should only show one section of Disappearing Messages Type
                expect(viewModel.tableData.count)
                    .to(equal(1))
                if Features.useNewDisappearingMessagesConfig {
                    // Off
                    // Disappear After Read
                    // Disappear After Send
                    expect(viewModel.tableData.first?.elements.count)
                        .to(equal(3))
                } else {
                    // Off
                    // Legacy
                    // Disappear After Read
                    // Disappear After Send
                    expect(viewModel.tableData.first?.elements.count)
                        .to(equal(4))
                }
            }
            
            it("has the correct default state") {
                // First option is always Off
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
                                accessibility: Accessibility(
                                    identifier: "Disable disappearing messages (Off option)",
                                    label: "Disable disappearing messages (Off option)"
                                )
                            )
                        )
                    )
                // Last option is always Disappear After Send`
                expect(viewModel.tableData.first?.elements.last)
                    .to(
                        equal(
                            SessionCell.Info(
                                id: ThreadDisappearingMessagesSettingsViewModel.Item(
                                    title: "DISAPPERING_MESSAGES_TYPE_AFTER_SEND_TITLE".localized()
                                ),
                                position: .bottom,
                                title: "DISAPPERING_MESSAGES_TYPE_AFTER_SEND_TITLE".localized(),
                                subtitle: "DISAPPERING_MESSAGES_TYPE_AFTER_SEND_DESCRIPTION".localized(),
                                rightAccessory: .radio(
                                    isSelected: { false }
                                ),
                                isEnabled: Features.useNewDisappearingMessagesConfig,
                                accessibility: Accessibility(
                                    identifier: "Disappear after send option",
                                    label: "Disappear after send option"
                                )
                            )
                        )
                    )
            }
            
            it("starts with the correct item active if not default") {
                // Test config: Disappear After Send - 2 weeks
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
                
                // Should have 2 sections now: Disappearing Messages Type & Timer
                expect(viewModel.tableData.count)
                    .to(equal(2))
                
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
                                accessibility: Accessibility(
                                    identifier: "Disable disappearing messages (Off option)",
                                    label: "Disable disappearing messages (Off option)"
                                )
                            )
                        )
                    )
                
                expect(viewModel.tableData.first?.elements.last)
                    .to(
                        equal(
                            SessionCell.Info(
                                id: ThreadDisappearingMessagesSettingsViewModel.Item(
                                    title: "DISAPPERING_MESSAGES_TYPE_AFTER_SEND_TITLE".localized()
                                ),
                                title: "DISAPPERING_MESSAGES_TYPE_AFTER_SEND_TITLE".localized(),
                                subtitle: "DISAPPERING_MESSAGES_TYPE_AFTER_SEND_DESCRIPTION".localized(),
                                rightAccessory: .radio(
                                    isSelected: { true }
                                ),
                                accessibility: Accessibility(
                                    identifier: "Disappear after send option",
                                    label: "Disappear after send option"
                                )
                            )
                        )
                    )
                
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
                                accessibility: Accessibility(
                                    identifier: "Time option",
                                    label: "Time option"
                                )
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
                
                // TODO: Continue to work from here
                
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
