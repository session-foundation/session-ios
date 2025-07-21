// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Combine
import GRDB
import Quick
import Nimble
import SessionUIKit
import SessionSnodeKit
import SessionMessagingKit
import SessionUtilitiesKit

@testable import Session

class NotificationContentViewModelSpec: AsyncSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies { dependencies in
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
            using: dependencies
        )
        @TestState var viewModel: NotificationContentViewModel! = NotificationContentViewModel(
            using: dependencies
        )
        @TestState var dataChangeCancellable: AnyCancellable?
        @TestState var dismissCancellable: AnyCancellable?
        
        @MainActor
        func setupTestSubscriptions() {
            dataChangeCancellable = viewModel.tableDataPublisher
                .receive(on: ImmediateScheduler.shared)
                .sink(
                    receiveCompletion: { _ in },
                    receiveValue: { viewModel.updateTableData($0) }
                )
        }
        
        
        
        // MARK: - a NotificationContentViewModel
        describe("a NotificationContentViewModel") {
            beforeEach {
                await setupTestSubscriptions()
            }
            // MARK: -- has the correct title
            it("has the correct title") {
                await expect(viewModel.title).toEventually(equal("notificationsContent".localized()))
            }

            // MARK: -- has the correct number of items
            it("has the correct number of items") {
                await expect(viewModel.tableData.count).toEventually(equal(1))
                await expect(viewModel.tableData.first?.elements.count).toEventually(equal(3))
            }
            
            // MARK: -- has the correct default state
            it("has the correct default state") {
                await expect(viewModel.tableData.first?.elements)
                    .toEventually(
                        equal([
                            SessionCell.Info(
                                id: Preferences.NotificationPreviewType.nameAndPreview,
                                position: .top,
                                title: "notificationsContentShowNameAndContent".localized(),
                                trailingAccessory: .radio(
                                    isSelected: true
                                )
                            ),
                            SessionCell.Info(
                                id: Preferences.NotificationPreviewType.nameNoPreview,
                                position: .middle,
                                title: "notificationsContentShowNameOnly".localized(),
                                trailingAccessory: .radio(
                                    isSelected: false
                                )
                            ),
                            SessionCell.Info(
                                id: Preferences.NotificationPreviewType.noNameNoPreview,
                                position: .bottom,
                                title: "notificationsContentShowNoNameOrContent".localized(),
                                trailingAccessory: .radio(
                                    isSelected: false
                                )
                            )
                        ])
                    )
            }
            
            // MARK: -- starts with the correct item active if not default
            it("starts with the correct item active if not default") {
                mockStorage.write { db in
                    db[.preferencesNotificationPreviewType] = Preferences.NotificationPreviewType.nameNoPreview
                }
                viewModel = NotificationContentViewModel(using: dependencies)
                await setupTestSubscriptions()
                
                expect(viewModel.tableData.first?.elements)
                    .to(
                        equal([
                            SessionCell.Info(
                                id: Preferences.NotificationPreviewType.nameAndPreview,
                                position: .top,
                                title: "notificationsContentShowNameAndContent".localized(),
                                trailingAccessory: .radio(
                                    isSelected: false
                                )
                            ),
                            SessionCell.Info(
                                id: Preferences.NotificationPreviewType.nameNoPreview,
                                position: .middle,
                                title: "notificationsContentShowNameOnly".localized(),
                                trailingAccessory: .radio(
                                    isSelected: true
                                )
                            ),
                            SessionCell.Info(
                                id: Preferences.NotificationPreviewType.noNameNoPreview,
                                position: .bottom,
                                title: "notificationsContentShowNoNameOrContent".localized(),
                                trailingAccessory: .radio(
                                    isSelected: false
                                )
                            )
                        ])
                    )
            }
            
            // MARK: -- when tapping an item
            context("when tapping an item") {
                // MARK: ---- updates the saved preference
                it("updates the saved preference") {
                    await viewModel.tableData.first?.elements.last?.onTap?()
                    
                    await expect(dependencies[singleton: .storage, key: .preferencesNotificationPreviewType])
                        .toEventually(equal(Preferences.NotificationPreviewType.noNameNoPreview))
                }
                
                // MARK: ---- dismisses the screen
                it("dismisses the screen") {
                    var didDismissScreen: Bool = false
                    
                    dismissCancellable = viewModel.navigatableState.dismissScreen
                        .receive(on: ImmediateScheduler.shared)
                        .sink(
                            receiveCompletion: { _ in },
                            receiveValue: { _ in didDismissScreen = true }
                        )
                    await viewModel.tableData.first?.elements.last?.onTap?()
                    
                    expect(didDismissScreen).to(beTrue())
                }
            }
        }
    }
}
