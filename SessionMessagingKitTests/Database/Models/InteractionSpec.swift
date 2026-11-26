// Copyright © 2026 Session Technology Foundation. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit
import TestUtilities

import Quick
import Nimble

@testable import SessionMessagingKit

class InteractionSpec: AsyncSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies { dependencies in
            dependencies.dateNow = Date(timeIntervalSince1970: 1234567890)
        }
        @TestState var mockStorage: Storage! = try! Storage.createForTesting(using: dependencies)
        @TestState var mockGeneralCache: MockGeneralCache! = .create(using: dependencies)
        @TestState var mockLibSessionCache: MockLibSessionCache! = .create(using: dependencies)
        @TestState var userSessionId: SessionId! = SessionId(.standard, hex: TestConstants.publicKey)
        
        let ordinaryThreadId: String = "05\(String(repeating: "1", count: 64))"
        let mutedThreadId: String = "05\(String(repeating: "2", count: 64))"
        let messageRequestThreadId: String = "05\(String(repeating: "3", count: 64))"
        let blockedThreadId: String = "05\(String(repeating: "4", count: 64))"
        let hiddenThreadId: String = "05\(String(repeating: "5", count: 64))"
        
        func insertContactThread(
            _ db: ObservingDatabase,
            id: String,
            shouldBeVisible: Bool = true,
            mutedUntilTimestamp: TimeInterval? = nil,
            isApproved: Bool = true,
            isBlocked: Bool = false,
            unreadCount: Int
        ) throws {
            try SessionThread(
                id: id,
                variant: .contact,
                creationDateTimestamp: 1234567800,
                shouldBeVisible: shouldBeVisible,
                mutedUntilTimestamp: mutedUntilTimestamp
            ).insert(db)
            try Contact(
                id: id,
                isApproved: isApproved,
                isBlocked: isBlocked,
                currentUserSessionId: userSessionId
            ).insert(db)
            
            try (0..<unreadCount).forEach { index in
                _ = try Interaction(
                    threadId: id,
                    threadVariant: .contact,
                    authorId: id,
                    variant: .standardIncoming,
                    body: "Test\(index)",
                    timestampMs: (1234567800000 + Int64(index)),
                    wasRead: false,
                    using: dependencies
                ).inserted(db)
            }
        }
        
        func badgeCount() async throws -> Int {
            return try await mockStorage.read { db in
                try Interaction.fetchAppBadgeUnreadCount(db, using: dependencies)
            }
        }
        
        beforeEach {
            dependencies.set(cache: .general, to: mockGeneralCache)
            try await mockGeneralCache.defaultInitialSetup()
            
            dependencies.set(cache: .libSession, to: mockLibSessionCache)
            try await mockLibSessionCache.defaultInitialSetup()
            try await mockLibSessionCache
                .when { $0.isMessageRequest(threadId: .any, threadVariant: .any) }
                .thenReturn { args in (args.first as? String) == messageRequestThreadId }
            
            dependencies.set(singleton: .storage, to: mockStorage)
            try await mockStorage.perform(migrations: SNMessagingKit.migrations)
        }
        
        // MARK: - an Interaction
        describe("an Interaction") {
            // MARK: -- when fetching the app badge unread count
            context("when fetching the app badge unread count") {
                // MARK: ---- counts unread messages in an ordinary conversation
                it("counts unread messages in an ordinary conversation") {
                    try await mockStorage.write { db in
                        try insertContactThread(db, id: ordinaryThreadId, unreadCount: 2)
                    }
                    
                    let count1: Int = try await badgeCount()
                    expect(count1).to(equal(2))
                }
                
                // MARK: ---- does not count unread messages from a blocked contact
                it("does not count unread messages from a blocked contact") {
                    try await mockStorage.write { db in
                        try insertContactThread(db, id: ordinaryThreadId, unreadCount: 1)
                        try insertContactThread(db, id: blockedThreadId, isBlocked: true, unreadCount: 2)
                    }
                    
                    let count2: Int = try await badgeCount()
                    expect(count2).to(equal(1))
                }
                
                // MARK: ---- counts a contact's unread messages again once they are unblocked
                it("counts a contact's unread messages again once they are unblocked") {
                    try await mockStorage.write { db in
                        try insertContactThread(db, id: blockedThreadId, isBlocked: true, unreadCount: 2)
                    }
                    let count3: Int = try await badgeCount()
                    expect(count3).to(equal(0))
                    
                    try await mockStorage.write { db in
                        try Contact
                            .filter(id: blockedThreadId)
                            .updateAll(db, Contact.Columns.isBlocked.set(to: false))
                    }
                    let count4: Int = try await badgeCount()
                    expect(count4).to(equal(2))
                }
                
                // MARK: ---- does not count unread messages in a hidden conversation
                it("does not count unread messages in a hidden conversation") {
                    try await mockStorage.write { db in
                        try insertContactThread(db, id: ordinaryThreadId, unreadCount: 1)
                        try insertContactThread(db, id: hiddenThreadId, shouldBeVisible: false, unreadCount: 2)
                    }
                    
                    let count5: Int = try await badgeCount()
                    expect(count5).to(equal(1))
                }
                
                // MARK: ---- only counts conversations the home screen shows
                it("only counts conversations the home screen shows") {
                    try await mockStorage.write { db in
                        try insertContactThread(db, id: ordinaryThreadId, unreadCount: 2)
                        try insertContactThread(
                            db,
                            id: mutedThreadId,
                            mutedUntilTimestamp: (1234567890 + 1000),
                            unreadCount: 1
                        )
                        try insertContactThread(db, id: messageRequestThreadId, isApproved: false, unreadCount: 1)
                        try insertContactThread(db, id: blockedThreadId, isBlocked: true, unreadCount: 1)
                        try insertContactThread(db, id: hiddenThreadId, shouldBeVisible: false, unreadCount: 1)
                    }
                    
                    let homeThreadIds: Set<String> = try await mockStorage.read { db in
                        let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
                        let contact: TypedTableAlias<Contact> = TypedTableAlias()
                        let closedGroup: TypedTableAlias<ClosedGroup> = TypedTableAlias()
                        let request: SQLRequest<String> = """
                            SELECT \(thread[.id])
                            FROM \(SessionThread.self)
                            LEFT JOIN \(Contact.self) ON \(contact[.id]) = \(thread[.id])
                            LEFT JOIN \(ClosedGroup.self) ON \(closedGroup[.threadId]) = \(thread[.id])
                            WHERE \(ConversationInfoViewModel.homeFilterSQL(userSessionId: userSessionId))
                        """
                        
                        return try request.fetchSet(db)
                    }
                    
                    /// The list shows the ordinary and muted conversations, and the badge counts the ordinary one (it deliberately
                    /// leaves out muted conversations and message requests)
                    expect(homeThreadIds).to(equal([ordinaryThreadId, mutedThreadId]))
                    let count6: Int = try await badgeCount()
                    expect(count6).to(equal(2))
                }
            }
        }
    }
}
