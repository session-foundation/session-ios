// Copyright © 2026 Session Technology Foundation. All rights reserved.

import UIKit
import Quick
import Nimble
import SessionUIKit
import SessionUtilitiesKit
import TestUtilities

@testable import SessionMessagingKit
@testable import Session

class VisibleMessageCellSpec: AsyncSpec {
    override class func spec() {
        // MARK: Configuration

        @TestState var threadId: String! = "05\(TestConstants.publicKey)"
        @TestState var userSessionId: SessionId! = SessionId(.standard, hex: TestConstants.publicKey)
        @TestState var dependencies: TestDependencies! = TestDependencies { dependencies in
            dependencies[singleton: .scheduler] = .immediate
            dependencies.dateNow = Date(timeIntervalSince1970: 1234567890)
            dependencies.forceSynchronous = true
        }
        @TestState var mockStorage: Storage! = try! Storage.createForTesting(using: dependencies)
        @TestState var mockGeneralCache: MockGeneralCache! = .create(using: dependencies)
        @TestState var mockLibSessionCache: MockLibSessionCache! = .create(using: dependencies)
        @TestState var mockNetwork: MockNetwork! = .create(using: dependencies)
        @TestState var tableSize: CGSize! = CGSize(width: 390, height: 844)

        /// Synthetic, and long enough that the 25-line cap has something to remove
        @TestState var longBody: String! = (1...40)
            .map { "Line \($0) of a message that has to be long enough to truncate." }
            .joined(separator: "\n")

        func makeViewModel(withLinkPreview: Bool) -> MessageViewModel {
            let linkPreviewUrl: String = "https://example.com/some-page"
            let timestampMs: Int64 = 1234567890000
            var dataCache: ConversationDataCache = ConversationDataCache(
                userSessionId: userSessionId,
                context: ConversationDataCache.Context(
                    source: .messageList(threadId: threadId),
                    requireFullRefresh: false,
                    requireAuthMethodFetch: false,
                    requiresMessageRequestCountUpdate: false,
                    requiresPinnedConversationCountUpdate: false,
                    requiresInitialUnreadInteractionInfo: false,
                    requireRecentReactionEmojiUpdate: false
                )
            )

            if withLinkPreview {
                dataCache.insert(linkPreviews: [
                    LinkPreview(
                        url: linkPreviewUrl,
                        messageSentTimestampMs: UInt64(timestampMs),
                        variant: .standard,
                        title: "Example",
                        using: dependencies
                    )
                ])
            }

            let interaction: Interaction = Interaction(
                threadId: threadId,
                threadVariant: .contact,
                authorId: threadId,
                variant: .standardIncoming,
                body: longBody,
                timestampMs: timestampMs,
                linkPreviewUrl: (withLinkPreview ? linkPreviewUrl : nil),
                using: dependencies
            )

            return MessageViewModel(
                optimisticMessageId: 1,
                interaction: interaction,
                reactionInfo: nil,
                maybeUnresolvedQuotedInfo: nil,
                userSessionId: userSessionId,
                threadInfo: ConversationInfoViewModel(
                    thread: SessionThread(
                        id: threadId,
                        variant: .contact,
                        creationDateTimestamp: 0
                    ),
                    dataCache: dataCache,
                    using: dependencies
                ),
                dataCache: dataCache,
                previousInteraction: nil,
                nextInteraction: nil,
                isLast: true,
                isLastOutgoing: false,
                currentUserMentionImage: nil,
                using: dependencies
            )!
        }

        /// Lays the cell out the way the table does, so the assertions are about rendered geometry rather than
        /// about what the cell was asked for
        @MainActor func makeCell(for cellViewModel: MessageViewModel, shouldExpanded: Bool) -> VisibleMessageCell {
            /// `init(style:reuseIdentifier:)` is what runs `setUpViewHierarchy`, so a cell built any other way has
            /// no constraints and lays out to nothing
            let cell: VisibleMessageCell = VisibleMessageCell(style: .default, reuseIdentifier: nil)
            cell.frame = CGRect(origin: .zero, size: tableSize)
            cell.update(
                with: cellViewModel,
                playbackInfo: nil,
                showExpandedReactions: false,
                shouldExpanded: shouldExpanded,
                lastSearchText: nil,
                tableSize: tableSize,
                using: dependencies
            )
            cell.setNeedsLayout()
            cell.layoutIfNeeded()

            return cell
        }

        beforeEach {
            /// Nothing applies a `themeAttributedText` until a theme has been loaded, and an unthemed label holds no
            /// text at all - so without this the cell lays out to nothing and every height assertion reads zero
            await MainActor.run { ThemeManager.updateThemeState(theme: .classicDark) }
            
            /// Building a `MessageViewModel` resolves `sessionProManager`, whose background tasks are cancelled
            /// only in its `deinit` - and `Task.cancel()` cannot interrupt a `fetchOne` already inside SQLCipher,
            /// so one of those reads outlives the spec. It needs a storage of its own rather than the app's real one
            dependencies.set(singleton: .storage, to: mockStorage)
            
            dependencies.set(cache: .general, to: mockGeneralCache)
            try await mockGeneralCache.defaultInitialSetup()

            dependencies.set(cache: .libSession, to: mockLibSessionCache)
            try await mockLibSessionCache.defaultInitialSetup()

            dependencies.set(singleton: .network, to: mockNetwork)
            try await mockNetwork.defaultInitialSetup(using: dependencies)
        }

        // MARK: - a VisibleMessageCell
        describe("a VisibleMessageCell") {
            // MARK: -- when the body is truncated alongside a standard link preview
            context("when the body is truncated alongside a standard link preview") {
                // MARK: ---- expands the body when the read more handler lifts the line limit
                it("expands the body when the read more handler lifts the line limit") {
                    let cellViewModel: MessageViewModel = makeViewModel(withLinkPreview: true)
                    let (collapsedHeight, expandedHeight, maxHeight): (CGFloat, CGFloat, CGFloat) = await MainActor.run {
                        let cell: VisibleMessageCell = makeCell(for: cellViewModel, shouldExpanded: false)
                        let collapsedHeight: CGFloat = (cell.bodyLabel?.frame.height ?? 0)

                        /// What `handleTap` does when the read more button is tapped
                        cell.bodyLabel?.numberOfLines = 0
                        cell.bodyLabel?.invalidateIntrinsicContentSize()
                        cell.setNeedsLayout()
                        cell.layoutIfNeeded()

                        return (
                            collapsedHeight,
                            (cell.bodyLabel?.frame.height ?? 0),
                            VisibleMessageCell.getMaxHeightAfterTruncation(for: cellViewModel)
                        )
                    }

                    expect(collapsedHeight).to(beGreaterThan(0))
                    expect(collapsedHeight).to(beLessThanOrEqualTo(maxHeight + 1))
                    expect(expandedHeight).to(beGreaterThan(collapsedHeight))
                }

                // MARK: ---- gives the read more handler the stack view that holds the body
                it("gives the read more handler the stack view that holds the body") {
                    let cellViewModel: MessageViewModel = makeViewModel(withLinkPreview: true)
                    let bodyIsInContainer: Bool = await MainActor.run {
                        let cell: VisibleMessageCell = makeCell(for: cellViewModel, shouldExpanded: false)

                        guard
                            let stackView: UIStackView = cell.bodyContainerStackView,
                            let bodyLabel: UILabel = cell.bodyLabel
                        else { return false }

                        return bodyLabel.isDescendant(of: stackView)
                    }

                    expect(bodyIsInContainer).to(beTrue())
                }
            }

            // MARK: -- when reused
            context("when reused") {
                // MARK: ---- drops its reference to the previous body container
                it("drops its reference to the previous body container") {
                    let cellViewModel: MessageViewModel = makeViewModel(withLinkPreview: false)
                    let containerAfterReuse: UIStackView? = await MainActor.run {
                        let cell: VisibleMessageCell = makeCell(for: cellViewModel, shouldExpanded: false)
                        cell.prepareForReuse()

                        return cell.bodyContainerStackView
                    }

                    expect(containerAfterReuse).to(beNil())
                }
            }
        }
    }
}
