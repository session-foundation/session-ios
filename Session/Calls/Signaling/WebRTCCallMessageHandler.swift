//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import Foundation

@objc(OWSWebRTCCallMessageHandler)
public class WebRTCCallMessageHandler: NSObject, OWSCallMessageHandler {

    // MARK: Initializers

    @objc
    public override init() {
        super.init()

        SwiftSingletons.register(self)
    }

    // MARK: - Call Handlers

    public func receivedOffer(
        _ offer: SNProtoCallMessageOffer,
        from caller: String,
        sourceDevice: UInt32,
        sentAtTimestamp: UInt64,
        serverReceivedTimestamp: UInt64,
        serverDeliveryTimestamp: UInt64,
        supportsMultiRing: Bool
    ) {
        AssertIsOnMainThread()

        let callType: SNProtoCallMessageOfferType
        if offer.hasType {
            callType = SNProtoCallMessageOfferType(rawValue: offer.type.rawValue)!
        } else {
            // The type is not defined so assume the default, audio.
            callType = .offerAudioCall
        }

        let thread = TSContactThread.getOrCreateThread(contactSessionID: caller)
        self.callService.individualCallService.handleReceivedOffer(
            thread: thread,
            callId: offer.id,
            sourceDevice: sourceDevice,
            sdp: offer.sdp,
            opaque: offer.opaque,
            sentAtTimestamp: sentAtTimestamp,
            serverReceivedTimestamp: serverReceivedTimestamp,
            serverDeliveryTimestamp: serverDeliveryTimestamp,
            callType: callType,
            supportsMultiRing: supportsMultiRing
        )
    }

    public func receivedAnswer(_ answer: SNProtoCallMessageAnswer, from caller: String, sourceDevice: UInt32, supportsMultiRing: Bool) {
        AssertIsOnMainThread()

        let thread = TSContactThread.getOrCreateThread(contactSessionID: caller)
        self.callService.individualCallService.handleReceivedAnswer(
            thread: thread,
            callId: answer.id,
            sourceDevice: sourceDevice,
            sdp: answer.sdp,
            opaque: answer.opaque,
            supportsMultiRing: supportsMultiRing
        )
    }

    public func receivedIceUpdate(_ iceUpdate: [SNProtoCallMessageIceUpdate], from caller: String, sourceDevice: UInt32) {
        AssertIsOnMainThread()

        let thread = TSContactThread.getOrCreateThread(contactSessionID: caller)
        self.callService.individualCallService.handleReceivedIceCandidates(
            thread: thread,
            callId: iceUpdate[0].id,
            sourceDevice: sourceDevice,
            candidates: iceUpdate
        )
    }

    public func receivedHangup(_ hangup: SNProtoCallMessageHangup, from caller: String, sourceDevice: UInt32) {
        AssertIsOnMainThread()

        // deviceId is optional and defaults to 0.
        var deviceId: UInt32 = 0

        let type: SNProtoCallMessageHangupType
        if hangup.hasType {
            type = SNProtoCallMessageHangupType(rawValue: hangup.type.rawValue)!

            if hangup.hasDeviceID {
                deviceId = hangup.deviceID
            }
        } else {
            // The type is not defined so assume the default, normal.
            type = .hangupNormal
        }

        let thread = TSContactThread.getOrCreateThread(contactSessionID: caller)
        self.callService.individualCallService.handleReceivedHangup(
            thread: thread,
            callId: hangup.id,
            sourceDevice: sourceDevice,
            type: type,
            deviceId: deviceId
        )
    }

    public func receivedBusy(_ busy: SNProtoCallMessageBusy, from caller: String, sourceDevice: UInt32) {
        AssertIsOnMainThread()

        let thread = TSContactThread.getOrCreateThread(contactSessionID: caller)
        self.callService.individualCallService.handleReceivedBusy(
            thread: thread,
            callId: busy.id,
            sourceDevice: sourceDevice
        )
    }

    public func receivedOpaque(
        _ opaque: SNProtoCallMessageOpaque,
        from caller: String,
        sourceDevice: UInt32,
        serverReceivedTimestamp: UInt64,
        serverDeliveryTimestamp: UInt64
    ) {
        AssertIsOnMainThread()
        Logger.info("Received opaque call message from \(caller) on device \(sourceDevice)")

        guard let message = opaque.data else {
            return owsFailDebug("Received opaque call message without data")
        }

        var messageAgeSec: UInt64 = 0
        if serverReceivedTimestamp > 0 && serverDeliveryTimestamp >= serverReceivedTimestamp {
            messageAgeSec = (serverDeliveryTimestamp - serverReceivedTimestamp) / 1000
        }

        self.callService.callManager.receivedCallMessage(
            senderUuid: caller,
            senderDeviceId: sourceDevice,
            localDeviceId: 1,
            message: message,
            messageAgeSec: messageAgeSec
        )
    }

    public func receivedGroupCallUpdateMessage(
        _ update: SNProtoDataMessageGroupCallUpdate,
        for groupThread: TSGroupThread,
        serverReceivedTimestamp: UInt64) {

        Logger.info("Received group call update for thread \(groupThread.uniqueId!)")
        callService.groupCallMessageHandler.handleUpdateMessage(update, for: groupThread, serverReceivedTimestamp: serverReceivedTimestamp)
    }

    public func externallyHandleCallMessage(envelope: SNProtoEnvelope, plaintextData: Data, wasReceivedByUD: Bool, serverDeliveryTimestamp: UInt64, transaction: YapDatabaseReadWriteTransaction) -> Bool {
        return false
    }
}
