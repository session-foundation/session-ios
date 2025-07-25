// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Combine
import GRDB
import Quick
import Nimble
import SessionUIKit
import SessionSnodeKit
import SessionUtilitiesKit

@testable import SessionUIKit
@testable import SessionMessagingKit
@testable import Session

class ThreadSettingsViewModelSpec: AsyncSpec {
    private typealias Item = SessionCell.Info<ThreadSettingsViewModel.TableItem>
    
    override class func spec() {
        // MARK: Configuration
        
        @TestState var userPubkey: String! = "05\(TestConstants.publicKey)"
        @TestState var user2Pubkey: String! = "05\(TestConstants.publicKey.replacingOccurrences(of: "8", with: "7"))"
        @TestState var legacyGroupPubkey: String! = "05\(TestConstants.publicKey.replacingOccurrences(of: "8", with: "6"))"
        @TestState var groupPubkey: String! = "03\(TestConstants.publicKey.replacingOccurrences(of: "8", with: "5"))"
        @TestState var communityId: String! = "testserver.testRoom"
        @TestState var dependencies: TestDependencies! = TestDependencies { dependencies in
            dependencies[singleton: .scheduler] = .immediate
            dependencies.forceSynchronous = true
        }
        @TestState(singleton: .storage, in: dependencies) var mockStorage: Storage! = SynchronousStorage(
            customWriter: try! DatabaseQueue(),
            migrationTargets: [
                SNUtilitiesKit.self,
                SNSnodeKit.self,
                SNMessagingKit.self,
                DeprecatedUIKitMigrationTarget.self
            ],
            using: dependencies,
            initialData: { db in
                try Identity(
                    variant: .x25519PublicKey,
                    data: Data(hex: TestConstants.publicKey)
                ).insert(db)
                try Profile(id: userPubkey, name: "TestMe").insert(db)
                try Profile(id: user2Pubkey, name: "TestUser").insert(db)
            }
        )
        @TestState(cache: .general, in: dependencies) var mockGeneralCache: MockGeneralCache! = MockGeneralCache(
            initialSetup: { cache in
                cache.when { $0.sessionId }.thenReturn(SessionId(.standard, hex: TestConstants.publicKey))
            }
        )
        @TestState(singleton: .jobRunner, in: dependencies) var mockJobRunner: MockJobRunner! = MockJobRunner(
            initialSetup: { jobRunner in
                jobRunner
                    .when { $0.add(.any, job: .any, dependantJob: .any, canStartJob: .any) }
                    .thenReturn(nil)
                jobRunner
                    .when { $0.upsert(.any, job: .any, canStartJob: .any) }
                    .thenReturn(nil)
                jobRunner
                    .when { $0.jobInfoFor(jobs: .any, state: .any, variant: .any) }
                    .thenReturn([:])
            }
        )
        @TestState(cache: .libSession, in: dependencies) var mockLibSessionCache: MockLibSessionCache! = MockLibSessionCache(
            initialSetup: { $0.defaultInitialSetup() }
        )
        @TestState(singleton: .crypto, in: dependencies) var mockCrypto: MockCrypto! = MockCrypto(
            initialSetup: { crypto in
                crypto
                    .when { $0.generate(.signature(message: .any, ed25519SecretKey: .any)) }
                    .thenReturn(Authentication.Signature.standard(signature: "TestSignature".bytes))
            }
        )
        @TestState(cache: .snodeAPI, in: dependencies) var mockSnodeAPICache: MockSnodeAPICache! = MockSnodeAPICache(
            initialSetup: { cache in
                var timestampMs: Int64 = 1234567890000
                
                cache.when { $0.clockOffsetMs }.thenReturn(0)
                cache
                    .when { $0.currentOffsetTimestampMs() }
                    .thenReturn { _, _ in
                        /// **Note:** We need to increment this value every time it's accessed because otherwise any functions which
                        /// insert multiple `Interaction` values can end up running into unique constraint conflicts due to the timestamp
                        /// being identical between different interactions
                        timestampMs += 1
                        return timestampMs
                    }
            }
        )
        @TestState var threadVariant: SessionThread.Variant! = .contact
        @TestState var didTriggerSearchCallbackTriggered: Bool! = false
        @TestState var viewModel: ThreadSettingsViewModel!
        @TestState var disposables: [AnyCancellable]! = []
        @TestState var screenTransitions: [(destination: UIViewController, transition: TransitionType)]! = []
        
        func item(section: ThreadSettingsViewModel.Section, id: ThreadSettingsViewModel.TableItem) -> Item? {
            return viewModel.tableData
                .first(where: { (sectionModel: ThreadSettingsViewModel.SectionModel) -> Bool in
                    sectionModel.model == section
                })?
                .elements
                .first(where: { (item: SessionCell.Info<ThreadSettingsViewModel.TableItem>) -> Bool in
                    item.id == id
                })
        }
        func setupTestSubscriptions() {
            viewModel.tableDataPublisher
                .receive(on: ImmediateScheduler.shared)
                .sink(
                    receiveCompletion: { _ in },
                    receiveValue: { viewModel.updateTableData($0) }
                )
                .store(in: &disposables)
            viewModel.navigatableState.transitionToScreen
                .receive(on: ImmediateScheduler.shared)
                .sink(
                    receiveCompletion: { _ in },
                    receiveValue: { screenTransitions.append($0) }
                )
                .store(in: &disposables)
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
                
                viewModel = ThreadSettingsViewModel(
                    threadId: user2Pubkey,
                    threadVariant: .contact,
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
                    
                    viewModel = ThreadSettingsViewModel(
                        threadId: userPubkey,
                        threadVariant: .contact,
                        didTriggerSearch: {
                            didTriggerSearchCallbackTriggered = true
                        },
                        using: dependencies
                    )
                    setupTestSubscriptions()
                }
                
                // MARK: ---- has the correct title
                it("has the correct title") {
                    expect(viewModel.title).to(equal("sessionSettings".localized()))
                }
                
                // MARK: ---- has the correct display name
                it("has the correct display name") {
                    let item: Item? = await expect(item(section: .conversationInfo, id: .displayName))
                        .toEventuallyNot(beNil())
                        .retrieveValue()
                    expect(item?.title?.text).to(equal("noteToSelf".localized()))
                }
                
                // MARK: ---- has no edit icon
                it("has no edit icon") {
                    let item: Item? = await expect(item(section: .conversationInfo, id: .displayName))
                        .toEventuallyNot(beNil())
                        .retrieveValue()
                    expect(item?.leadingAccessory).to(beNil())
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
                    
                    viewModel = ThreadSettingsViewModel(
                        threadId: user2Pubkey,
                        threadVariant: .contact,
                        didTriggerSearch: {
                            didTriggerSearchCallbackTriggered = true
                        },
                        using: dependencies
                    )
                    setupTestSubscriptions()
                }
                
                // MARK: ---- has the correct title
                it("has the correct title") {
                    expect(viewModel.title).to(equal("sessionSettings".localized()))
                }
                
                // MARK: ---- has the correct display name
                it("has the correct display name") {
                    let item: Item? = await expect(item(section: .conversationInfo, id: .displayName))
                        .toEventuallyNot(beNil())
                        .retrieveValue()
                    expect(item?.title?.text).to(equal("TestUser"))
                }
                
                // MARK: ---- has an edit icon
                it("has an edit icon") {
                    let item: Item? = await expect(item(section: .conversationInfo, id: .displayName))
                        .toEventuallyNot(beNil())
                        .retrieveValue()
                    expect(item?.trailingAccessory).toNot(beNil())
                }
                
                // MARK: ---- presents a confirmation modal when tapped
                it("presents a confirmation modal when tapped") {
                    let item: Item? = await expect(item(section: .conversationInfo, id: .displayName))
                        .toEventuallyNot(beNil())
                        .retrieveValue()
                    await item?.onTap?()
                    await expect(screenTransitions.first?.destination)
                        .toEventually(beAKindOf(ConfirmationModal.self))
                    expect(screenTransitions.first?.transition).to(equal(TransitionType.present))
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
                        await item?.onTap?()
                        await expect(screenTransitions.first?.destination)
                            .toEventually(beAKindOf(ConfirmationModal.self))
                        
                        modal = (screenTransitions.first?.destination as? ConfirmationModal)
                        modalInfo = await modal?.info
                        switch await modal?.info.body {
                            case .input(_, _, let onChange_): onChange = onChange_
                            default: break
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
                    
                    viewModel = ThreadSettingsViewModel(
                        threadId: legacyGroupPubkey,
                        threadVariant: .legacyGroup,
                        didTriggerSearch: {
                            didTriggerSearchCallbackTriggered = true
                        },
                        using: dependencies
                    )
                    setupTestSubscriptions()
                }
                
                // MARK: ---- has the correct title
                it("has the correct title") {
                    expect(viewModel.title).to(equal("deleteAfterGroupPR1GroupSettings".localized()))
                }
                
                // MARK: ---- has the correct display name
                it("has the correct display name") {
                    let item: Item? = await expect(item(section: .conversationInfo, id: .displayName))
                        .toEventuallyNot(beNil())
                        .retrieveValue()
                    expect(item?.title?.text).to(equal("TestGroup"))
                }
                
                // MARK: ---- when the user is a standard member
                context("when the user is a standard member") {
                    // MARK: ------ has no edit icon
                    it("has no edit icon") {
                        let item: Item? = await expect(item(section: .conversationInfo, id: .displayName))
                            .toEventuallyNot(beNil())
                            .retrieveValue()
                        expect(item?.leadingAccessory).to(beNil())
                    }
                    
                    // MARK: ------ does nothing when tapped
                    it("does nothing when tapped") {
                        let item: Item? = await expect(item(section: .conversationInfo, id: .displayName))
                            .toEventuallyNot(beNil())
                            .retrieveValue()
                        await item?.onTap?()
                        await expect(screenTransitions).toEventually(beEmpty())
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
                        
                        viewModel = ThreadSettingsViewModel(
                            threadId: legacyGroupPubkey,
                            threadVariant: .legacyGroup,
                            didTriggerSearch: {
                                didTriggerSearchCallbackTriggered = true
                            },
                            using: dependencies
                        )
                        setupTestSubscriptions()
                    }
                    
                    // MARK: ------ has an edit icon
                    it("has an edit icon") {
                        let item: Item? = await expect(item(section: .conversationInfo, id: .displayName))
                            .toEventuallyNot(beNil())
                            .retrieveValue()
                        expect(item?.trailingAccessory).toNot(beNil())
                    }
                    
                    // MARK: ------ presents a confirmation modal when tapped
                    it("presents a confirmation modal when tapped") {
                        let item: Item? = await expect(item(section: .conversationInfo, id: .displayName))
                            .toEventuallyNot(beNil())
                            .retrieveValue()
                        expect(item?.trailingAccessory).toNot(beNil())
                        await item?.onTap?()
                        await expect(screenTransitions.first?.destination)
                            .toEventually(beAKindOf(ConfirmationModal.self))
                        expect(screenTransitions.first?.transition).to(equal(TransitionType.present))
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
                    
                    viewModel = ThreadSettingsViewModel(
                        threadId: groupPubkey,
                        threadVariant: .group,
                        didTriggerSearch: {
                            didTriggerSearchCallbackTriggered = true
                        },
                        using: dependencies
                    )
                    setupTestSubscriptions()
                }
                
                // MARK: ---- has the correct title
                it("has the correct title") {
                    expect(viewModel.title).to(equal("deleteAfterGroupPR1GroupSettings".localized()))
                }
                
                // MARK: ---- has the correct display name
                it("has the correct display name") {
                    let item: Item? = await expect(item(section: .conversationInfo, id: .displayName))
                        .toEventuallyNot(beNil())
                        .retrieveValue()
                    expect(item?.title?.text).to(equal("TestGroup"))
                }
                
                // MARK: ---- when the user is a standard member
                context("when the user is a standard member") {
                    // MARK: ------ has no edit icon
                    it("has no edit icon") {
                        let item: Item? = await expect(item(section: .conversationInfo, id: .displayName))
                            .toEventuallyNot(beNil())
                            .retrieveValue()
                        expect(item?.leadingAccessory).to(beNil())
                    }
                    
                    // MARK: ------ does nothing when tapped
                    it("does nothing when tapped") {
                        let item: Item? = await expect(item(section: .conversationInfo, id: .displayName))
                            .toEventuallyNot(beNil())
                            .retrieveValue()
                        await item?.onTap?()
                        await expect(screenTransitions).toEventually(beEmpty())
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
                        
                        viewModel = ThreadSettingsViewModel(
                            threadId: groupPubkey,
                            threadVariant: .group,
                            didTriggerSearch: {
                                didTriggerSearchCallbackTriggered = true
                            },
                            using: dependencies
                        )
                        setupTestSubscriptions()
                    }
                    
                    // MARK: ------ has an edit icon
                    it("has an edit icon") {
                        let item: Item? = await expect(item(section: .conversationInfo, id: .displayName))
                            .toEventuallyNot(beNil())
                            .retrieveValue()
                        expect(item?.trailingAccessory).toNot(beNil())
                    }
                    
                    // MARK: ------ presents a confirmation modal when tapped
                    it("presents a confirmation modal when tapped") {
                        let item: Item? = await expect(item(section: .conversationInfo, id: .displayName))
                            .toEventuallyNot(beNil())
                            .retrieveValue()
                        expect(item?.trailingAccessory).toNot(beNil())
                        await item?.onTap?()
                        await expect(screenTransitions.first?.destination)
                            .toEventually(beAKindOf(ConfirmationModal.self))
                        expect(screenTransitions.first?.transition).to(equal(TransitionType.present))
                    }
                    
                    // MARK: ------ when updating the group info
                    context("when updating the group info") {
                        @TestState var onChange: ((String) -> ())?
                        @TestState var onChange2: ((String, String) -> ())?
                        @TestState var modal: ConfirmationModal?
                        @TestState var modalInfo: ConfirmationModal.Info?
                        
                        beforeEach {
                            dependencies[feature: .updatedGroupsAllowDescriptionEditing] = true
                            viewModel = ThreadSettingsViewModel(
                                threadId: groupPubkey,
                                threadVariant: .group,
                                didTriggerSearch: {
                                    didTriggerSearchCallbackTriggered = true
                                },
                                using: dependencies
                            )
                            setupTestSubscriptions()
                            
                            let item: Item? = await expect(item(section: .conversationInfo, id: .displayName))
                                .toEventuallyNot(beNil())
                                .retrieveValue()
                            await item?.onTap?()
                            await expect(screenTransitions.first?.destination)
                                .toEventually(beAKindOf(ConfirmationModal.self))
                            
                            modal = (screenTransitions.first?.destination as? ConfirmationModal)
                            modalInfo = await modal?.info
                            switch modalInfo?.body {
                                case .input(_, _, let onChange_): onChange = onChange_
                                case .dualInput(_, _, _, let onChange2_): onChange2 = onChange2_
                                default: break
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
                            
                            let groups: [ClosedGroup]? = await expect(mockStorage.read { db in try ClosedGroup.fetchAll(db) })
                                .toEventuallyNot(beEmpty())
                                .retrieveValue()
                            expect(groups?.map { $0.name }.asSet()).to(equal(["TestNewGroupName"]))
                        }
                        
                        // MARK: -------- updates the group description when valid
                        it("updates the group description when valid") {
                            onChange2?("Test", "TestNewGroupDescription")
                            await modal?.confirmationPressed()
                            
                            let groups: [ClosedGroup]? = await expect(mockStorage.read { db in try ClosedGroup.fetchAll(db) })
                                .toEventuallyNot(beEmpty())
                                .retrieveValue()
                            expect(groups?.map { $0.groupDescription }.asSet()).to(equal(["TestNewGroupDescription"]))
                        }
                        
                        // MARK: -------- inserts a control message
                        it("inserts a control message") {
                            onChange2?("TestNewGroupName", "")
                            await modal?.confirmationPressed()
                            
                            let interactions: [Interaction]? = await expect(mockStorage.read { db in try Interaction.fetchAll(db) })
                                .toEventuallyNot(beEmpty())
                                .retrieveValue()
                            expect(interactions?.first?.variant).to(equal(.infoGroupInfoUpdated))
                            expect(interactions?.first?.body)
                                .to(equal(
                                    ClosedGroup.MessageInfo
                                        .updatedName("TestNewGroupName")
                                        .infoString(using: dependencies)
                                ))
                        }
                        
                        // MARK: -------- schedules a control message to be sent
                        it("schedules a control message to be sent") {
                            onChange2?("TestNewGroupName", "")
                            await modal?.confirmationPressed()
                            
                            await expect(mockJobRunner)
                                .toEventually(call(matchingParameters: .all) {
                                    $0.add(
                                        .any,
                                        job: Job(
                                            variant: .messageSend,
                                            behaviour: .runOnceAfterConfigSyncIgnoringPermanentFailure,
                                            threadId: groupPubkey,
                                            interactionId: nil,
                                            details: MessageSendJob.Details(
                                                destination: .closedGroup(groupPublicKey: groupPubkey),
                                                message: try GroupUpdateInfoChangeMessage(
                                                    changeType: .name,
                                                    updatedName: "TestNewGroupName",
                                                    sentTimestampMs: UInt64(1234567890002),
                                                    authMethod: Authentication.groupAdmin(
                                                        groupSessionId: SessionId(.group, hex: groupPubkey),
                                                        ed25519SecretKey: [1, 2, 3]
                                                    ),
                                                    using: dependencies
                                                ),
                                                requiredConfigSyncVariant: .groupInfo
                                            )
                                        ),
                                        dependantJob: nil,
                                        canStartJob: false
                                    )
                                })
                        }
                        
                        // MARK: -------- triggers a libSession change
                        it("triggers a libSession change") {
                            mockLibSessionCache
                                .when { $0.isAdmin(groupSessionId: .any) }
                                .thenReturn(true)
                            
                            onChange2?("Test", "TestNewGroupDescription")
                            await modal?.confirmationPressed()
                            
                            await expect(mockLibSessionCache)
                                .toEventually(call(matchingParameters: .all) {
                                    try $0.performAndPushChange(
                                        .any,
                                        for: .userGroups,
                                        sessionId: SessionId(.standard, hex: userPubkey),
                                        change: { _ in }
                                    )
                                })
                            expect(mockLibSessionCache)
                                .to(call(matchingParameters: .all) {
                                    try $0.performAndPushChange(
                                        .any,
                                        for: .groupInfo,
                                        sessionId: SessionId(.group, hex: groupPubkey),
                                        change: { _ in }
                                    )
                                })
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
                            isActive: false,
                            name: "TestCommunity",
                            userCount: 1,
                            infoUpdates: 1
                        ).insert(db)
                    }
                    
                    viewModel = ThreadSettingsViewModel(
                        threadId: communityId,
                        threadVariant: .community,
                        didTriggerSearch: {
                            didTriggerSearchCallbackTriggered = true
                        },
                        using: dependencies
                    )
                    setupTestSubscriptions()
                }
                
                // MARK: ---- has the correct title
                it("has the correct title") {
                    expect(viewModel.title).to(equal("deleteAfterGroupPR1GroupSettings".localized()))
                }
                
                // MARK: ---- has the correct display name
                it("has the correct display name") {
                    let item: Item? = await expect(item(section: .conversationInfo, id: .displayName))
                        .toEventuallyNot(beNil())
                        .retrieveValue()
                    expect(item?.title?.text).to(equal("TestCommunity"))
                }
                
                // MARK: ---- has no edit icon
                it("has no edit icon") {
                    let item: Item? = await expect(item(section: .conversationInfo, id: .displayName))
                        .toEventuallyNot(beNil())
                        .retrieveValue()
                    expect(item?.leadingAccessory).to(beNil())
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
        }
    }
}
