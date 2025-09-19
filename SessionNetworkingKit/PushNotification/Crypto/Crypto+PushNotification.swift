// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtil
import SessionUtilitiesKit

public extension Crypto.Generator {
    static func plaintextWithPushNotificationPayload(
        payload: Data,
        encKey: Data
    ) -> Crypto.Generator<Data> {
        return Crypto.Generator(
            id: "plaintextWithPushNotificationPayload",
            args: [payload, encKey]
        ) {
            var cPayload: [UInt8] = Array(payload)
            var cEncKey: [UInt8] = Array(encKey)
            var maybePlaintext: UnsafeMutablePointer<UInt8>? = nil
            var plaintextLen: Int = 0

            guard
                cEncKey.count == 32,
                session_decrypt_push_notification(
                    &cPayload,
                    cPayload.count,
                    &cEncKey,
                    &maybePlaintext,
                    &plaintextLen
                ),
                plaintextLen > 0,
                let plaintext: Data = maybePlaintext.map({ Data(bytes: $0, count: plaintextLen) })
            else { throw CryptoError.decryptionFailed }

            free(UnsafeMutableRawPointer(mutating: maybePlaintext))

            return plaintext
        }
    }
}
