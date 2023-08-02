// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension JSONEncoder {
    func with(outputFormatting: JSONEncoder.OutputFormatting) -> JSONEncoder {
        let result: JSONEncoder = self
        result.outputFormatting = outputFormatting
        
        return result
    }
}
