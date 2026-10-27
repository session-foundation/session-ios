// Copyright © 2026 Session Technology Foundation. All rights reserved.

import Foundation
import Quick
import Nimble

@testable import SessionMessagingKit

class CallMessageExtensionHandlingSpec: QuickSpec {
    override class func spec() {
        let ongoingCallUuid: String = "11111111-1111-1111-1111-111111111111"
        let otherCallUuid: String = "22222222-2222-2222-2222-222222222222"

        func handling(
            _ kind: CallMessage.Kind,
            uuid: String,
            areCallsEnabled: Bool = true,
            hasMicrophonePermission: Bool = true,
            isCallOngoing: Bool,
            ongoingCallUuid: String?
        ) -> MessageReceiver.CallMessageExtensionHandling {
            return MessageReceiver.callMessageExtensionHandling(
                for: CallMessage(uuid: uuid, kind: kind, sdps: []),
                areCallsEnabled: areCallsEnabled,
                hasMicrophonePermission: hasMicrophonePermission,
                isCallOngoing: isCallOngoing,
                ongoingCallUuid: ongoingCallUuid
            )
        }

        // MARK: - a CallMessage received by the notification extension
        describe("a CallMessage received by the notification extension") {
            // MARK: -- while a call is ongoing
            context("while a call is ongoing") {
                // MARK: ---- leaves every message for the ongoing call to the main app
                it("leaves every message for the ongoing call to the main app") {
                    let kinds: [CallMessage.Kind] = [
                        .preOffer,
                        .offer,
                        .answer,
                        .provisionalAnswer,
                        .iceCandidates(sdpMLineIndexes: [0], sdpMids: ["0"]),
                        .endCall
                    ]

                    kinds.forEach { kind in
                        expect(handling(kind, uuid: ongoingCallUuid, isCallOngoing: true, ongoingCallUuid: ongoingCallUuid))
                            .to(equal(.leaveForMainApp), description: "\(kind)")
                    }
                }

                // MARK: ---- responds busy to a pre-offer for a different call
                it("responds busy to a pre-offer for a different call") {
                    expect(handling(.preOffer, uuid: otherCallUuid, isCallOngoing: true, ongoingCallUuid: ongoingCallUuid))
                        .to(equal(.respondBusy))
                }

                // MARK: ---- responds busy to a pre-offer when the ongoing call's uuid is unknown
                it("responds busy to a pre-offer when the ongoing call's uuid is unknown") {
                    expect(handling(.preOffer, uuid: otherCallUuid, isCallOngoing: true, ongoingCallUuid: nil))
                        .to(equal(.respondBusy))
                }

                // MARK: ---- does not respond busy to signalling for a different call
                it("does not respond busy to signalling for a different call") {
                    expect(handling(.answer, uuid: otherCallUuid, isCallOngoing: true, ongoingCallUuid: ongoingCallUuid))
                        .to(equal(.standard))
                }

                // MARK: ---- does not respond busy to signalling when the ongoing call's uuid is unknown
                it("does not respond busy to signalling when the ongoing call's uuid is unknown") {
                    expect(handling(.answer, uuid: ongoingCallUuid, isCallOngoing: true, ongoingCallUuid: nil))
                        .to(equal(.standard))
                }

                // MARK: ---- ignores an end call message
                it("ignores an end call message") {
                    expect(handling(.endCall, uuid: otherCallUuid, isCallOngoing: true, ongoingCallUuid: ongoingCallUuid))
                        .to(equal(.standard))
                }
            }

            // MARK: -- while no call is ongoing
            context("while no call is ongoing") {
                // MARK: ---- reports a pre-offer as an incoming call
                it("reports a pre-offer as an incoming call") {
                    expect(handling(.preOffer, uuid: otherCallUuid, isCallOngoing: false, ongoingCallUuid: nil))
                        .to(equal(.reportIncomingCall))
                }

                // MARK: ---- gives other kinds the standard handling
                it("gives other kinds the standard handling") {
                    expect(handling(.answer, uuid: otherCallUuid, isCallOngoing: false, ongoingCallUuid: nil))
                        .to(equal(.standard))
                }
            }

            // MARK: -- when calls cannot be received
            context("when calls cannot be received") {
                // MARK: ---- reports a disabled calls setting
                it("reports a disabled calls setting") {
                    expect(handling(.preOffer, uuid: otherCallUuid, areCallsEnabled: false, isCallOngoing: true, ongoingCallUuid: ongoingCallUuid))
                        .to(equal(.unableToReceiveCall(.permissionDenied)))
                }

                // MARK: ---- reports a missing microphone permission
                it("reports a missing microphone permission") {
                    expect(handling(.preOffer, uuid: otherCallUuid, hasMicrophonePermission: false, isCallOngoing: false, ongoingCallUuid: nil))
                        .to(equal(.unableToReceiveCall(.permissionDeniedMicrophone)))
                }
            }
        }
    }
}
