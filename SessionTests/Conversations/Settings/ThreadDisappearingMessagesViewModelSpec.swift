// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Combine
import GRDB
import Quick
import Nimble
import SessionUIKit
import SessionNetworkingKit
import SessionMessagingKit
import SessionUtilitiesKit

@testable import Session

class ThreadDisappearingMessagesSettingsViewModelSpec: AsyncSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies { dependencies in
            dependencies.forceSynchronous = true
            dependencies[singleton: .scheduler] = .immediate
        }
        @TestState var mockStorage: Storage! = try! Storage.createForTesting(using: dependencies)
        @TestState var mockJobRunner: MockJobRunner! = .create(using: dependencies)
        @TestState var viewModel: ThreadDisappearingMessagesSettingsViewModel!
        @TestState var cancellables: [AnyCancellable]!
        
        beforeEach {
            dependencies.set(singleton: .storage, to: mockStorage)
            try await mockStorage.perform(migrations: SNMessagingKit.migrations)
            try await mockStorage.write { db in
                try SessionThread(
                    id: "TestId",
                    variant: .contact,
                    creationDateTimestamp: 0
                ).insert(db)
            }
            
            dependencies.set(singleton: .jobRunner, to: mockJobRunner)
            try await mockJobRunner
                .when { $0.add(.any, job: .any, initialDependencies: .any) }
                .thenReturn(nil)
            try await mockJobRunner
                .when { await $0.jobsMatching(filters: .any) }
                .thenReturn([:])
            
            /// **Note:** The sink captures this *instance* rather than the `viewModel` variable. Some examples below replace
            /// `viewModel` with a second instance, and capturing the variable meant this subscription kept feeding whichever
            /// instance was current - so the first view model's emissions were applied to the second one, letting a stale value
            /// overwrite the state under test.
            let initialViewModel: ThreadDisappearingMessagesSettingsViewModel = await ThreadDisappearingMessagesSettingsViewModel(
                threadId: "TestId",
                threadVariant: .contact,
                currentUserRole: nil,
                config: DisappearingMessagesConfiguration.defaultWith("TestId"),
                using: dependencies
            )
            viewModel = initialViewModel
            cancellables = [
                initialViewModel.tableDataPublisher
                    .receive(on: ImmediateScheduler.shared)
                    .sink(
                        receiveCompletion: { _ in },
                        receiveValue: { initialViewModel.updateTableData($0) }
                    )
            ]
        }
        
        // MARK: - a ThreadDisappearingMessagesSettingsViewModel
        describe("a ThreadDisappearingMessagesSettingsViewModel") {
            // MARK: -- has the correct title
            it("has the correct title") {
                expect(viewModel.title).to(equal("disappearingMessages".localized()))
            }
            
            // MARK: -- has the correct number of items
            it("has the correct number of items") {
                // The default disappearing messages configure is Off
                // Should only show one section of Disappearing Messages Type
                await expect(viewModel.tableData)
                    .toEventually(haveCount(1), timeout: .milliseconds(100))
                
                // Off
                // Disappear After Read
                // Disappear After Send
                expect(viewModel.tableData.first?.elements.count).to(equal(3))
            }
            
            // MARK: -- has the correct default state
            it("has the correct default state") {
                await expect(viewModel.tableData)
                    .toEventually(haveCount(1), timeout: .milliseconds(100))
                
                // First option is always Off
                expect(viewModel.tableData.first?.elements.first)
                    .to(
                        equal(
                            SessionCell.Info(
                                id: "off".localized(),
                                position: .top,
                                title: "off".localized(),
                                trailingAccessory: .radio(
                                    isSelected: true,
                                    accessibility: Accessibility(
                                        identifier: "Off - Radio"
                                    )
                                ),
                                accessibility: Accessibility(
                                    identifier: "Disable disappearing messages (Off option)",
                                    label: "Disable disappearing messages (Off option)"
                                )
                            )
                        )
                    )
                // Last option is always Disappear After Send
                expect(viewModel.tableData.first?.elements.last)
                    .to(
                        equal(
                            SessionCell.Info(
                                id: "disappearingMessagesDisappearAfterSend".localized(),
                                position: .bottom,
                                title: "disappearingMessagesDisappearAfterSend".localized(),
                                subtitle: "disappearingMessagesDisappearAfterSendDescription".localized(),
                                trailingAccessory: .radio(
                                    isSelected: false,
                                    accessibility: Accessibility(
                                        identifier: "Disappear After Send - Radio"
                                    )
                                ),
                                accessibility: Accessibility(
                                    identifier: "Disappear after send option",
                                    label: "Disappear after send option"
                                )
                            )
                        )
                    )
            }
            
            // MARK: -- starts with the correct item active if not default
            it("starts with the correct item active if not default") {
                // Test config: Disappear After Send - 2 weeks
                let config: DisappearingMessagesConfiguration = DisappearingMessagesConfiguration
                    .defaultWith("TestId")
                    .with(
                        isEnabled: true,
                        durationSeconds: DisappearingMessagesConfiguration
                            .validDurationsSeconds(.disappearAfterSend, using: dependencies)
                            .last,
                        type: .disappearAfterSend
                    )
                try await mockStorage.write { db in
                    try config.upserted(db)
                }
                /// **Note:** Capture this *instance* in the sink rather than the `viewModel` variable - see the note in `beforeEach`
                let updatedViewModel: ThreadDisappearingMessagesSettingsViewModel = await ThreadDisappearingMessagesSettingsViewModel(
                    threadId: "TestId",
                    threadVariant: .contact,
                    currentUserRole: nil,
                    config: config,
                    using: dependencies
                )
                viewModel = updatedViewModel
                cancellables.append(
                    updatedViewModel.tableDataPublisher
                        .receive(on: ImmediateScheduler.shared)
                        .sink(
                            receiveCompletion: { _ in },
                            receiveValue: { updatedViewModel.updateTableData($0) }
                        )
                )
                
                // Should have 2 sections now: Disappearing Messages Type & Timer
                await expect(viewModel.tableData)
                    .toEventually(haveCount(2), timeout: .milliseconds(100))
                
                expect(viewModel.tableData.first?.elements.first)
                    .to(
                        equal(
                            SessionCell.Info(
                                id: "off".localized(),
                                position: .top,
                                title: "off".localized(),
                                trailingAccessory: .radio(
                                    isSelected: false,
                                    accessibility: Accessibility(
                                        identifier: "Off - Radio"
                                    )
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
                                id: "disappearingMessagesDisappearAfterSend".localized(),
                                position: .bottom,
                                title: "disappearingMessagesDisappearAfterSend".localized(),
                                subtitle: "disappearingMessagesDisappearAfterSendDescription".localized(),
                                trailingAccessory: .radio(
                                    isSelected: true,
                                    accessibility: Accessibility(
                                        identifier: "Disappear After Send - Radio"
                                    )
                                ),
                                accessibility: Accessibility(
                                    identifier: "Disappear after send option",
                                    label: "Disappear after send option"
                                )
                            )
                        )
                    )
                
                let title: String = (DisappearingMessagesConfiguration
                    .validDurationsSeconds(.disappearAfterSend, using: dependencies)
                    .last?
                    .formatted(format: .long))
                    .defaulting(to: "")
                expect(viewModel.tableData.last?.elements.last)
                    .to(
                        equal(
                            SessionCell.Info(
                                id: title,
                                position: .bottom,
                                title: title,
                                trailingAccessory: .radio(
                                    isSelected: true,
                                    accessibility: Accessibility(
                                        identifier: "2 weeks - Radio"
                                    )
                                ),
                                accessibility: Accessibility(
                                    identifier: "Time option",
                                    label: "Time option"
                                )
                            )
                        )
                    )
            }
            
            // MARK: -- has no footer button
            it("has no footer button") {
                var footerButtonInfo: SessionButton.Info?
                
                await expect(viewModel.tableData)
                    .toEventually(haveCount(1), timeout: .milliseconds(100))
                
                cancellables.append(
                    viewModel.footerButtonInfo
                        .receive(on: ImmediateScheduler.shared)
                        .sink(
                            receiveCompletion: { _ in },
                            receiveValue: { info in footerButtonInfo = info }
                        )
                )
                
                expect(footerButtonInfo).to(beNil())
            }
            
            // MARK: -- can change to another setting and change back
            it("can change to another setting and change back") {
                // Test config: Disappear After Send - 2 weeks
                let config: DisappearingMessagesConfiguration = DisappearingMessagesConfiguration
                    .defaultWith("TestId")
                    .with(
                        isEnabled: true,
                        durationSeconds: DisappearingMessagesConfiguration
                            .validDurationsSeconds(.disappearAfterSend, using: dependencies)
                            .last,
                        type: .disappearAfterSend
                    )
                try await mockStorage.write { db in
                    try config.upserted(db)
                }
                /// **Note:** Capture this *instance* in the sink rather than the `viewModel` variable - see the note in `beforeEach`
                let updatedViewModel: ThreadDisappearingMessagesSettingsViewModel = await ThreadDisappearingMessagesSettingsViewModel(
                    threadId: "TestId",
                    threadVariant: .contact,
                    currentUserRole: nil,
                    config: config,
                    using: dependencies
                )
                viewModel = updatedViewModel
                cancellables.append(
                    updatedViewModel.tableDataPublisher
                        .receive(on: ImmediateScheduler.shared)
                        .sink(
                            receiveCompletion: { _ in },
                            receiveValue: { updatedViewModel.updateTableData($0) }
                        )
                )
                
                await expect(viewModel.tableData)
                    .toEventually(haveCount(2), timeout: .milliseconds(100))
                
                /// Change to Off, wait for 1 section with no footer button
                ///
                /// **Note:** We wait until the tapped option is actually *selected* rather than just until the section count
                /// changes. `haveCount` is satisfied by the first emission that happens to have the right number of sections,
                /// and the test then reads and taps again immediately with no margin - so a subsequent emission can replace the
                /// element between the check and the next read, leaving that tap to silently no-op through the optional chain
                /// and stranding the following wait. Requiring the tap target makes that case fail loudly instead of as a
                /// confusing timeout.
                let offOption: SessionCell.Info<String> = try require(viewModel.tableData.first?.elements.first)
                    .toNot(beNil())
                let offTap: @MainActor () -> Void = try require(offOption.onTap).toNot(beNil())
                await offTap()
                await expect { viewModel.tableData.first?.elements.first?.isRadioSelected }
                    .toEventually(beTrue(), timeout: .milliseconds(100))
                expect(viewModel.tableData).to(haveCount(1))

                /// Change back, wait for 2 sections to confirm timer section is present
                let sendOption: SessionCell.Info<String> = try require(viewModel.tableData.first?.elements.last)
                    .toNot(beNil())
                let sendTap: @MainActor () -> Void = try require(sendOption.onTap).toNot(beNil())
                await sendTap()
                await expect { viewModel.tableData.first?.elements.last?.isRadioSelected }
                    .toEventually(beTrue(), timeout: .milliseconds(100))
                await expect { viewModel.tableData }
                    .toEventually(haveCount(2), timeout: .milliseconds(100))
                
                await expect { viewModel.tableData.first?.elements.last }
                    .toEventually(
                        equal(
                            SessionCell.Info(
                                id: "disappearingMessagesDisappearAfterSend".localized(),
                                position: .bottom,
                                title: "disappearingMessagesDisappearAfterSend".localized(),
                                subtitle: "disappearingMessagesDisappearAfterSendDescription".localized(),
                                trailingAccessory: .radio(
                                    isSelected: true,
                                    accessibility: Accessibility(
                                        identifier: "Disappear After Send - Radio"
                                    )
                                ),
                                accessibility: Accessibility(
                                    identifier: "Disappear after send option",
                                    label: "Disappear after send option"
                                )
                            )
                        ),
                        timeout: .milliseconds(100)
                    )
                
                let title: String = (DisappearingMessagesConfiguration
                    .validDurationsSeconds(.disappearAfterSend, using: dependencies)
                    .last?
                    .formatted(format: .long))
                    .defaulting(to: "")
                await expect { viewModel.tableData.last?.elements.last }
                    .toEventually(
                        equal(
                            SessionCell.Info(
                                id: title,
                                position: .bottom,
                                title: title,
                                trailingAccessory: .radio(
                                    isSelected: true,
                                    accessibility: Accessibility(
                                        identifier: "2 weeks - Radio"
                                    )
                                ),
                                accessibility: Accessibility(
                                    identifier: "Time option",
                                    label: "Time option"
                                )
                            )
                        ),
                        timeout: .milliseconds(100)
                    )
                
                var footerButtonInfo: SessionButton.Info?
                
                cancellables.append(
                    viewModel.footerButtonInfo
                        .receive(on: ImmediateScheduler.shared)
                        .sink(
                            receiveCompletion: { _ in },
                            receiveValue: { info in footerButtonInfo = info }
                        )
                )
                
                await expect { footerButtonInfo }.toEventually(beNil(), timeout: .milliseconds(100))
            }
            
            // MARK: -- when changed from the previous setting
            context("when changed from the previous setting") {
                @TestState var footerButtonInfo: SessionButton.Info?
                
                beforeEach {
                    await expect { viewModel.tableData }
                        .toEventually(haveCount(1), timeout: .milliseconds(100))
                    
                    cancellables.append(
                        viewModel.footerButtonInfo
                            .receive(on: ImmediateScheduler.shared)
                            .sink(
                                receiveCompletion: { _ in },
                                receiveValue: { info in footerButtonInfo = info }
                            )
                    )
                    
                    let tapTarget: SessionCell.Info<String> = try require(viewModel.tableData.first?.elements.last)
                        .toNot(beNil())
                    let tapAction: @MainActor () -> Void = try require(tapTarget.onTap).toNot(beNil())
                    await tapAction()
                    await expect { viewModel.tableData }
                        .toEventually(haveCount(2), timeout: .milliseconds(100))
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
                        
                        await MainActor.run { [footerButtonInfo] in footerButtonInfo?.onTap() }
                        
                        await expect { didDismissScreen }
                            .toEventually(beTrue(), timeout: .milliseconds(100))
                    }
                    
                    // MARK: ------ saves the updated config
                    it("saves the updated config") {
                        await MainActor.run { [footerButtonInfo] in footerButtonInfo?.onTap() }
                        
                        let updatedConfig: DisappearingMessagesConfiguration? = try await require {
                            try await mockStorage.read { db in
                                try DisappearingMessagesConfiguration.fetchOne(db, id: "TestId")
                            }
                        }.toEventuallyNot(beNil(), timeout: .milliseconds(100))
                        
                        expect(updatedConfig?.isEnabled).to(beTrue())
                        expect(updatedConfig?.durationSeconds)
                            .to(equal(DisappearingMessagesConfiguration.DefaultDuration.disappearAfterSend.seconds))
                        expect(updatedConfig?.type).to(equal(.disappearAfterSend))
                    }
                }
            }
        }
    }
}

// MARK: - Convenience

private extension SessionCell.Info {
    /// Whether this cell's trailing radio is currently selected
    ///
    /// **Note:** Test-only helper. It lets a spec wait on the *settled* selection state rather than on a section count -
    /// `haveCount` is satisfied by the first emission with the expected number of sections, which isn't necessarily the final
    /// one, so tapping straight after a count check can race a later emission.
    var isRadioSelected: Bool {
        return ((trailingAccessory as? SessionCell.AccessoryConfig.Radio)?.isSelected == true)
    }
}
