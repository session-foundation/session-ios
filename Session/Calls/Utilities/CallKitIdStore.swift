
// Mimics Signal's CallKitIdStore

enum CallKitIdStore {
    
    private static let callKitIDCollection = "CallKitIDCollection"
    
    static func setAddress(_ publicKey: String, forCallKitId callKitId: String) {
        Storage.write { transaction in
            transaction.setObject(publicKey, forKey: callKitId, inCollection: CallKitIdStore.callKitIDCollection)
        }
    }
}
