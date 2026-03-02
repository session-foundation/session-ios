// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Combine
import GRDB
import Quick
import Nimble
import SessionUIKit
import SessionNetworkingKit
import SessionUtilitiesKit
import TestUtilities

@testable import SessionUIKit
@testable import SessionMessagingKit
@testable import Session

class ThreadSettingsViewModelSpec: AsyncSpec {
    private typealias Item = SessionListScreenContent.ListItemInfo<ThreadSettingsViewModel.ListItem>
    
    override class func spec() {
        // MARK: Configuration
        
        @TestState var userPubkey: String! = "05\(TestConstants.publicKey)"
        @TestState var user2Pubkey: String! = "05\(TestConstants.publicKey.replacingOccurrences(of: "8", with: "7"))"
        @TestState var legacyGroupPubkey: String! = "05\(TestConstants.publicKey.replacingOccurrences(of: "8", with: "6"))"
        @TestState var groupPubkey: String! = "03\(TestConstants.publicKey.replacingOccurrences(of: "8", with: "5"))"
        @TestState var communityId: String! = "testserver.testRoom"
        @TestState var dependencies: TestDependencies! = TestDependencies { dependencies in
            dependencies[singleton: .scheduler] = .immediate
            dependencies.dateNow = Date(timeIntervalSince1970: 1234567890)
            dependencies.forceSynchronous = true
        }
        @TestState var mockStorage: Storage! = SynchronousStorage(
            customWriter: try! DatabaseQueue(),
            using: dependencies
        )
        @TestState var mockGeneralCache: MockGeneralCache! = .create(using: dependencies)
        @TestState var mockJobRunner: MockJobRunner! = .create(using: dependencies)
        @TestState var mockLibSessionCache: MockLibSessionCache! = .create(using: dependencies)
        @TestState var mockCrypto: MockCrypto! = .create(using: dependencies)
        @TestState var mockNetwork: MockNetwork! = .create(using: dependencies)
        @TestState var threadVariant: SessionThread.Variant! = .contact
        @TestState var didTriggerSearchCallbackTriggered: Bool! = false
        @TestState var viewModel: ThreadSettingsViewModel!
        @TestState var disposables: [AnyCancellable]! = []
        @TestState var screenTransitions: [(destination: UIViewController, transition: TransitionType)]! = []
        
        func item(section: ThreadSettingsViewModel.Section, id: ThreadSettingsViewModel.ListItem) -> Item? {
            return viewModel.state.listItemData
                .first(where: { (sectionModel: ThreadSettingsViewModel.SectionModel) -> Bool in
                    sectionModel.model == section
                })?
                .elements
                .first(where: { (item: SessionListScreenContent.ListItemInfo<ThreadSettingsViewModel.ListItem>) -> Bool in
                    item.id == id
                })
        }
        
        func setupTestSubscriptions() {
            viewModel.navigatableState.transitionToScreen
                .receive(on: ImmediateScheduler.shared)
                .sink(
                    receiveCompletion: { _ in },
                    receiveValue: { screenTransitions.append($0) }
                )
                .store(in: &disposables)
        }
        
        beforeEach {
            dependencies.set(cache: .general, to: mockGeneralCache)
            try await mockGeneralCache.defaultInitialSetup()
            
            dependencies.set(cache: .libSession, to: mockLibSessionCache)
            try await mockLibSessionCache.defaultInitialSetup()
            
            dependencies.set(singleton: .storage, to: mockStorage)
            try await mockStorage.perform(migrations: SNMessagingKit.migrations)
            try await mockStorage.writeAsync { db in
                try Identity(
                    variant: .x25519PublicKey,
                    data: Data(hex: TestConstants.publicKey)
                ).insert(db)
                try Profile(
                    id: userPubkey,
                    name: "TestMe",
                    nickname: nil,
                    displayPictureUrl: nil,
                    displayPictureEncryptionKey: nil,
                    profileLastUpdated: nil,
                    blocksCommunityMessageRequests: nil,
                    proFeatures: .none,
                    proExpiryUnixTimestampMs: 0,
                    proGenIndexHashHex: nil
                ).insert(db)
                try Profile(
                    id: user2Pubkey,
                    name: "TestUser",
                    nickname: nil,
                    displayPictureUrl: nil,
                    displayPictureEncryptionKey: nil,
                    profileLastUpdated: nil,
                    blocksCommunityMessageRequests: nil,
                    proFeatures: .none,
                    proExpiryUnixTimestampMs: 0,
                    proGenIndexHashHex: nil
                ).insert(db)
            }
            
            dependencies.set(singleton: .jobRunner, to: mockJobRunner)
            try await mockJobRunner
                .when { $0.add(.any, job: .any, initialDependencies: .any) }
                .thenReturn(.mock)
            try await mockJobRunner
                .when { try $0.addJobDependency(.any, .any) }
                .thenReturn(())
            
            dependencies.set(singleton: .crypto, to: mockCrypto)
            try await mockCrypto
                .when { $0.generate(.signature(message: .any, ed25519SecretKey: .any)) }
                .thenReturn(Authentication.Signature.standard(signature: "TestSignature".bytes))
            
            dependencies.set(singleton: .network, to: mockNetwork)
            var networkOffset: Int64 = 0
            try await mockNetwork.when { await $0.networkTimeOffsetMs }.thenReturn { _ in
                /// **Note:** We need to increment this value every time it's accessed because otherwise any functions which
                /// insert multiple `Interaction` values can end up running into unique constraint conflicts due to the timestamp
                /// being identical between different interactions
                networkOffset += 1
                return networkOffset
            }
            try await mockNetwork.when { $0.syncState }.thenReturn { _ in
                /// **Note:** We need to increment this value every time it's accessed because otherwise any functions which
                /// insert multiple `Interaction` values can end up running into unique constraint conflicts due to the timestamp
                /// being identical between different interactions
                networkOffset += 1
                
                return NetworkSyncState(
                    hardfork: 2,
                    softfork: 11,
                    networkTimeOffsetMs: networkOffset,
                    using: dependencies
                )
            }
        }
        
        // MARK: - a ThreadSettingsViewModel
        describe("a ThreadSettingsViewModel") {
            beforeEach {
                mockStorage.write { db in
                    try SessionThread(
                        id: user2Pubkey,
                        variant: .contact,
                        creationDateTimestamp: 0
                    ).insert(db)
                }
                
                viewModel = await ThreadSettingsViewModel(
                    threadInfo: ConversationInfoViewModel(
                        thread: SessionThread(
                            id: user2Pubkey,
                            variant: .contact,
                            creationDateTimestamp: 1234567890
                        ),
                        dataCache: ConversationDataCache(
                            userSessionId: SessionId(.standard, hex: TestConstants.publicKey),
                            context: ConversationDataCache.Context(
                                source: .conversationSettings(threadId: user2Pubkey),
                                requireFullRefresh: false,
                                requireAuthMethodFetch: false,
                                requiresMessageRequestCountUpdate: false,
                                requiresPinnedConversationCountUpdate: false,
                                requiresInitialUnreadInteractionInfo: false,
                                requireRecentReactionEmojiUpdate: false
                            )
                        ),
                        targetInteractionId: nil,
                        searchText: nil,
                        using: dependencies
                    ),
                    didTriggerSearch: {
                        didTriggerSearchCallbackTriggered = true
                    },
                    using: dependencies
                )
                setupTestSubscriptions()
            }
            
            // MARK: -- with any conversation type
            context("with any conversation type") {
                // MARK: ---- triggers the search callback when tapping search
                it("triggers the search callback when tapping search") {
                    let item: Item? = await expect(item(section: .content, id: .searchConversation))
                        .toEventuallyNot(beNil())
                        .retrieveValue()
                    await item?.onTap?()
                    
                    await expect(didTriggerSearchCallbackTriggered).toEventually(beTrue())
                }
            }
            
            // MARK: -- with a note-to-self conversation
            context("with a note-to-self conversation") {
                beforeEach {
                    mockStorage.write { db in
                        try SessionThread(
                            id: userPubkey,
                            variant: .contact,
                            creationDateTimestamp: 0
                        ).insert(db)
                    }
                    
                    viewModel = await ThreadSettingsViewModel(
                        threadInfo: ConversationInfoViewModel(
                            thread: SessionThread(
                                id: userPubkey,
                                variant: .contact,
                                creationDateTimestamp: 1234567890
                            ),
                            dataCache: ConversationDataCache(
                                userSessionId: SessionId(.standard, hex: userPubkey),
                                context: ConversationDataCache.Context(
                                    source: .conversationSettings(threadId: userPubkey),
                                    requireFullRefresh: false,
                                    requireAuthMethodFetch: false,
                                    requiresMessageRequestCountUpdate: false,
                                    requiresPinnedConversationCountUpdate: false,
                                    requiresInitialUnreadInteractionInfo: false,
                                    requireRecentReactionEmojiUpdate: false
                                )
                            ),
                            targetInteractionId: nil,
                            searchText: nil,
                            using: dependencies
                        ),
                        didTriggerSearch: {
                            didTriggerSearchCallbackTriggered = true
                        },
                        using: dependencies
                    )
                    setupTestSubscriptions()
                }
                
                // MARK: ---- has the correct title
                it("has the correct title") {
                    await expect { await viewModel.title }
                        .toEventually(equal("sessionSettings".localized()))
                }
                
                // MARK: ---- has the correct display name
                it("has the correct display name") {
                    let item: Item? = await expect(item(section: .conversationInfo, id: .displayName))
                        .toEventuallyNot(beNil())
                        .retrieveValue()
                    
                    switch item?.variant {
                        case .tappableText(let info):
                            expect(info.text).to(equal("noteToSelf".localized()))
                        default:
                            fail("Expected .tappableText variant for displayName")
                    }
                }
                
                // MARK: ---- does nothing when tapped
                it("does nothing when tapped") {
                    let item: Item? = await expect(item(section: .conversationInfo, id: .displayName))
                        .toEventuallyNot(beNil())
                        .retrieveValue()
                    await item?.onTap?()
                    await expect(screenTransitions).toEventually(beEmpty())
                }
            }
            
            // MARK: -- with a one-to-one conversation
            context("with a one-to-one conversation") {
                beforeEach {
                    mockStorage.write { db in
                        try SessionThread(
                            id: user2Pubkey,
                            variant: .contact,
                            creationDateTimestamp: 0
                        ).insert(db)
                    }
                    
                    viewModel = await ThreadSettingsViewModel(
                        threadInfo: ConversationInfoViewModel(
                            thread: SessionThread(
                                id: user2Pubkey,
                                variant: .contact,
                                creationDateTimestamp: 1234567890
                            ),
                            dataCache: ConversationDataCache(
                                userSessionId: SessionId(.standard, hex: TestConstants.publicKey),
                                context: ConversationDataCache.Context(
                                    source: .conversationSettings(threadId: user2Pubkey),
                                    requireFullRefresh: false,
                                    requireAuthMethodFetch: false,
                                    requiresMessageRequestCountUpdate: false,
                                    requiresPinnedConversationCountUpdate: false,
                                    requiresInitialUnreadInteractionInfo: false,
                                    requireRecentReactionEmojiUpdate: false
                                )
                            ),
                            targetInteractionId: nil,
                            searchText: nil,
                            using: dependencies
                        ),
                        didTriggerSearch: {
                            didTriggerSearchCallbackTriggered = true
                        },
                        using: dependencies
                    )
                    setupTestSubscriptions()
                }
                
                // MARK: ---- has the correct title
                it("has the correct title") {
                    await expect { await viewModel.title }
                        .toEventually(equal("sessionSettings".localized()))
                }
                
                // MARK: ---- has the correct display name
                it("has the correct display name") {
                    let item: Item? = await expect(item(section: .conversationInfo, id: .displayName))
                        .toEventuallyNot(beNil())
                        .retrieveValue()
                    
                    switch item?.variant {
                        case .tappableText(let info):
                            expect(info.text).to(equal("TestUser"))
                        default:
                            fail("Expected .tappableText variant for displayName")
                    }
                }
                
                // MARK: ---- presents a confirmation modal when tapped
                it("presents a confirmation modal when tapped") {
                    let item: Item? = await expect(item(section: .conversationInfo, id: .displayName))
                        .toEventuallyNot(beNil())
                        .retrieveValue()
                    switch item?.variant {
                        case .tappableText(let info):
                            await info.onTextTap?()
                            await expect(screenTransitions.first?.destination)
                                .toEventually(beAKindOf(ConfirmationModal.self))
                            expect(screenTransitions.first?.transition).to(equal(TransitionType.present))
                        default:
                            fail("Expected .tappableText variant for displayName")
                    }
                }
                
                // MARK: ---- when updating the nickname
                context("when updating the nickname") {
                    @TestState var onChange: ((String) -> ())?
                    @TestState var modal: ConfirmationModal?
                    @TestState var modalInfo: ConfirmationModal.Info?
                    
                    beforeEach {
                        let item: Item? = await expect(item(section: .conversationInfo, id: .displayName))
                            .toEventuallyNot(beNil())
                            .retrieveValue()
                        switch item?.variant {
                            case .tappableText(let info):
                                await info.onTextTap?()
                                await expect(screenTransitions.first?.destination)
                                    .toEventually(beAKindOf(ConfirmationModal.self))
                                expect(screenTransitions.first?.transition).to(equal(TransitionType.present))
                            
                                modal = (screenTransitions.first?.destination as? ConfirmationModal)
                                modalInfo = await modal?.info
                                switch await modal?.info.body {
                                    case .input(_, _, let onChange_): onChange = onChange_
                                    default: break
                                }
                            default:
                                fail("Expected .tappableText variant for displayName")
                        }
                    }
                    
                    // MARK: ------ has the correct content
                    it("has the correct content") {
                        expect(modalInfo?.title).to(equal("nicknameSet".localized()))
                        expect(modalInfo?.body).to(equal(
                            .input(
                                explanation: "nicknameDescription"
                                    .put(key: "name", value: "TestUser")
                                    .localizedFormatted(baseFont: ConfirmationModal.explanationFont),
                                info: ConfirmationModal.Info.Body.InputInfo(
                                    placeholder: "nicknameEnter".localized(),
                                    initialValue: nil,
                                    accessibility: Accessibility(identifier: "Username input")
                                ),
                                onChange: { _ in }
                            )
                        ))
                        expect(modalInfo?.confirmTitle).to(equal("save".localized()))
                        expect(modalInfo?.cancelTitle).to(equal("remove".localized()))
                    }
                    
                    // MARK: ------ does nothing if the name contains only white space
                    it("does nothing if the name contains only white space") {
                        onChange?("   ")
                        await modal?.confirmationPressed()
                        
                        await expect(screenTransitions.count).toEventually(equal(1))
                    }
                    
                    // MARK: ------ shows an error modal when the updated nickname is too long
                    it("shows an error modal when the updated nickname is too long") {
                        onChange?([String](Array(repeating: "1", count: 101)).joined())
                        await modal?.confirmationPressed()
                        
                        await expect(screenTransitions.count).toEventually(equal(1))
                        
                        let text: String? = await modal?.textFieldErrorLabel.text
                        expect(text).to(equal("nicknameErrorShorter".localized()))
                    }
                    
                    // MARK: ------ updates the contacts nickname when valid
                    it("updates the contacts nickname when valid") {
                        onChange?("TestNickname")
                        await modal?.confirmationPressed()
                        
                        let profiles: [Profile]? = await expect(mockStorage.read { db in try Profile.fetchAll(db) })
                            .toEventuallyNot(beEmpty())
                            .retrieveValue()
                        expect(profiles?.map { $0.nickname }.asSet()).to(equal([nil, "TestNickname"]))
                    }
                    
                    // MARK: ------ removes the nickname when cancel is pressed
                    it("removes the nickname when cancel is pressed") {
                        mockStorage.write { db in
                            try Profile
                                .filter(id: "TestId")
                                .updateAll(db, Profile.Columns.nickname.set(to: "TestOldNickname"))
                        }
                        await modal?.cancel()
                        
                        let profiles: [Profile]? = await expect(mockStorage.read { db in try Profile.fetchAll(db) })
                            .toEventuallyNot(beEmpty())
                            .retrieveValue()
                        expect(profiles?.map { $0.nickname }.asSet()).to(equal([nil, nil]))
                    }
                }
            }
            
            // MARK: -- with a legacy group conversation
            context("with a legacy group conversation") {
                beforeEach {
                    mockStorage.write { db in
                        try SessionThread(
                            id: legacyGroupPubkey,
                            variant: .legacyGroup,
                            creationDateTimestamp: 0
                        ).insert(db)
                        
                        try DisappearingMessagesConfiguration
                            .defaultWith(legacyGroupPubkey)
                            .insert(db)
                        
                        try ClosedGroup(
                            threadId: legacyGroupPubkey,
                            name: "TestGroup",
                            groupDescription: nil,
                            formationTimestamp: 1234567890,
                            displayPictureUrl: nil,
                            displayPictureEncryptionKey: nil,
                            shouldPoll: false,
                            groupIdentityPrivateKey: nil,
                            authData: nil,
                            invited: nil
                        ).insert(db)
                        
                        try GroupMember(
                            groupId: legacyGroupPubkey,
                            profileId: userPubkey,
                            role: .standard,
                            roleStatus: .accepted,
                            isHidden: false
                        ).insert(db)
                    }
                    
                    viewModel = await ThreadSettingsViewModel(
                        threadInfo: ConversationInfoViewModel(
                            thread: SessionThread(
                                id: legacyGroupPubkey,
                                variant: .legacyGroup,
                                creationDateTimestamp: 1234567890
                            ),
                            dataCache: ConversationDataCache(
                                userSessionId: SessionId(.standard, hex: TestConstants.publicKey),
                                context: ConversationDataCache.Context(
                                    source: .conversationSettings(threadId: legacyGroupPubkey),
                                    requireFullRefresh: false,
                                    requireAuthMethodFetch: false,
                                    requiresMessageRequestCountUpdate: false,
                                    requiresPinnedConversationCountUpdate: false,
                                    requiresInitialUnreadInteractionInfo: false,
                                    requireRecentReactionEmojiUpdate: false
                                )
                            ),
                            targetInteractionId: nil,
                            searchText: nil,
                            using: dependencies
                        ),
                        didTriggerSearch: {
                            didTriggerSearchCallbackTriggered = true
                        },
                        using: dependencies
                    )
                    setupTestSubscriptions()
                }
                
                // MARK: ---- has the correct title
                it("has the correct title") {
                    await expect { await viewModel.title }
                        .toEventually(equal("deleteAfterGroupPR1GroupSettings".localized()))
                }
                
                // MARK: ---- has the correct display name
                it("has the correct display name") {
                    let item: Item? = await expect(item(section: .conversationInfo, id: .displayName))
                        .toEventuallyNot(beNil())
                        .retrieveValue()
                    switch item?.variant {
                        case .tappableText(let info):
                            expect(info.text).to(equal("TestGroup"))
                        default:
                            fail("Expected .tappableText variant for displayName")
                    }
                }
                
                // MARK: ---- when the user is a standard member
                context("when the user is a standard member") {
                    // MARK: ------ does nothing when tapped
                    it("does nothing when tapped") {
                        let item: Item? = await expect(item(section: .conversationInfo, id: .displayName))
                            .toEventuallyNot(beNil())
                            .retrieveValue()
                        switch item?.variant {
                            case .tappableText(let info):
                                await info.onTextTap?()
                                await expect(screenTransitions).toEventually(beEmpty())
                            default:
                                fail("Expected .tappableText variant for displayName")
                        }
                    }
                }
                
                // MARK: ---- when the user is an admin
                context("when the user is an admin") {
                    beforeEach {
                        mockStorage.write { db in
                            try GroupMember.deleteAll(db)
                            
                            try GroupMember(
                                groupId: legacyGroupPubkey,
                                profileId: userPubkey,
                                role: .admin,
                                roleStatus: .accepted,
                                isHidden: false
                            ).insert(db)
                        }
                        
                        viewModel = await ThreadSettingsViewModel(
                            threadInfo: ConversationInfoViewModel(
                                thread: SessionThread(
                                    id: legacyGroupPubkey,
                                    variant: .legacyGroup,
                                    creationDateTimestamp: 1234567890
                                ),
                                dataCache: ConversationDataCache(
                                    userSessionId: SessionId(.standard, hex: TestConstants.publicKey),
                                    context: ConversationDataCache.Context(
                                        source: .conversationSettings(threadId: legacyGroupPubkey),
                                        requireFullRefresh: false,
                                        requireAuthMethodFetch: false,
                                        requiresMessageRequestCountUpdate: false,
                                        requiresPinnedConversationCountUpdate: false,
                                        requiresInitialUnreadInteractionInfo: false,
                                        requireRecentReactionEmojiUpdate: false
                                    )
                                ),
                                targetInteractionId: nil,
                                searchText: nil,
                                using: dependencies
                            ),
                            didTriggerSearch: {
                                didTriggerSearchCallbackTriggered = true
                            },
                            using: dependencies
                        )
                        setupTestSubscriptions()
                    }
                    
                    // MARK: ------ presents a confirmation modal when tapped
                    it("presents a confirmation modal when tapped") {
                        let item: Item? = await expect(item(section: .conversationInfo, id: .displayName))
                            .toEventuallyNot(beNil())
                            .retrieveValue()
                        switch item?.variant {
                            case .tappableText(let info):
                                await info.onTextTap?()
                                await expect(screenTransitions.first?.destination)
                                    .toEventually(beAKindOf(ConfirmationModal.self))
                                expect(screenTransitions.first?.transition).to(equal(TransitionType.present))
                            default:
                                fail("Expected .tappableText variant for displayName")
                        }
                    }
                }
            }
            
            // MARK: -- with a group conversation
            context("with a group conversation") {
                beforeEach {
                    mockStorage.write { db in
                        try SessionThread(
                            id: groupPubkey,
                            variant: .group,
                            creationDateTimestamp: 0
                        ).insert(db)
                        
                        try ClosedGroup(
                            threadId: groupPubkey,
                            name: "TestGroup",
                            groupDescription: nil,
                            formationTimestamp: 1234567890,
                            displayPictureUrl: nil,
                            displayPictureEncryptionKey: nil,
                            shouldPoll: false,
                            groupIdentityPrivateKey: nil,
                            authData: nil,
                            invited: nil
                        ).insert(db)
                        
                        try GroupMember(
                            groupId: groupPubkey,
                            profileId: userPubkey,
                            role: .standard,
                            roleStatus: .accepted,
                            isHidden: false
                        ).insert(db)
                    }
                    
                    viewModel = await ThreadSettingsViewModel(
                        threadInfo: ConversationInfoViewModel(
                            thread: SessionThread(
                                id: groupPubkey,
                                variant: .group,
                                creationDateTimestamp: 1234567890
                            ),
                            dataCache: ConversationDataCache(
                                userSessionId: SessionId(.standard, hex: TestConstants.publicKey),
                                context: ConversationDataCache.Context(
                                    source: .conversationSettings(threadId: groupPubkey),
                                    requireFullRefresh: false,
                                    requireAuthMethodFetch: false,
                                    requiresMessageRequestCountUpdate: false,
                                    requiresPinnedConversationCountUpdate: false,
                                    requiresInitialUnreadInteractionInfo: false,
                                    requireRecentReactionEmojiUpdate: false
                                )
                            ),
                            targetInteractionId: nil,
                            searchText: nil,
                            using: dependencies
                        ),
                        didTriggerSearch: {
                            didTriggerSearchCallbackTriggered = true
                        },
                        using: dependencies
                    )
                    setupTestSubscriptions()
                }
                
                // MARK: ---- has the correct title
                it("has the correct title") {
                    await expect { await viewModel.title }
                        .toEventually(equal("deleteAfterGroupPR1GroupSettings".localized()))
                }
                
                // MARK: ---- has the correct display name
                it("has the correct display name") {
                    let item: Item? = await expect(item(section: .conversationInfo, id: .displayName))
                        .toEventuallyNot(beNil())
                        .retrieveValue()
                    
                    switch item?.variant {
                        case .tappableText(let info):
                            expect(info.text).to(equal("TestGroup"))
                        default:
                            fail("Expected .tappableText variant for displayName")
                    }
                }
                
                // MARK: ---- when the user is a standard member
                context("when the user is a standard member") {
                    // MARK: ------ does nothing when tapped
                    it("does nothing when tapped") {
                        let item: Item? = await expect(item(section: .conversationInfo, id: .displayName))
                            .toEventuallyNot(beNil())
                            .retrieveValue()
                        switch item?.variant {
                            case .tappableText(let info):
                                await info.onTextTap?()
                                await expect(screenTransitions).toEventually(beEmpty())
                            default:
                                fail("Expected .tappableText variant for displayName")
                        }
                    }
                }
                
                // MARK: ---- when the user is an admin
                context("when the user is an admin") {
                    beforeEach {
                        mockStorage.write { db in
                            try GroupMember.deleteAll(db)
                            
                            try ClosedGroup
                                .updateAll(
                                    db,
                                    ClosedGroup.Columns.groupIdentityPrivateKey.set(to: Data([1, 2, 3]))
                                )
                            try GroupMember(
                                groupId: groupPubkey,
                                profileId: userPubkey,
                                role: .admin,
                                roleStatus: .accepted,
                                isHidden: false
                            ).insert(db)
                        }
                        
                        viewModel = await ThreadSettingsViewModel(
                            threadInfo: ConversationInfoViewModel(
                                thread: SessionThread(
                                    id: groupPubkey,
                                    variant: .group,
                                    creationDateTimestamp: 1234567890
                                ),
                                dataCache: ConversationDataCache(
                                    userSessionId: SessionId(.standard, hex: TestConstants.publicKey),
                                    context: ConversationDataCache.Context(
                                        source: .conversationSettings(threadId: groupPubkey),
                                        requireFullRefresh: false,
                                        requireAuthMethodFetch: false,
                                        requiresMessageRequestCountUpdate: false,
                                        requiresPinnedConversationCountUpdate: false,
                                        requiresInitialUnreadInteractionInfo: false,
                                        requireRecentReactionEmojiUpdate: false
                                    )
                                ),
                                targetInteractionId: nil,
                                searchText: nil,
                                using: dependencies
                            ),
                            didTriggerSearch: {
                                didTriggerSearchCallbackTriggered = true
                            },
                            using: dependencies
                        )
                        setupTestSubscriptions()
                    }
                    
                    // MARK: ------ presents a confirmation modal when tapped
                    it("presents a confirmation modal when tapped") {
                        let item: Item? = await expect(item(section: .conversationInfo, id: .displayName))
                            .toEventuallyNot(beNil())
                            .retrieveValue()
                        
                        switch item?.variant {
                            case .tappableText(let info):
                                await info.onTextTap?()
                                await expect(screenTransitions.first?.destination)
                                    .toEventually(beAKindOf(ConfirmationModal.self))
                                expect(screenTransitions.first?.transition).to(equal(TransitionType.present))
                            default:
                                fail("Expected .tappableText variant for displayName")
                        }
                    }
                    
                    // MARK: ------ when updating the group info
                    context("when updating the group info") {
                        @TestState var onChange: ((String) -> ())?
                        @TestState var onChange2: ((String, String) -> ())?
                        @TestState var modal: ConfirmationModal?
                        @TestState var modalInfo: ConfirmationModal.Info?
                        
                        beforeEach {
                            dependencies[feature: .updatedGroupsAllowDescriptionEditing] = true
                            viewModel = await ThreadSettingsViewModel(
                                threadInfo: ConversationInfoViewModel(
                                    thread: SessionThread(
                                        id: groupPubkey,
                                        variant: .group,
                                        creationDateTimestamp: 1234567890
                                    ),
                                    dataCache: ConversationDataCache(
                                        userSessionId: SessionId(.standard, hex: TestConstants.publicKey),
                                        context: ConversationDataCache.Context(
                                            source: .conversationSettings(threadId: groupPubkey),
                                            requireFullRefresh: false,
                                            requireAuthMethodFetch: false,
                                            requiresMessageRequestCountUpdate: false,
                                            requiresPinnedConversationCountUpdate: false,
                                            requiresInitialUnreadInteractionInfo: false,
                                            requireRecentReactionEmojiUpdate: false
                                        )
                                    ),
                                    targetInteractionId: nil,
                                    searchText: nil,
                                    using: dependencies
                                ),
                                didTriggerSearch: {
                                    didTriggerSearchCallbackTriggered = true
                                },
                                using: dependencies
                            )
                            setupTestSubscriptions()
                            
                            let item: Item? = await expect(item(section: .conversationInfo, id: .displayName))
                                .toEventuallyNot(beNil())
                                .retrieveValue()
                            switch item?.variant {
                                case .tappableText(let info):
                                    await info.onTextTap?()
                                    await expect(screenTransitions.first?.destination)
                                        .toEventually(beAKindOf(ConfirmationModal.self))
                                    
                                    modal = (screenTransitions.first?.destination as? ConfirmationModal)
                                    modalInfo = await modal?.info
                                    switch modalInfo?.body {
                                        case .input(_, _, let onChange_): onChange = onChange_
                                        case .dualInput(_, _, _, let onChange2_): onChange2 = onChange2_
                                        default: break
                                    }
                                default:
                                    fail("Expected .tappableText variant for displayName")
                            }
                        }
                        
                        // MARK: -------- has the correct content
                        it("has the correct content") {
                            expect(modalInfo?.title).to(equal("updateGroupInformation".localized()))
                            expect(modalInfo?.body).to(equal(
                                .dualInput(
                                    explanation: "updateGroupInformationDescription"
                                        .localizedFormatted(baseFont: ConfirmationModal.explanationFont),
                                    firstInfo: ConfirmationModal.Info.Body.InputInfo(
                                        placeholder: "groupNameEnter".localized(),
                                        initialValue: "TestGroup",
                                        clearButton: true,
                                        accessibility: Accessibility(identifier: "Group name text field"),
                                        inputChecker: { _ in nil }
                                    ),
                                    secondInfo: ConfirmationModal.Info.Body.InputInfo(
                                        placeholder: "groupDescriptionEnter".localized(),
                                        initialValue: nil,
                                        clearButton: true,
                                        accessibility: Accessibility(identifier: "Group description text field"),
                                        inputChecker: { _ in nil }
                                    ),
                                    onChange: { _, _ in }
                                )
                            ))
                            expect(modalInfo?.confirmTitle).to(equal("save".localized()))
                            expect(modalInfo?.cancelTitle).to(equal("cancel".localized()))
                        }
                        
                        // MARK: -------- does nothing if the name contains only white space
                        it("does nothing if the name contains only white space") {
                            onChange2?("   ", "Test")
                            await modal?.confirmationPressed()
                            
                            await expect(screenTransitions.count).toEventually(equal(1))
                        }
                        
                        // MARK: -------- updates the modal with an error when the updated name is too long
                        it("updates the modal with an error when the updated name is too long") {
                            onChange2?([String](Array(repeating: "1", count: 101)).joined(), "Test")
                            await modal?.confirmationPressed()
                            
                            await expect(screenTransitions.count).toEventually(equal(1))
                            
                            let text: String? = await modal?.textFieldErrorLabel.text
                            expect(text).to(equal("groupNameEnterShorter".localized()))
                        }
                        
                        // MARK: -------- updates the modal with an error when the updated description is too long
                        it("updates the modal with an error when the updated description is too long") {
                            onChange2?("Test", [String](Array(repeating: "1", count: 2001)).joined())
                            await modal?.confirmationPressed()
                            
                            await expect(screenTransitions.count).toEventually(equal(1))
                            
                            let text: String? = await modal?.textViewErrorLabel.text
                            expect(text).to(equal("updateGroupInformationEnterShorterDescription".localized()))
                        }
                        
                        // MARK: -------- updates the group name when valid
                        it("updates the group name when valid") {
                            onChange2?("TestNewGroupName", "Test")
                            await modal?.confirmationPressed()
                            
                            await expect {
                                try await mockStorage.readAsync { db in
                                    Set(try ClosedGroup.fetchAll(db)
                                        .map { $0.name })
                                }
                            }.toEventually(equal(["TestNewGroupName"]), timeout: .milliseconds(100))
                        }
                        
                        // MARK: -------- updates the group description when valid
                        it("updates the group description when valid") {
                            onChange2?("Test", "TestNewGroupDescription")
                            await modal?.confirmationPressed()
                            
                            await expect {
                                try await mockStorage.readAsync { db in
                                    Set(try ClosedGroup.fetchAll(db)
                                        .map { $0.groupDescription })
                                }
                            }.toEventually(equal(["TestNewGroupDescription"]), timeout: .milliseconds(100))
                        }
                        
                        // MARK: -------- inserts a control message
                        it("inserts a control message") {
                            onChange2?("TestNewGroupName", "")
                            await modal?.confirmationPressed()
                            
                            await expect {
                                try await mockStorage.readAsync { db in
                                    Set(try Interaction.fetchAll(db)
                                        .map { EquatablePair($0.variant, $0.body) })
                                }
                            }.toEventually(
                                equal([
                                    EquatablePair(
                                        .infoGroupInfoUpdated,
                                        ClosedGroup.MessageInfo
                                            .updatedName("TestNewGroupName")
                                            .infoString(using: dependencies)
                                    )
                                ]),
                                timeout: .milliseconds(100)
                            )
                        }
                        
                        // MARK: -------- schedules a control message to be sent
                        it("schedules a control message to be sent") {
                            onChange2?("TestNewGroupName", "")
                            await modal?.confirmationPressed()
                            
                            await mockJobRunner
                                .verify {
                                    $0.add(
                                        .any,
                                        job: Job(
                                            variant: .messageSend,
                                            threadId: groupPubkey,
                                            interactionId: nil,
                                            details: MessageSendJob.Details(
                                                destination: .group(publicKey: groupPubkey),
                                                message: try GroupUpdateInfoChangeMessage(
                                                    changeType: .name,
                                                    updatedName: "TestNewGroupName",
                                                    sentTimestampMs: UInt64(1234567890001),
                                                    authMethod: Authentication.groupAdmin(
                                                        groupSessionId: SessionId(.group, hex: groupPubkey),
                                                        ed25519SecretKey: [1, 2, 3]
                                                    ),
                                                    using: dependencies
                                                ),
                                                requiredConfigSyncVariant: .groupInfo,
                                                ignorePermanentFailure: true
                                            )
                                        ),
                                        initialDependencies: []
                                    )
                                }
                                .wasCalled(exactly: 1, timeout: .milliseconds(100))
                        }
                        
                        // MARK: -------- triggers a libSession change
                        it("triggers a libSession change") {
                            try await mockLibSessionCache
                                .when { $0.isAdmin(groupSessionId: .any) }
                                .thenReturn(true)
                            
                            onChange2?("Test", "TestNewGroupDescription")
                            await modal?.confirmationPressed()
                            
                            await mockLibSessionCache
                                .verify {
                                    try $0.performAndPushChange(
                                        .any,
                                        for: .userGroups,
                                        sessionId: SessionId(.standard, hex: userPubkey),
                                        change: { _ in }
                                    )
                                }
                                .wasCalled(exactly: 1, timeout: .milliseconds(100))
                            await mockLibSessionCache
                                .verify {
                                    try $0.performAndPushChange(
                                        .any,
                                        for: .groupInfo,
                                        sessionId: SessionId(.group, hex: groupPubkey),
                                        change: { _ in }
                                    )
                                }
                                .wasCalled(exactly: 1)
                        }
                    }
                }
            }
            
            // MARK: -- with a community conversation
            context("with a community conversation") {
                beforeEach {
                    mockStorage.write { db in
                        try SessionThread.deleteAll(db)
                        
                        try SessionThread(
                            id: communityId,
                            variant: .community,
                            creationDateTimestamp: 0
                        ).insert(db)
                        
                        try OpenGroup(
                            server: "testServer",
                            roomToken: "testRoom",
                            publicKey: TestConstants.serverPublicKey,
                            shouldPoll: false,
                            name: "TestCommunity",
                            userCount: 1,
                            infoUpdates: 1
                        ).insert(db)
                    }
                    
                    viewModel = await ThreadSettingsViewModel(
                        threadInfo: ConversationInfoViewModel(
                            thread: SessionThread(
                                id: communityId,
                                variant: .community,
                                creationDateTimestamp: 1234567890
                            ),
                            dataCache: ConversationDataCache(
                                userSessionId: SessionId(.standard, hex: TestConstants.publicKey),
                                context: ConversationDataCache.Context(
                                    source: .conversationSettings(threadId: communityId),
                                    requireFullRefresh: false,
                                    requireAuthMethodFetch: false,
                                    requiresMessageRequestCountUpdate: false,
                                    requiresPinnedConversationCountUpdate: false,
                                    requiresInitialUnreadInteractionInfo: false,
                                    requireRecentReactionEmojiUpdate: false
                                )
                            ),
                            targetInteractionId: nil,
                            searchText: nil,
                            using: dependencies
                        ),
                        didTriggerSearch: {
                            didTriggerSearchCallbackTriggered = true
                        },
                        using: dependencies
                    )
                    setupTestSubscriptions()
                }
                
                // MARK: ---- has the correct title
                it("has the correct title") {
                    await expect { await viewModel.title }
                        .toEventually(equal("deleteAfterGroupPR1GroupSettings".localized()))
                }
                
                // MARK: ---- has the correct display name
                it("has the correct display name") {
                    let item: Item? = await expect(item(section: .conversationInfo, id: .displayName))
                        .toEventuallyNot(beNil())
                        .retrieveValue()
                    
                    switch item?.variant {
                        case .tappableText(let info):
                            expect(info.text).to(equal("TestCommunity"))
                        default:
                            fail("Expected .tappableText variant for displayName")
                    }
                }
                
                // MARK: ---- does nothing when tapped
                it("does nothing when tapped") {
                    let item: Item? = await expect(item(section: .conversationInfo, id: .displayName))
                        .toEventuallyNot(beNil())
                        .retrieveValue()
                    switch item?.variant {
                        case .tappableText(let info):
                            await info.onTextTap?()
                            await expect(screenTransitions).toEventually(beEmpty())
                        default:
                            fail("Expected .tappableText variant for displayName")
                    }
                }
            }
        }
    }
}
