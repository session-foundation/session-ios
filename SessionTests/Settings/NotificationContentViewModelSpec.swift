// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Combine
import GRDB
import Quick
import Nimble
import SessionUtil
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
        @TestState var secretKey: [UInt8]! = Array(Data(hex: TestConstants.edSecretKey))
        @TestState var localConfig: LibSession.Config! = {
            var conf: UnsafeMutablePointer<config_object>!
            _ = user_groups_init(&conf, &secretKey, nil, 0, nil)
            
            return .local(conf)
        }()
        @TestState(cache: .libSession, in: dependencies) var mockLibSessionCache: MockLibSessionCache! = MockLibSessionCache(
            initialSetup: {
                $0.defaultInitialSetup(
                    configs: [
                        .local: localConfig
                    ]
                )
            }
        )
        @TestState var viewModel: NotificationContentViewModel! = TestState.create {
            await NotificationContentViewModel(using: dependencies)
        }
        @TestState var dataChangeCancellable: AnyCancellable? = viewModel.tableDataPublisher
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { viewModel.updateTableData($0) }
            )
        @TestState var dismissCancellable: AnyCancellable?
        
        // MARK: - a NotificationContentViewModel
        describe("a NotificationContentViewModel") {
            beforeEach {
                try await require { viewModel.tableData.count }.toEventually(beGreaterThan(0))
            }
            
            // MARK: -- has the correct title
            it("has the correct title") {
                await expect { await viewModel.title }.toEventually(equal("notificationsContent".localized()))
            }

            // MARK: -- has the correct number of items
            it("has the correct number of items") {
                expect(viewModel.tableData.count).to(equal(1))
                expect(viewModel.tableData.first?.elements.count).to(equal(3))
            }
            
            // MARK: -- has the correct default state
            it("has the correct default state") {
                expect(viewModel.tableData.first?.elements)
                    .to(
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
                    
                    dismissCancellable = await viewModel.navigatableState.dismissScreen
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
