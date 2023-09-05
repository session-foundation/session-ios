// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Combine
import GRDB
import Quick
import Nimble
import SessionUIKit
import SessionSnodeKit
import SessionUtilitiesKit

@testable import Session

class ThreadSettingsViewModelSpec: QuickSpec {
    typealias ParentType = SessionTableViewModel<ThreadSettingsViewModel.NavButton, ThreadSettingsViewModel.Section, ThreadSettingsViewModel.Setting>
    
    // MARK: - Spec
    
    override func spec() {
        var mockStorage: Storage!
        var mockCaches: MockCaches!
        var mockGeneralCache: MockGeneralCache!
        var disposables: [AnyCancellable] = []
        var dependencies: Dependencies!
        var viewModel: ThreadSettingsViewModel!
        var didTriggerSearchCallbackTriggered: Bool = false
        
        describe("a ThreadSettingsViewModel") {
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
                mockCaches = MockCaches()
                mockGeneralCache = MockGeneralCache()
                dependencies = Dependencies(
                    storage: mockStorage,
                    caches: mockCaches,
                    scheduler: .immediate
                )
                mockCaches[.general] = mockGeneralCache
                mockGeneralCache.when { $0.encodedPublicKey }.thenReturn("05\(TestConstants.publicKey)")
                mockStorage.write { db in
                    try SessionThread(
                        id: "TestId",
                        variant: .contact
                    ).insert(db)
                    
                    try Identity(
                        variant: .x25519PublicKey,
                        data: Data(hex: TestConstants.publicKey)
                    ).insert(db)
                    
                    try Profile(
                        id: "05\(TestConstants.publicKey)",
                        name: "TestMe",
                        lastNameUpdate: 0,
                        lastProfilePictureUpdate: 0,
                        lastBlocksCommunityMessageRequests: 0
                    ).insert(db)
                    
                    try Profile(
                        id: "TestId",
                        name: "TestUser",
                        lastNameUpdate: 0,
                        lastProfilePictureUpdate: 0,
                        lastBlocksCommunityMessageRequests: 0
                    ).insert(db)
                }
                viewModel = ThreadSettingsViewModel(
                    threadId: "TestId",
                    threadVariant: .contact,
                    didTriggerSearch: {
                        didTriggerSearchCallbackTriggered = true
                    },
                    using: dependencies
                )
                disposables.append(
                    viewModel.observableTableData
                        .receive(on: ImmediateScheduler.shared)
                        .sink(
                            receiveCompletion: { _ in },
                            receiveValue: { viewModel.updateTableData($0.0) }
                        )
                )
            }
            
            afterEach {
                disposables.forEach { $0.cancel() }
                
                mockStorage = nil
                disposables = []
                dependencies = nil
                viewModel = nil
                didTriggerSearchCallbackTriggered = false
            }
            
            // MARK: - Basic Tests
            
            context("with any conversation type") {
                it("triggers the search callback when tapping search") {
                    viewModel.tableData
                        .first(where: { $0.model == .content })?
                        .elements
                        .first(where: { $0.id == .searchConversation })?
                        .onTap?()
                    
                    expect(didTriggerSearchCallbackTriggered).to(beTrue())
                }
                
                it("mutes a conversation") {
                    viewModel.tableData
                        .first(where: { $0.model == .content })?
                        .elements
                        .first(where: { $0.id == .notificationMute })?
                        .onTap?()
                    
                    expect(
                        mockStorage
                            .read { db in try SessionThread.fetchOne(db, id: "TestId") }?
                            .mutedUntilTimestamp
                    )
                    .toNot(beNil())
                }
                
                it("unmutes a conversation") {
                    mockStorage.write { db in
                        try SessionThread
                            .updateAll(
                                db,
                                SessionThread.Columns.mutedUntilTimestamp.set(to: 1234567890)
                            )
                    }
                    
                    expect(
                        mockStorage
                            .read { db in try SessionThread.fetchOne(db, id: "TestId") }?
                            .mutedUntilTimestamp
                    )
                    .toNot(beNil())
                    
                    viewModel.tableData
                        .first(where: { $0.model == .content })?
                        .elements
                        .first(where: { $0.id == .notificationMute })?
                        .onTap?()
                
                    expect(
                        mockStorage
                            .read { db in try SessionThread.fetchOne(db, id: "TestId") }?
                            .mutedUntilTimestamp
                    )
                    .to(beNil())
                }
            }
            
            context("with a note-to-self conversation") {
                beforeEach {
                    mockStorage.write { db in
                        try SessionThread.deleteAll(db)
                        
                        try SessionThread(
                            id: "05\(TestConstants.publicKey)",
                            variant: .contact
                        ).insert(db)
                    }
                    
                    viewModel = ThreadSettingsViewModel(
                        threadId: "05\(TestConstants.publicKey)",
                        threadVariant: .contact,
                        didTriggerSearch: {
                            didTriggerSearchCallbackTriggered = true
                        },
                        using: dependencies
                    )
                    disposables.append(
                        viewModel.observableTableData
                            .receive(on: ImmediateScheduler.shared)
                            .sink(
                                receiveCompletion: { _ in },
                                receiveValue: { viewModel.updateTableData($0.0) }
                            )
                    )
                }
                
                it("has the correct title") {
                    expect(viewModel.title).to(equal("vc_settings_title".localized()))
                }
                
                it("starts in the standard nav state") {
                    expect(viewModel.navState.firstValue())
                        .to(equal(.standard))
                    
                    expect(viewModel.leftNavItems.firstValue()).to(equal([]))
                    expect(viewModel.rightNavItems.firstValue())
                        .to(equal([
                            ParentType.NavItem(
                                id: .edit,
                                systemItem: .edit,
                                accessibilityIdentifier: "Edit button"
                            )
                        ]))
                }
                
                it("has no mute button") {
                    expect(
                        viewModel.tableData
                            .first(where: { $0.model == .content })?
                            .elements
                            .first(where: { $0.id == .notificationMute })
                    ).to(beNil())
                }
                
                context("when entering edit mode") {
                    beforeEach {
                        viewModel.navState.sinkAndStore(in: &disposables)
                        viewModel.rightNavItems.firstValue()??.first?.action?()
                        viewModel.textChanged("TestNew", for: .nickname)
                    }
                    
                    it("enters the editing state") {
                        expect(viewModel.navState.firstValue())
                            .to(equal(.editing))
                        
                        expect(viewModel.leftNavItems.firstValue())
                            .to(equal([
                                ParentType.NavItem(
                                    id: .cancel,
                                    systemItem: .cancel,
                                    accessibilityIdentifier: "Cancel button"
                                )
                            ]))
                        expect(viewModel.rightNavItems.firstValue())
                            .to(equal([
                                ParentType.NavItem(
                                    id: .done,
                                    systemItem: .done,
                                    accessibilityIdentifier: "Done"
                                )
                            ]))
                    }
                    
                    context("when cancelling edit mode") {
                        beforeEach {
                            viewModel.leftNavItems.firstValue()??.first?.action?()
                        }
                        
                        it("exits editing mode") {
                            expect(viewModel.navState.firstValue())
                                .to(equal(.standard))
                            
                            expect(viewModel.leftNavItems.firstValue()).to(equal([]))
                            expect(viewModel.rightNavItems.firstValue())
                                .to(equal([
                                    ParentType.NavItem(
                                        id: .edit,
                                        systemItem: .edit,
                                        accessibilityIdentifier: "Edit button"
                                    )
                                ]))
                        }
                        
                        it("does not update the nickname for the current user") {
                            expect(
                                mockStorage
                                    .read { db in
                                        try Profile.fetchOne(db, id: "05\(TestConstants.publicKey)")
                                    }?
                                    .nickname
                            )
                            .to(beNil())
                        }
                    }
                    
                    context("when saving edit mode") {
                        beforeEach {
                            viewModel.rightNavItems.firstValue()??.first?.action?()
                        }
                        
                        it("exits editing mode") {
                            expect(viewModel.navState.firstValue())
                                .to(equal(.standard))
                            
                            expect(viewModel.leftNavItems.firstValue()).to(equal([]))
                            expect(viewModel.rightNavItems.firstValue())
                                .to(equal([
                                    ParentType.NavItem(
                                        id: .edit,
                                        systemItem: .edit,
                                        accessibilityIdentifier: "Edit button"
                                    )
                                ]))
                        }
                        
                        it("updates the nickname for the current user") {
                            expect(
                                mockStorage
                                    .read { db in
                                        try Profile.fetchOne(db, id: "05\(TestConstants.publicKey)")
                                    }?
                                    .nickname
                            )
                            .to(equal("TestNew"))
                        }
                    }
                }
            }
            
            context("with a one-to-one conversation") {
                beforeEach {
                    mockStorage.write { db in
                        try SessionThread.deleteAll(db)
                        
                        try SessionThread(
                            id: "TestId",
                            variant: .contact
                        ).insert(db)
                    }
                }
                
                it("has the correct title") {
                    expect(viewModel.title).to(equal("vc_settings_title".localized()))
                }
                
                it("starts in the standard nav state") {
                    expect(viewModel.navState.firstValue())
                        .to(equal(.standard))
                    
                    expect(viewModel.leftNavItems.firstValue()).to(equal([]))
                    expect(viewModel.rightNavItems.firstValue())
                        .to(equal([
                            ParentType.NavItem(
                                id: .edit,
                                systemItem: .edit,
                                accessibilityIdentifier: "Edit button"
                            )
                        ]))
                }
                
                context("when entering edit mode") {
                    beforeEach {
                        viewModel.navState.sinkAndStore(in: &disposables)
                        viewModel.rightNavItems.firstValue()??.first?.action?()
                        viewModel.textChanged("TestUserNew", for: .nickname)
                    }
                    
                    it("enters the editing state") {
                        expect(viewModel.navState.firstValue())
                            .to(equal(.editing))
                        
                        expect(viewModel.leftNavItems.firstValue())
                            .to(equal([
                                ParentType.NavItem(
                                    id: .cancel,
                                    systemItem: .cancel,
                                    accessibilityIdentifier: "Cancel button"
                                )
                            ]))
                        expect(viewModel.rightNavItems.firstValue())
                            .to(equal([
                                ParentType.NavItem(
                                    id: .done,
                                    systemItem: .done,
                                    accessibilityIdentifier: "Done"
                                )
                            ]))
                    }
                    
                    context("when cancelling edit mode") {
                        beforeEach {
                            viewModel.leftNavItems.firstValue()??.first?.action?()
                        }
                        
                        it("exits editing mode") {
                            expect(viewModel.navState.firstValue())
                                .to(equal(.standard))
                            
                            expect(viewModel.leftNavItems.firstValue()).to(equal([]))
                            expect(viewModel.rightNavItems.firstValue())
                                .to(equal([
                                    ParentType.NavItem(
                                        id: .edit,
                                        systemItem: .edit,
                                        accessibilityIdentifier: "Edit button"
                                    )
                                ]))
                        }
                        
                        it("does not update the nickname for the current user") {
                            expect(
                                mockStorage
                                    .read { db in try Profile.fetchOne(db, id: "TestId") }?
                                    .nickname
                            )
                            .to(beNil())
                        }
                    }
                    
                    context("when saving edit mode") {
                        beforeEach {
                            viewModel.rightNavItems.firstValue()??.first?.action?()
                        }
                        
                        it("exits editing mode") {
                            expect(viewModel.navState.firstValue())
                                .to(equal(.standard))
                            
                            expect(viewModel.leftNavItems.firstValue()).to(equal([]))
                            expect(viewModel.rightNavItems.firstValue())
                                .to(equal([
                                    ParentType.NavItem(
                                        id: .edit,
                                        systemItem: .edit,
                                        accessibilityIdentifier: "Edit button"
                                    )
                                ]))
                        }
                        
                        it("updates the nickname for the current user") {
                            expect(
                                mockStorage
                                    .read { db in try Profile.fetchOne(db, id: "TestId") }?
                                    .nickname
                            )
                            .to(equal("TestUserNew"))
                        }
                    }
                }
            }
            
            context("with a group conversation") {
                beforeEach {
                    mockStorage.write { db in
                        try SessionThread.deleteAll(db)
                        
                        try SessionThread(
                            id: "TestId",
                            variant: .legacyGroup
                        ).insert(db)
                    }
                    
                    viewModel = ThreadSettingsViewModel(
                        threadId: "TestId",
                        threadVariant: .legacyGroup,
                        didTriggerSearch: {
                            didTriggerSearchCallbackTriggered = true
                        },
                        using: dependencies
                    )
                    disposables.append(
                        viewModel.observableTableData
                            .receive(on: ImmediateScheduler.shared)
                            .sink(
                                receiveCompletion: { _ in },
                                receiveValue: { viewModel.updateTableData($0.0) }
                            )
                    )
                }
                
                it("has the correct title") {
                    expect(viewModel.title).to(equal("vc_group_settings_title".localized()))
                }
                
                it("starts in the standard nav state") {
                    expect(viewModel.navState.firstValue())
                        .to(equal(.standard))
                    
                    expect(viewModel.leftNavItems.firstValue()).to(equal([]))
                    expect(viewModel.rightNavItems.firstValue()).to(equal([]))
                }
            }
            
            context("with a community conversation") {
                beforeEach {
                    mockStorage.write { db in
                        try SessionThread.deleteAll(db)
                        
                        try SessionThread(
                            id: "TestId",
                            variant: .community
                        ).insert(db)
                    }
                    
                    viewModel = ThreadSettingsViewModel(
                        threadId: "TestId",
                        threadVariant: .community,
                        didTriggerSearch: {
                            didTriggerSearchCallbackTriggered = true
                        },
                        using: dependencies
                    )
                    disposables.append(
                        viewModel.observableTableData
                            .receive(on: ImmediateScheduler.shared)
                            .sink(
                                receiveCompletion: { _ in },
                                receiveValue: { viewModel.updateTableData($0.0) }
                            )
                    )
                }
                
                it("has the correct title") {
                    expect(viewModel.title).to(equal("vc_group_settings_title".localized()))
                }
                
                it("starts in the standard nav state") {
                    expect(viewModel.navState.firstValue())
                        .to(equal(.standard))
                    
                    expect(viewModel.leftNavItems.firstValue()).to(equal([]))
                    expect(viewModel.rightNavItems.firstValue()).to(equal([]))
                }
            }
        }
    }
}
