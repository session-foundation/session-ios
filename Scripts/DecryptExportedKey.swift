// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import CryptoKit

let arguments = CommandLine.arguments

// First argument is the file name
if arguments.count == 3 {
    let encryptedData = Data(base64Encoded: arguments[1].data(using: .utf8)!)!
    let hash: SHA256.Digest = SHA256.hash(data: arguments[2].data(using: .utf8)!)
    let key: SymmetricKey = SymmetricKey(data: Data(hash.makeIterator()))
    let sealedBox = try! ChaChaPoly.SealedBox(combined: encryptedData)
    let decryptedData = try! ChaChaPoly.open(sealedBox, using: key)

    print(Array(decryptedData).map { String(format: "%02x", $0) }.joined())
}
else {
    print("Please provide the base64 encoded 'encrypted key' and plain text 'password' as arguments")
}
