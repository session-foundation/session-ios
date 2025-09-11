// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Combine
import GRDB
import Quick
import Nimble
import SessionUtil
import SessionUIKit
import SessionNetworkingKit
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
            using: dependencies
        )
        @TestState var secretKey: [UInt8]! = Array(Data(hex: TestConstants.edSecretKey))
        @TestState var localConfig: LibSession.Config! = {
            var conf: UnsafeMutablePointer<config_object>!
            _ = user_groups_init(&conf, &secretKey, nil, 0, nil)
            
            return .local(conf)
        }()
        @TestState var mockLibSessionCache: MockLibSessionCache! = MockLibSessionCache()
        @TestState var viewModel: NotificationContentViewModel!
        @TestState var dataChangeCancellable: AnyCancellable?
        @TestState var dismissCancellable: AnyCancellable?
        
        beforeEach {
            /// The compiler kept crashing when doing this via `@TestState` so need to do it here instead
            mockLibSessionCache.defaultInitialSetup(
                configs: [
                    .local: localConfig
                ]
            )
            dependencies.set(cache: .libSession, to: mockLibSessionCache)
            
            try await mockStorage.perform(migrations: SNMessagingKit.migrations)
            
            viewModel = await NotificationContentViewModel(using: dependencies)
            dataChangeCancellable = viewModel.tableDataPublisher
               .sink(
                   receiveCompletion: { _ in },
                   receiveValue: { viewModel.updateTableData($0) }
               )
        }
        
        // MARK: - a NotificationContentViewModel
        describe("a NotificationContentViewModel") {
            beforeEach {
                try await require { viewModel.tableData.count }.toEventually(beGreaterThan(0))
            }
            
            // MARK: -- has the correct title
            it("has the correct title") {
                expect(viewModel.title).to(equal("notificationsContent".localized()))
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
                mockLibSessionCache
                    .when { $0.get(.preferencesNotificationPreviewType) }
                    .thenReturn(Preferences.NotificationPreviewType.nameNoPreview)
                viewModel = await NotificationContentViewModel(using: dependencies)
                dataChangeCancellable = viewModel.tableDataPublisher
                    .sink(
                        receiveCompletion: { _ in },
                        receiveValue: { viewModel.updateTableData($0) }
                    )
                try await require { viewModel.tableData.count }.toEventually(beGreaterThan(0))
                
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
                    
                    await expect(mockLibSessionCache).toEventually(call(.exactly(times: 1), matchingParameters: .all) {
                        $0.set(.preferencesNotificationPreviewType, Preferences.NotificationPreviewType.noNameNoPreview)
                    })
                }
                
                // MARK: ---- dismisses the screen
                it("dismisses the screen") {
                    var didDismissScreen: Bool = false
                    
                    dismissCancellable = viewModel.navigatableState.dismissScreen
                        .sink(
                            receiveCompletion: { _ in },
                            receiveValue: { _ in didDismissScreen = true }
                        )
                    await viewModel.tableData.first?.elements.last?.onTap?()
                    
                    await expect(didDismissScreen).toEventually(beTrue())
                }
            }
        }
    }
}
