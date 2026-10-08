// Copyright © 2026 Session Technology Foundation. All rights reserved.

import UIKit
import SwiftUI
import Quick
import Nimble
import SessionUIKit
import SessionUtilitiesKit
import TestUtilities

@testable import SessionUIKit
@testable import SessionMessagingKit
@testable import Session

class MessageInfoTruncationSpec: AsyncSpec {
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
        @TestState var screenWidth: CGFloat! = 390

        /// The reported overflow reduced to its shape, and generated rather than copied - the message that found
        /// the bug is deliberately not in the repo. 991 ASCII characters over 10 lines: one 395-character line, six
        /// `- ` list items and two blank lines, which is well under the 2,000-character non-Pro limit
        @TestState var fixtureBody: String! = {
            func filler(_ length: Int) -> String {
                return String(String(repeating: "lorem ipsum dolor sit amet ", count: ((length / 27) + 1)).prefix(length))
            }

            let listItems: [String] = (1...6).map { index in "- item \(index) \(filler(71))" }

            return ([filler(395), ""] + listItems + ["", filler(107)]).joined(separator: "\n")
        }()

        @TestState var quoteViewModel: QuoteViewModel! = QuoteViewModel(
            mode: .regular,
            direction: .incoming,
            quotedInfo: QuoteViewModel.QuotedInfo(
                interactionId: 2,
                authorId: threadId,
                authorName: "TestUser",
                timestampMs: 1234567890000,
                body: fixtureBody,
                attachmentInfo: nil
            ),
            showProBadge: false,
            currentUserSessionIds: [],
            displayNameRetriever: { _, _ in nil },
            currentUserMentionImage: nil
        )

