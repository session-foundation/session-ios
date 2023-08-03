// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Combine
import GRDB
import Quick
import Nimble

import SessionUIKit
import SessionSnodeKit

@testable import Session

class NotificationContentViewModelSpec: QuickSpec {
    // MARK: - Spec

    override func spec() {
        var mockStorage: Storage!
        var dataChangeCancellable: AnyCancellable?
        var dismissCancellable: AnyCancellable?
        var viewModel: NotificationContentViewModel!
        
        describe("a NotificationContentViewModel") {
            // MARK: - Configuration
            
            beforeEach {
                mockStorage = SynchronousStorage(
                    customWriter: try! DatabaseQueue(),
                    customMigrationTargets: [
                        SNUtilitiesKit.self,
                        SNSnodeKit.self,
                        SNMessagingKit.self,
                        SNUIKit.self
                    ]
                )
                viewModel = NotificationContentViewModel(storage: mockStorage, scheduling: .immediate)
                dataChangeCancellable = viewModel.observableTableData
                    .receive(on: ImmediateScheduler.shared)
                    .sink(
                        receiveCompletion: { _ in },
                        receiveValue: { viewModel.updateTableData($0.0) }
                    )
            }
            
            afterEach {
                dataChangeCancellable?.cancel()
                dismissCancellable?.cancel()
                
                mockStorage = nil
                dataChangeCancellable = nil
                dismissCancellable = nil
                viewModel = nil
            }
            
            // MARK: - Basic Tests
            
            it("has the correct title") {
                expect(viewModel.title).to(equal("NOTIFICATIONS_STYLE_CONTENT_TITLE".localized()))
            }

            it("has the correct number of items") {
                expect(viewModel.tableData.count)
                    .to(equal(1))
                expect(viewModel.tableData.first?.elements.count)
                    .to(equal(3))
            }
            
            it("has the correct default state") {
                expect(viewModel.tableData.first?.elements)
                    .to(
                        equal([
                            SessionCell.Info(
                                id: Preferences.NotificationPreviewType.nameAndPreview,
                                position: .top,
                                title: "NOTIFICATIONS_STYLE_CONTENT_OPTION_NAME_AND_CONTENT".localized(),
                                rightAccessory: .radio(
                                    isSelected: { true }
                                )
                            ),
                            SessionCell.Info(
                                id: Preferences.NotificationPreviewType.nameNoPreview,
                                position: .middle,
                                title: "NOTIFICATIONS_STYLE_CONTENT_OPTION_NAME_ONLY".localized(),
                                rightAccessory: .radio(
                                    isSelected: { false }
                                )
                            ),
                            SessionCell.Info(
                                id: Preferences.NotificationPreviewType.noNameNoPreview,
                                position: .bottom,
                                title: "NOTIFICATIONS_STYLE_CONTENT_OPTION_NO_NAME_OR_CONTENT".localized(),
                                rightAccessory: .radio(
                                    isSelected: { false }
                                )
                            )
                        ])
                    )
            }
            
            it("starts with the correct item active if not default") {
                mockStorage.write { db in
                    db[.preferencesNotificationPreviewType] = Preferences.NotificationPreviewType.nameNoPreview
                }
                viewModel = NotificationContentViewModel(storage: mockStorage, scheduling: .immediate)
                dataChangeCancellable = viewModel.observableTableData
                    .receive(on: ImmediateScheduler.shared)
                    .sink(
                        receiveCompletion: { _ in },
                        receiveValue: { viewModel.updateTableData($0.0) }
                    )
                
                expect(viewModel.tableData.first?.elements)
                    .to(
                        equal([
                            SessionCell.Info(
                                id: Preferences.NotificationPreviewType.nameAndPreview,
                                position: .top,
                                title: "NOTIFICATIONS_STYLE_CONTENT_OPTION_NAME_AND_CONTENT".localized(),
                                rightAccessory: .radio(
                                    isSelected: { false }
                                )
                            ),
                            SessionCell.Info(
                                id: Preferences.NotificationPreviewType.nameNoPreview,
                                position: .middle,
                                title: "NOTIFICATIONS_STYLE_CONTENT_OPTION_NAME_ONLY".localized(),
                                rightAccessory: .radio(
                                    isSelected: { true }
                                )
                            ),
                            SessionCell.Info(
                                id: Preferences.NotificationPreviewType.noNameNoPreview,
                                position: .bottom,
                                title: "NOTIFICATIONS_STYLE_CONTENT_OPTION_NO_NAME_OR_CONTENT".localized(),
                                rightAccessory: .radio(
                                    isSelected: { false }
                                )
                            )
                        ])
                    )
            }
            
            context("when tapping an item") {
                it("updates the saved preference") {
                    viewModel.tableData.first?.elements.last?.onTap?()
                    
                    expect(mockStorage[.preferencesNotificationPreviewType])
                        .to(equal(Preferences.NotificationPreviewType.noNameNoPreview))
                }
                
                it("dismisses the screen") {
                    var didDismissScreen: Bool = false
                    
                    dismissCancellable = viewModel.dismissScreen
                        .receive(on: ImmediateScheduler.shared)
                        .sink(
                            receiveCompletion: { _ in },
                            receiveValue: { _ in didDismissScreen = true }
                        )
                    viewModel.tableData.first?.elements.last?.onTap?()
                    
                    expect(didDismissScreen).to(beTrue())
                }
            }
        }
    }
}
