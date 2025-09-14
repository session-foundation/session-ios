// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

internal protocol Buildable {
    func build() async throws -> MockFunction
}

public class MockFunctionBuilder<T, R> {
    private let handler: MockHandler<T>
    private let callBlock: (inout T) async throws -> R
    private let dummyProvider: (any MockFunctionHandler) -> T
    
    private var capturedFunctionName: String?
    private var capturedGenerics: [Any.Type] = []
    private var capturedArguments: [Any?] = []
    
    private var returnValue: Any?
    private var dynamicReturnValueRetriever: (([Any?]) -> Any?)?
    private var returnError: Error?
    private var actions: [([Any?]) -> Void] = []
    
    public init(
        handler: MockHandler<T>,
        callBlock: @escaping (inout T) async throws -> R,
        dummyProvider: @escaping (any MockFunctionHandler) -> T
    ) {
        self.handler = handler
        self.callBlock = callBlock
        self.dummyProvider = dummyProvider
    }
    
    // MARK: - Mock Configuration API
    
    @discardableResult public func then(_ action: @escaping ([Any?]) -> Void) -> Self {
        self.actions.append({ args in action(args) })
        return self
    }
    
    public func thenReturn(_ value: R) async throws {
        self.returnValue = value
        try await finalize()
    }
    
    public func thenReturn(_ closure: @escaping ([Any?]) -> R) async throws {
        self.dynamicReturnValueRetriever = closure
        try await finalize()
    }
    
    public func thenThrow(_ error: Error) async throws {
        self.returnError = error
        try await finalize()
    }
    
    // MARK: - Internal Functions
    
    private func finalize() async throws {
        let function = try await self.build()
        handler.register(stub: function)
    }
    
    private func captureDetails() async {
        /// Only run capture once
        guard capturedFunctionName == nil else { return }
        
        var dummy: T = dummyProvider(self)
        _ = try? await callBlock(&dummy)
    }
}

extension MockFunctionBuilder: Buildable {
    func build() async throws -> MockFunction {
        await captureDetails()
        
        guard let name: String = capturedFunctionName else {
            throw MockError.invalidWhenBlock(message: "The when{...} block did not call a mockable function.")
        }
        
        return MockFunction(
            name: name,
            generics: capturedGenerics,
            arguments: capturedArguments,
            returnValue: returnValue,
            dynamicReturnValueRetriever: dynamicReturnValueRetriever,
            returnError: returnError,
            actions: actions
        )
    }
}

// MARK: - MockFunctionHandler

extension MockFunctionBuilder: MockFunctionHandler {
    public func mock<Output>(funcName: String, generics: [Any.Type], args: [Any?]) -> Output {
        self.capturedFunctionName = funcName
        self.capturedGenerics = generics
        self.capturedArguments = args
        
        return MockHelper.unsafePlaceholder()
    }
}

private protocol _OptionalProtocol {}
extension Optional: _OptionalProtocol {}
