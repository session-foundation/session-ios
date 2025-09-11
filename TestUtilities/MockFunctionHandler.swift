// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public protocol MockFunctionHandler {
    @discardableResult
    func mock<Output>(funcName: String, generics: [Any.Type], args: [Any?]) -> Output
}
