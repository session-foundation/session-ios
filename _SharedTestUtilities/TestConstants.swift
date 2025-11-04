// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit

enum TestConstants {
    // Test keys (from here https://github.com/jagerman/session-pysogs/blob/docs/contrib/auth-example.py)
    static let publicKey: String = "88672ccb97f40bb57238989226cf429b575ba355443f47bc76c5ab144a96c65b"
    static let privateKey: String = "30d796c1ddb4dc455fd998a98aa275c247494a9a7bde9c1fee86ae45cd585241"
    static let edKeySeed: String = "c010d89eccbaf5d1c6d19df766c6eedf965d4a28a56f87c9fc819edb59896dd9"
    static let edPublicKey: String = "bac6e71efd7dfa4a83c98ed24f254ab2c267f9ccdb172a5280a0444ad24e89cc"
    static let edSecretKey: String = "c010d89eccbaf5d1c6d19df766c6eedf965d4a28a56f87c9fc819edb59896dd9bac6e71efd7dfa4a83c98ed24f254ab2c267f9ccdb172a5280a0444ad24e89cc"
    static let blind15PublicKey: String = "98932d4bccbe595a8789d7eb1629cefc483a0eaddc7e20e8fe5c771efafd9af5"
    static let blind15SecretKey: String = "16663322d6b684e1c9dcc02b9e8642c3affd3bc431a9ea9e63dbbac88ce7a305"
    static let blind25PublicKey: String = "c0a17a5594f3708414f61a76517ddb02a97d07e715c4225188977990fc6283f0"
    static let blind25SecretKey: String = "8c35261f847cb4a49e3699af92b14171f17e23c711a17ccc5d829bb611267e02"
    static let serverPublicKey: String = "c3b3c6f32f0ab5a57f853cc4f30f5da7fda5624b0c77b3fb0829de562ada081d"
    
    static let invalidImageData: Data = Data([1, 2, 3])
    static let validImageData: Data = {
        let size = CGSize(width: 1, height: 1)
        UIGraphicsBeginImageContext(size)
        defer { UIGraphicsEndImageContext() }
        
        UIColor.red.setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        
        let image: UIImage = UIGraphicsGetImageFromCurrentImageContext()!
        return image.jpegData(compressionQuality: 1.0)!
    }()
}

public enum TestError: Error, Equatable {
    case mock
    case timeout
    case unableToEvaluateExpression
}
