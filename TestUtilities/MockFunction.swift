// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

internal final class MockFunction {
    let name: String
    let generics: [Any.Type]
    let arguments: [Any?]
    let returnValue: Any?
    let dynamicReturnValueRetriever: (([Any?]) -> Any?)?
    let returnError: (any Error)?
    let actions: [([Any?]) -> Void]
    
    var asCall: RecordedCall { RecordedCall(name: name, generics: generics, arguments: arguments) }
    
    init(
        name: String,
        generics: [Any.Type],
        arguments: [Any?],
        returnValue: Any?,
        dynamicReturnValueRetriever: (([Any?]) -> Any?)?,
        returnError: Error?,
        actions: [([Any?]) -> Void]
    ) {
        self.name = name
        self.generics = generics
        self.arguments = arguments
        self.returnValue = returnValue
        self.dynamicReturnValueRetriever = dynamicReturnValueRetriever
        self.returnError = returnError
        self.actions = actions
    }
}
