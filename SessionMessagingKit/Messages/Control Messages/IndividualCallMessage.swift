import SessionUtilitiesKit

public final class IndividualCallMessage : ControlMessage {
    public var callID: UInt64?
    public var kind: Kind?
    
    // MARK: Call Type
    public enum CallType : String {
        case audio, video
        
        fileprivate static func from(_ proto: SNProtoCallMessageOffer.SNProtoCallMessageOfferType) -> CallType {
            switch proto {
            case .offerAudioCall: return .audio
            case .offerVideoCall: return .video
            }
        }
    }
    
    // MARK: Hangup Type
    public enum HangupType : String {
        case normal, accepted, declined, busy, needPermission
        
        fileprivate static func from(_ proto: SNProtoCallMessageHangup.SNProtoCallMessageHangupType) -> HangupType {
            switch proto {
            case .hangupNormal: return .normal
            case .hangupAccepted: return .accepted
            case .hangupDeclined: return .declined
            case .hangupBusy: return .busy
            case .hangupNeedPermission: return .needPermission
            }
        }
    }
    
    // MARK: Kind
    public enum Kind : CustomStringConvertible {
        case offer(opaque: Data, callType: CallType)
        case answer(opaque: Data)
        case iceUpdate(candidates: [Data])
        case hangup(type: HangupType)
        case busy

        public var description: String {
            switch self {
            case .offer(let opaque, let callType): return "offer(opaque: \(opaque.count) bytes, callType: \(callType.rawValue))"
            case .answer(let opaque): return "answer(opaque: \(opaque.count) bytes)"
            case .iceUpdate(let candidates): return "iceUpdate(candidates: \(candidates.count) candidates)"
            case .hangup(let type): return "hangup(type: \(type.rawValue)"
            case .busy: return "busy"
            }
        }
    }

    // MARK: Initialization
    public override init() { super.init() }

    internal init(callID: UInt64, kind: Kind) {
        super.init()
        self.callID = callID
        self.kind = kind
    }

    // MARK: Validation
    public override var isValid: Bool {
        guard super.isValid else { return false }
        return true
    }

    // MARK: Coding
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    public override func encode(with coder: NSCoder) {
        super.encode(with: coder)
    }

    // MARK: Proto Conversion
    public override class func fromProto(_ proto: SNProtoContent) -> IndividualCallMessage? {
        guard let callMessage = proto.callMessage else { return nil }
        let callID: UInt64
        let kind: Kind
        // Offer
        if let offer = callMessage.offer {
            guard let opaque = offer.opaque else { return nil }
            callID = offer.id
            let callType = CallType.from(offer.type)
            kind = .offer(opaque: opaque, callType: callType)
        }
        // Answer
        else if let answer = callMessage.answer {
            guard let opaque = answer.opaque else { return nil }
            callID = answer.id
            kind = .answer(opaque: opaque)
        }
        // ICE Update
        else if !callMessage.iceUpdate.isEmpty {
            callID = callMessage.iceUpdate.first!.id // TODO: Is this how it's supposed to work?
            kind = .iceUpdate(candidates: callMessage.iceUpdate.compactMap { $0.opaque }) // Should never contain entries with a `nil` `opaque`
        }
        // Hangup
        else if let hangup = callMessage.hangup {
            callID = hangup.id
            let type = HangupType.from(hangup.type)
            kind = .hangup(type: type)
        }
        // Busy
        else if let busy = callMessage.busy {
            callID = busy.id
            kind = .busy
        }
        // Unknown
        else {
            return nil
        }
        return IndividualCallMessage(callID: callID, kind: kind)
    }

    public override func toProto(using transaction: YapDatabaseReadWriteTransaction) -> SNProtoContent? {
        guard let callID = callID, let kind = kind else {
            SNLog("Couldn't construct individual call message proto from: \(self).")
            return nil
        }
        let callMessageProto = SNProtoCallMessage.builder()
        switch kind {
        case let .offer(opaque, callType):
            let offerMessageProto = SNProtoCallMessageOffer.builder(id: callID)
            offerMessageProto.setOpaque(opaque)
            offerMessageProto.setType(SNProtoCallMessageOffer.SNProtoCallMessageOfferType.from(callType))
            do {
                callMessageProto.setOffer(try offerMessageProto.build())
            } catch {
                SNLog("Couldn't construct offer message proto from: \(self).")
                return nil
            }
        case let .answer(opaque):
            let answerMessageProto = SNProtoCallMessageAnswer.builder(id: callID)
            answerMessageProto.setOpaque(opaque)
            do {
                callMessageProto.setAnswer(try answerMessageProto.build())
            } catch {
                SNLog("Couldn't construct answer message proto from: \(self).")
                return nil
            }
        case let .iceUpdate(candidates):
            let iceUpdateMessageProtos = candidates.map { candidate -> SNProtoCallMessageIceUpdate.SNProtoCallMessageIceUpdateBuilder in
                let iceUpdateMessageProto = SNProtoCallMessageIceUpdate.builder(id: callID)
                iceUpdateMessageProto.setOpaque(candidate)
                return iceUpdateMessageProto
            }
            do {
                callMessageProto.setIceUpdate(try iceUpdateMessageProtos.map { try $0.build() })
            } catch {
                SNLog("Couldn't construct ICE update message proto from: \(self).")
                return nil
            }
        case let .hangup(type):
            let hangupMessageProto = SNProtoCallMessageHangup.builder(id: callID)
            hangupMessageProto.setType(SNProtoCallMessageHangup.SNProtoCallMessageHangupType.from(type))
            do {
                callMessageProto.setHangup(try hangupMessageProto.build())
            } catch {
                SNLog("Couldn't construct hangup message proto from: \(self).")
                return nil
            }
        case .busy:
            let busyMessageProto = SNProtoCallMessageBusy.builder(id: callID)
            do {
                callMessageProto.setBusy(try busyMessageProto.build())
            } catch {
                SNLog("Couldn't construct busy message proto from: \(self).")
                return nil
            }
        }
        return nil
    }

    // MARK: Description
    public override var description: String {
        """
        IndividualCallMessage(
            callID: \(callID?.description ?? "null"),
            kind: \(kind?.description ?? "null")
        )
        """
    }
}

// MARK: Convenience
extension SNProtoCallMessageOffer.SNProtoCallMessageOfferType {
    
    fileprivate static func from(_ callType: IndividualCallMessage.CallType) -> SNProtoCallMessageOffer.SNProtoCallMessageOfferType {
        switch callType {
        case .audio: return .offerAudioCall
        case .video: return .offerVideoCall
        }
    }
}

extension SNProtoCallMessageHangup.SNProtoCallMessageHangupType {
    
    fileprivate static func from(_ hangupType: IndividualCallMessage.HangupType) -> SNProtoCallMessageHangup.SNProtoCallMessageHangupType {
        switch hangupType {
        case .normal: return .hangupNormal
        case .accepted: return .hangupAccepted
        case .declined: return .hangupDeclined
        case .busy: return .hangupBusy
        case .needPermission: return .hangupNeedPermission
        }
    }
}
