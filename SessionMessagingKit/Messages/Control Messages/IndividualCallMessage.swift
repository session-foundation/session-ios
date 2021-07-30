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
        if let offer = callMessage.offer {
            guard let opaque = offer.opaque else { return nil }
            callID = offer.id
            let callType = CallType.from(offer.type)
            kind = .offer(opaque: opaque, callType: callType)
        } else if let answer = callMessage.answer {
            guard let opaque = answer.opaque else { return nil }
            callID = answer.id
            kind = .answer(opaque: opaque)
        } else if !callMessage.iceUpdate.isEmpty {
            callID = callMessage.iceUpdate.first!.id // TODO: Is this how it's supposed to work?
            kind = .iceUpdate(candidates: callMessage.iceUpdate.compactMap { $0.opaque }) // Should never contain entries with a `nil` `opaque`
        } else if let hangup = callMessage.hangup {
            callID = hangup.id
            let type = HangupType.from(hangup.type)
            kind = .hangup(type: type)
        } else if let busy = callMessage.busy {
            callID = busy.id
            kind = .busy
        } else {
            return nil
        }
        return IndividualCallMessage(callID: callID, kind: kind)
    }

    public override func toProto(using transaction: YapDatabaseReadWriteTransaction) -> SNProtoContent? {
        return nil
    }

    // MARK: Description
    public override var description: String {
        """
        IndividualCallMessage(
            
        )
        """
    }
}
