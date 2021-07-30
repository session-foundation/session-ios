import SessionUtilitiesKit

public final class IndividualCallMessage : ControlMessage {
    public var callID: UInt64?
    public var opaque: Data?
    public var kind: Kind?
    
//    let offerBuilder = SNProtoCallMessageOffer.builder(id: callId)
//    offerBuilder.setOpaque(opaque)
//    switch callMediaType {
//    case .audioCall: offerBuilder.setType(.offerAudioCall)
//    case .videoCall: offerBuilder.setType(.offerVideoCall)
//    }
//    let callMessage = OWSOutgoingCallMessage(thread: call.individualCall.thread, offerMessage: try offerBuilder.build(), destinationDeviceId: NSNumber(value: destinationDeviceId))
    
    // MARK: Call Type
    public enum CallType : CustomStringConvertible {
        case audio, video
        
        public var description: String {
            switch self {
            case .audio: return "audio"
            case .video: return "video"
            }
        }
    }
    
    // MARK: Kind
    public enum Kind : CustomStringConvertible {
        case offer(callType: CallType)
        case answer

        public var description: String {
            switch self {
            case .offer(let callType): return "offer(callType: \(callType))"
            case .answer: return "answer"
            }
        }
    }

    // MARK: Initialization
    public override init() { super.init() }

    internal init(callID: UInt64, opaque: Data, kind: Kind) {
        super.init()
        self.callID = callID
        self.opaque = opaque
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
        let opaqueOrNil: Data?
        let kind: Kind
        if let offer = callMessage.offer {
            callID = offer.id
            opaqueOrNil = offer.opaque
            let callType: CallType = (offer.type == .offerAudioCall) ? .audio : .video
            kind = .offer(callType: callType)
        } else if let answer = callMessage.answer {
            callID = answer.id
            opaqueOrNil = answer.opaque
            kind = .answer
        } else {
            return nil
        }
        guard let opaque = opaqueOrNil else { return nil }
        return IndividualCallMessage(callID: callID, opaque: opaque, kind: kind)
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
