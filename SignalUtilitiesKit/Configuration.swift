// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUIKit
import SessionSnodeKit
import SessionMessagingKit
import SessionUtilitiesKit

public enum Configuration {
    public static func performMainSetup() {
        // Need to do this first to ensure the legacy database exists
        SNUtilitiesKit.configure(maxFileSize: UInt(FileServerAPI.maxFileSize))
        SNMessagingKit.configure()
        SNSnodeKit.configure()
        SNUIKit.configure()
        let secKey = Identity.fetchUserEd25519KeyPair()?.secretKey
        
        SnodeAPI.otherReuquestCallback = { snode, payload in
            SessionUtil.sendRequest(
                ed25519SecretKey: secKey,
                targetPubkey: snode.x25519PublicKey,
                targetIp: snode.ip,
                targetPort: snode.port,
                endpoint: "/storage_rpc/v1",
                payload: payload
            ) { success, statusCode, data in
                print("RAWR")
            }
        }
    }
}
