// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Combine
import GRDB
import Quick
import Nimble

@testable import Session

class ThreadDisappearingMessagesViewModelSpec: QuickSpec {
    typealias ParentType = SessionTableViewModel<ThreadDisappearingMessagesViewModel.NavButton, ThreadDisappearingMessagesViewModel.Section, ThreadDisappearingMessagesViewModel.Item>
    
    // MARK: - Spec

    override func spec() {
        var mockStorage: Storage!
        var cancellables: [AnyCancellable] = []
        var dependencies: Dependencies!
        var viewModel: ThreadDisappearingMessagesViewModel!
        
        describe("a ThreadDisappearingMessagesViewModel") {
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
                viewModel = ThreadDisappearingMessagesViewModel(
                    dependencies: dependencies,
                    threadId: "TestId",
                    threadVariant: .contact,
                    currentUserIsClosedGroupAdmin: nil,
                    config: DisappearingMessagesConfiguration.defaultWith("TestId")
                )
                cancellables.append(
                    viewModel.observableSettingsData
                        .receiveOnMain(immediately: true)
                        .sink(
                            receiveCompletion: { _ in },
                            receiveValue: { viewModel.updateSettings($0) }
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
                expect(viewModel.settingsData.count)
                    .to(equal(1))
                expect(viewModel.settingsData.first?.elements.count)
                    .to(equal(3))
            }
            
            it("has the correct default state") {
                expect(viewModel.settingsData.first?.elements.first)
                    .to(
                        equal(
                            SessionCell.Info(
                                id: ThreadDisappearingMessagesViewModel.Item(
                                    title: "DISAPPEARING_MESSAGES_OFF".localized()
                                ),
                                title: "DISAPPEARING_MESSAGES_OFF".localized(),
                                rightAccessory: .radio(
                                    isSelected: { true }
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
                viewModel = ThreadDisappearingMessagesViewModel(
                    dependencies: dependencies,
                    threadId: "TestId",
                    threadVariant: .contact,
                    currentUserIsClosedGroupAdmin: nil,
                    config: config
                )
                cancellables.append(
                    viewModel.observableSettingsData
                        .receiveOnMain(immediately: true)
                        .sink(
                            receiveCompletion: { _ in },
                            receiveValue: { viewModel.updateSettings($0) }
                        )
                )
                
                expect(viewModel.settingsData.first?.elements.first)
                    .to(
                        equal(
                            SessionCell.Info(
                                id: ThreadDisappearingMessagesViewModel.Item(
                                    title: "DISAPPEARING_MESSAGES_OFF".localized()
                                ),
                                title: "DISAPPEARING_MESSAGES_OFF".localized(),
                                rightAccessory: .radio(
                                    isSelected: { false }
                                )
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
                expect(viewModel.settingsData.last?.elements.last)
                    .to(
                        equal(
                            SessionCell.Info(
                                id: ThreadDisappearingMessagesViewModel.Item(title: title),
                                title: title,
                                rightAccessory: .radio(
                                    isSelected: { true }
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
                
                expect(footerButtonInfo).to(equal(nil))
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
                    
                    viewModel.settingsData.first?.elements.last?.onTap?(nil)
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