        /// A reply whose quoted original carries the same body, which is what the report describes
        func makeViewModel() -> MessageViewModel {
            let timestampMs: Int64 = 1234567890000
            let dataCache: ConversationDataCache = ConversationDataCache(
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
            let quotedInteraction: Interaction = Interaction(
                threadId: threadId,
                threadVariant: .contact,
                authorId: threadId,
                variant: .standardIncoming,
                body: fixtureBody,
                timestampMs: (timestampMs - 1000),
                using: dependencies
            )

            return MessageViewModel(
                optimisticMessageId: 1,
                interaction: Interaction(
                    threadId: threadId,
                    threadVariant: .contact,
                    authorId: threadId,
                    variant: .standardIncoming,
                    body: fixtureBody,
                    timestampMs: timestampMs,
                    using: dependencies
                ),
                reactionInfo: nil,
                maybeUnresolvedQuotedInfo: MessageViewModel.MaybeUnresolvedQuotedInfo(
                    foundQuotedInteractionId: 2,
                    resolvedQuotedInteraction: quotedInteraction
                ),
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

        /// A `UIViewRepresentable`'s `UILabel` only exists once SwiftUI has actually rendered it, so the view has to
        /// be hosted and laid out rather than inspected
        @MainActor func labels<Content: View>(
            renderedIn view: Content,
            width: CGFloat
        ) -> [(label: UILabel, frame: CGRect)] {
            let host: UIHostingController<Content> = UIHostingController(rootView: view)
            let window: UIWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 2000))
            window.rootViewController = host
            window.isHidden = false
            host.view.frame = window.bounds
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()

            func collect(_ view: UIView) -> [UILabel] {
                return (view as? UILabel).map { [$0] } ?? view.subviews.flatMap { collect($0) }
            }

            return collect(host.view)
                .map { (label: $0, frame: $0.convert($0.bounds, to: host.view)) }
                .sorted { $0.frame.minY < $1.frame.minY }
        }

        beforeEach {
            /// Nothing applies a `themeAttributedText` until a theme has been loaded, and an unthemed label holds no
            /// text at all - so without this every label lays out to nothing and the height assertions read zero
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

        // MARK: - Message Info truncation
        describe("Message Info truncation") {
            // MARK: -- uses a fixture of the shape that was reported
            it("uses a fixture of the shape that was reported") {
                expect(fixtureBody.count).to(equal(991))
                expect(fixtureBody.components(separatedBy: "\n").count).to(equal(10))
                expect(fixtureBody.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }.count).to(equal(6))
                expect(fixtureBody.components(separatedBy: "\n").filter { $0.isEmpty }.count).to(equal(2))
                expect(fixtureBody.components(separatedBy: "\n").map { $0.count }.max()).to(equal(395))
                expect(fixtureBody.allSatisfy { $0.isASCII }).to(beTrue())
            }

            // MARK: -- never wraps a label wider than the width its caller gave it
            it("never wraps a label wider than the width its caller gave it") {
                /// The label takes its wrapping width from its own bounds, so a caller that *does* know its width
                /// has to win - otherwise a label laid out too wide keeps itself there, and the bubble it is in
                /// grows off the screen
                let preferredWidth: CGFloat = await MainActor.run {
                    let label: AttributedLabel.SelfSizingLabel = AttributedLabel.SelfSizingLabel()
                    label.explicitMaxWidth = 250
                    label.frame = CGRect(x: 0, y: 0, width: 900, height: 50)
                    label.layoutIfNeeded()
                    
                    return label.preferredMaxLayoutWidth
                }
                
                expect(preferredWidth).to(equal(250))
            }
            
            // MARK: -- caps a quoted message at two lines
            it("caps a quoted message at two lines") {
                let twoLines: CGFloat = (2 * UIFont.systemFont(ofSize: Values.smallFontSize).lineHeight)
                let quoteLabels: [(label: UILabel, frame: CGRect)] = await MainActor.run {
                    labels(
                        renderedIn: QuoteView_SwiftUI(
                            viewModel: quoteViewModel,
                            dataManager: ImageDataManager()
                        ),
                        width: screenWidth
                    )
                }

                expect(quoteLabels.count).to(equal(1))
                expect(quoteLabels.first?.label.numberOfLines).to(equal(2))
                expect(quoteLabels.first?.frame.height).to(beGreaterThan(0))
                expect(quoteLabels.first?.frame.height).to(beLessThanOrEqualTo(twoLines + 1))
                
                /// A cap on the height alone is satisfied by a label that put the whole message on one very long
                /// line and widened its container off the screen, which is the other half of this bug
                expect(quoteLabels.first?.frame.maxX).to(beLessThanOrEqualTo(screenWidth))
            }

            // MARK: -- keeps the bubble's quote and body within their caps
            it("keeps the bubble's quote and body within their caps") {
                let cellViewModel: MessageViewModel = makeViewModel()
                let twoLines: CGFloat = (2 * UIFont.systemFont(ofSize: Values.smallFontSize).lineHeight)
                let maxBodyHeight: CGFloat = VisibleMessageCell.getMaxHeightAfterTruncation(for: cellViewModel)
                let bubbleLabels: [(label: UILabel, frame: CGRect)] = await MainActor.run {
                    labels(
                        renderedIn: MessageBubble(
                            messageViewModel: cellViewModel,
                            attachmentOnly: false,
                            dependencies: dependencies
                        ),
                        width: screenWidth
                    )
                }

                /// Sorted top to bottom, so the quote is first and the body second
                expect(bubbleLabels.count).to(equal(2))
                expect(bubbleLabels.first?.frame.height).to(beGreaterThan(0))
                expect(bubbleLabels.first?.frame.height).to(beLessThanOrEqualTo(twoLines + 1))
                expect(bubbleLabels.last?.frame.height).to(beGreaterThan(0))
                expect(bubbleLabels.last?.frame.height).to(beLessThanOrEqualTo(maxBodyHeight + 1))
                expect(bubbleLabels.map { $0.frame.maxX }.max()).to(beLessThanOrEqualTo(screenWidth))
            }
        }
    }
}
