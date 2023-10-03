// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Combine
import GRDB
import Quick
import Nimble
import SessionUIKit
import SessionSnodeKit
import SessionUtilitiesKit

@testable import Session

class ThreadDisappearingMessagesSettingsViewModelSpec: QuickSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var mockStorage: Storage! = SynchronousStorage(
            customWriter: try! DatabaseQueue(),
            migrationTargets: [
                SNUtilitiesKit.self,
                SNSnodeKit.self,
                SNMessagingKit.self,
                SNUIKit.self
            ],
            initialData: { db in
                try SessionThread(
                    id: "TestId",
                    variant: .contact
                ).insert(db)
            }
        )
        @TestState var dependencies: Dependencies! = Dependencies(
            storage: mockStorage,
            scheduler: .immediate
        )
        @TestState var viewModel: ThreadDisappearingMessagesSettingsViewModel! = ThreadDisappearingMessagesSettingsViewModel(
            threadId: "TestId",
            threadVariant: .contact,
            config: DisappearingMessagesConfiguration.defaultWith("TestId"),
            using: dependencies
        )
        
        @TestState var cancellables: [AnyCancellable]! = [
            viewModel.observableTableData
                .receive(on: ImmediateScheduler.shared)
                .sink(
                    receiveCompletion: { _ in },
                    receiveValue: { viewModel.updateTableData($0.0) }
                )
        ]
        
        // MARK: - a ThreadDisappearingMessagesSettingsViewModel
        describe("a ThreadDisappearingMessagesSettingsViewModel") {
            // MARK: -- has the correct title
            it("has the correct title") {
                expect(viewModel.title).to(equal("DISAPPEARING_MESSAGES".localized()))
            }
            
            // MARK: -- has the correct number of items
            it("has the correct number of items") {
                expect(viewModel.tableData.count).to(equal(1))
                expect(viewModel.tableData.first?.elements.count).to(equal(12))
            }
            
            // MARK: -- has the correct default state
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
                                )
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
            }
            
            // MARK: -- starts with the correct item active if not default
            it("starts with the correct item active if not default") {
                let config: DisappearingMessagesConfiguration = DisappearingMessagesConfiguration
                    .defaultWith("TestId")
                    .with(
                        isEnabled: true,
                        durationSeconds: DisappearingMessagesConfiguration.validDurationsSeconds.last
                    )
                mockStorage.write { db in
                    _ = try config.saved(db)
                }
                viewModel = ThreadDisappearingMessagesSettingsViewModel(
                    threadId: "TestId",
                    threadVariant: .contact,
                    config: config,
                    using: dependencies
                )
                cancellables.append(
                    viewModel.observableTableData
                        .receive(on: ImmediateScheduler.shared)
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
                                )
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
                                    isSelected: { true }
                                )
                            )
                        )
                    )
            }
            
            // MARK: -- has no right bar button
            it("has no right bar button") {
                var items: [ParentType.NavItem]?
                
                cancellables.append(
                    viewModel.rightNavItems
                        .receive(on: ImmediateScheduler.shared)
                        .sink(
                            receiveCompletion: { _ in },
                            receiveValue: { navItems in items = navItems }
                        )
                )
                
                expect(items).to(equal([]))
            }
            
            // MARK: -- when changed from the previous setting
            context("when changed from the previous setting") {
                @TestState var items: [ParentType.NavItem]?
                
                beforeEach {
                    cancellables.append(
                        viewModel.rightNavItems
                            .receive(on: ImmediateScheduler.shared)
                            .sink(
                                receiveCompletion: { _ in },
                                receiveValue: { navItems in items = navItems }
                            )
                    )
                    
                    viewModel.tableData.first?.elements.last?.onTap?()
                }
                
                // MARK: ---- shows the save button
                it("shows the save button") {
                    expect(items)
                        .to(equal([
                            ParentType.NavItem(
                                id: .save,
                                systemItem: .save,
                                accessibilityIdentifier: "Save button"
                            )
                        ]))
                }
                
                // MARK: ---- and saving
                context("and saving") {
                    // MARK: ------ dismisses the screen
                    it("dismisses the screen") {
                        var didDismissScreen: Bool = false
                        
                        cancellables.append(
                            viewModel.dismissScreen
                                .receive(on: ImmediateScheduler.shared)
                                .sink(
                                    receiveCompletion: { _ in },
                                    receiveValue: { _ in didDismissScreen = true }
                                )
                        )
                        
                        items?.first?.action?()
                        
                        expect(didDismissScreen).to(beTrue())
                    }
                    
                    // MARK: ------ saves the updated config
                    it("saves the updated config") {
                        items?.first?.action?()
                        
                        let updatedConfig: DisappearingMessagesConfiguration? = mockStorage.read { db in
                            try DisappearingMessagesConfiguration.fetchOne(db, id: "TestId")
                        }
                        
                        expect(updatedConfig?.isEnabled).to(beTrue())
                        expect(updatedConfig?.durationSeconds)
                            .to(equal(DisappearingMessagesConfiguration.validDurationsSeconds.last ?? -1))
                    }
                }
            }
        }
    }
}

// MARK: - Test Types

fileprivate typealias ParentType = SessionTableViewModel<ThreadDisappearingMessagesSettingsViewModel.NavButton, ThreadDisappearingMessagesSettingsViewModel.Section, ThreadDisappearingMessagesSettingsViewModel.Item>
