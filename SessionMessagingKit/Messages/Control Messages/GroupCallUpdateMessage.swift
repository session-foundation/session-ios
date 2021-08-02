import SessionUtilitiesKit

public final class GroupCallUpdateMessage : ControlMessage {
    public var eraID: String?

    // MARK: Initialization
    public override init() { super.init() }

    internal init(eraID: String) {
        super.init()
        self.eraID = eraID
    }

    // MARK: Validation
    public override var isValid: Bool {
        guard super.isValid else { return false }
        return eraID != nil
    }

    // MARK: Coding
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        guard let eraID = coder.decodeObject(forKey: "eraID") as? String else { return nil }
        self.eraID = eraID
    }

    public override func encode(with coder: NSCoder) {
        super.encode(with: coder)
        guard let eraID = eraID else { return }
        coder.encode(eraID, forKey: "eraID")
    }

    // MARK: Proto Conversion
    public override class func fromProto(_ proto: SNProtoContent) -> GroupCallUpdateMessage? {
        guard let groupCallUpdate = proto.dataMessage?.groupCallUpdate,
            let eraID = groupCallUpdate.eraID else { return nil }
        return GroupCallUpdateMessage(eraID: eraID)
    }

    public override func toProto(using transaction: YapDatabaseReadWriteTransaction) -> SNProtoContent? {
        guard let eraID = eraID else {
            SNLog("Couldn't construct group call update message proto from: \(self).")
            return nil
        }
        let groupCallUpdateProto = SNProtoDataMessageGroupCallUpdate.builder()
        groupCallUpdateProto.setEraID(eraID)
        do {
            let dataMessageProto = SNProtoDataMessage.builder()
            dataMessageProto.setGroupCallUpdate(try groupCallUpdateProto.build())
            let contentProto = SNProtoContent.builder()
            contentProto.setDataMessage(try dataMessageProto.build())
            return try contentProto.build()
        } catch {
            SNLog("Couldn't construct group call update message proto from: \(self).")
            return nil
        }
    }

    // MARK: Description
    public override var description: String {
        """
        GroupCallUpdateMessage(
            eraID: \(eraID ?? "null")
        )
        """
    }
}
