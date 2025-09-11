// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension Result where Failure == Error {
    init(_ closure: @autoclosure () throws -> Success) {
        do { self = Result.success(try closure()) }
        catch { self = Result.failure(error) }
    }
    
    func onFailure(closure: (Failure) -> ()) -> Result<Success, Failure> {
        switch self {
            case .success: break
            case .failure(let failure): closure(failure)
        }
        
        return self
    }
}
