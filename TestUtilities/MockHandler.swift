// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public final class MockHandler<T> {
    public let erasedDependencies: Any?
    
    private let lock = NSLock()
    private let dummyProvider: (any MockFunctionHandler) -> T
    private let failureReporter: TestFailureReporter
    private let forwardingHandler: (any MockFunctionHandler)?
    private var stubs: [RecordedCall.Key: [MockFunction]] = [:]
    private var calls: [RecordedCall.Key: [RecordedCall]] = [:]
    
    // MARK: - Initialization
    
    public init(
        dummyProvider: @escaping (any MockFunctionHandler) -> T,
        failureReporter: TestFailureReporter = NimbleFailureReporter(),
        using erasedDependencies: Any?
    ) {
        self.erasedDependencies = erasedDependencies
        self.dummyProvider = dummyProvider
        self.failureReporter = failureReporter
        self.forwardingHandler = nil
    }
    
    public init(forwardingHandler: any MockFunctionHandler) {
        self.erasedDependencies = nil
        self.dummyProvider = { _ in fatalError("A dummy instance cannot create other dummies.") }
        self.failureReporter = NimbleFailureReporter()
        self.forwardingHandler = forwardingHandler
    }

    
    public static func invalid() -> MockHandler<T> {
        return MockHandler(dummyProvider: { _ in fatalError("Should not call mock on a mock") }, using: nil)
    }
    
    // MARK: - Setup
    
    func createBuilder<R>(for callBlock: @escaping (inout T) async throws -> R) -> MockFunctionBuilder<T, R> {
        return MockFunctionBuilder(
            handler: self,
            callBlock: callBlock,
            dummyProvider: dummyProvider
        )
    }
    
    internal func register(stub: MockFunction) {
        let key: RecordedCall.Key = RecordedCall.Key(
            name: stub.name,
            generics: stub.generics,
            paramCount: stub.arguments.count
        )
        
        locked {
            stubs[key, default: []].append(stub)
        }
    }
    
    internal func removeStubs<R>(for functionBlock: @escaping (inout T) async throws -> R) async {
        guard let expectedCall: RecordedCall = await expectedCall(for: functionBlock) else { return }
        
        locked {
            stubs.removeValue(forKey: expectedCall.key)
        }
    }
    
    // MARK: - Verification
    
    func expectedCall<R>(for functionBlock: @escaping (inout T) async throws -> R) async -> RecordedCall? {
        let builder: MockFunctionBuilder<T, R> = createBuilder(for: functionBlock)
        
        guard let builtFunction = try? await builder.build() else {
            return nil
        }
        
        return RecordedCall(
            name: builtFunction.name,
            generics: builtFunction.generics,
            arguments: builtFunction.arguments
        )
    }
    
    func recordedCallInfo<R>(for functionBlock: @escaping (inout T) async throws -> R) async -> RecordedCallInfo? {
        let builder: MockFunctionBuilder<T, R> = createBuilder(for: functionBlock)
        
        guard let builtFunction = try? await builder.build() else {
            return nil
        }
        
        let expectedCall: RecordedCall = RecordedCall(
            name: builtFunction.name,
            generics: builtFunction.generics,
            arguments: builtFunction.arguments
        )
        let allCalls: [RecordedCall] = (locked { calls[expectedCall.key] } ?? [])
        
        return RecordedCallInfo(
            expectedCall: expectedCall,
            matchingCalls: allCalls.filter { expectedCall.matches(args: $0.arguments) },
            allCalls: allCalls
        )
    }
    
    // MARK: - Test Lifecycle
    
    public func clearCalls() {
        locked { calls.removeAll() }
    }
    
    public func reset() {
        locked {
            stubs.removeAll()
            calls.removeAll()
        }
    }
    
    // MARK: - Internal Logic
    
    @discardableResult private func locked<R>(_ operation: () -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
    
    private func findAndExecute<Output>(
        funcName: String,
        generics: [Any.Type],
        args: [Any?]
    ) -> Result<Output, Error> {
        typealias CallMatches = (
            matchingCall: MockFunction?,
            allCalls: [MockFunction]
        )
        let recordedCall: RecordedCall = RecordedCall(name: funcName, generics: generics, arguments: args)
        
        /// Get the `last` value as it was the one called most recently
        let maybeCallMatches: CallMatches? = locked {
            calls[recordedCall.key, default: []].append(recordedCall)
            
            return stubs[recordedCall.key].map { allStubs in
                (
                    allStubs.last(where: { $0.asCall.matches(args: args) }),
                    allStubs
                )
            }
        }
        
        guard let callMatches: CallMatches = maybeCallMatches else {
            return .failure(MockError.noStubFound(function: recordedCall.key.nameWithGenerics, args: args))
        }
        guard let matchingCall: MockFunction = callMatches.matchingCall else {
            return .failure(MockError.noMatchingStubFound(
                function: recordedCall.key.nameWithGenerics,
                expectedArgs: args,
                mockedArgs: callMatches.allCalls.map { $0.arguments }
            ))
        }
        
        /// Perform any actions
        for action in matchingCall.actions {
            action(args)
        }
        
        return execute(stub: matchingCall, args: args)
    }
    
    private func execute<Output>(stub: MockFunction, args: [Any?]) -> Result<Output, Error> {
        if let error: Error = stub.returnError {
            return .failure(error)
        }
        
        /// Handle `Void` returns first
        guard Output.self != Void.self else {
            return .success(() as! Output)
        }
        
        /// Try the `dynamicReturnValueRetriever` if there is one
        if let returnValue: Any = stub.dynamicReturnValueRetriever?(args), let typedValue: Output = returnValue as? Output {
            return .success(typedValue)
        }
        
        /// Then handle the proper typed return value
        if let returnValue: Any = stub.returnValue, let typedValue: Output = returnValue as? Output {
            return .success(typedValue)
        }
        
        return .failure(MockError.stubbedValueIsWrongType(
            function: stub.asCall.key.nameWithGenerics,
            expected: Output.self,
            actual: type(of: stub.returnValue)
        ))
    }
}

// MARK: - MockHandler.Key

private extension MockHandler {
    struct Key: Equatable, Hashable {
        let name: String
        let generics: [String]
        let paramCount: Int
        
        init(name: String, generics: [Any.Type], paramCount: Int) {
            self.name = name
            self.generics = generics.map { String(describing: $0) }
            self.paramCount = paramCount
        }
    }
}

// MARK: - Mock Functions

public extension MockHandler {
    func mock<Output>(
        funcName: String = #function,
        generics: [Any.Type] = [],
        args: [Any?] = [],
        fileID: String = #fileID,
        file: String = #file,
        line: UInt = #line
    ) -> Output {
        if let forwardedHandler: (any MockFunctionHandler) = forwardingHandler {
            return forwardedHandler.mock(funcName: funcName, generics: generics, args: args)
        }
        
        return handleNonThrowingResult(
            result: findAndExecute(
                funcName: funcName,
                generics: generics,
                args: args
            ),
            funcName: funcName,
            fileID: fileID,
            file: file,
            line: line
        )
    }
    
    func mockNoReturn(
        funcName: String = #function,
        generics: [Any.Type] = [],
        args: [Any?] = [],
        fileID: String = #fileID,
        file: String = #file,
        line: UInt = #line
    ) {
        let _: Void = mock(funcName: funcName, generics: generics, args: args, fileID: fileID, file: file, line: line)
    }
    
    func mockThrowing<Output>(
        funcName: String = #function,
        generics: [Any.Type] = [],
        args: [Any?] = [],
        fileID: String = #fileID,
        file: String = #file,
        line: UInt = #line
    ) throws -> Output {
        if let forwardedHandler: (any MockFunctionHandler) = forwardingHandler {
            return forwardedHandler.mock(funcName: funcName, generics: generics, args: args)
        }
        
        return try findAndExecute(
            funcName: funcName,
            generics: generics,
            args: args
        ).get()
    }
    
    func mockThrowingNoReturn(
        funcName: String = #function,
        generics: [Any.Type] = [],
        args: [Any?] = [],
        fileID: String = #fileID,
        file: String = #file,
        line: UInt = #line
    ) throws {
        let _: Void = try mockThrowing(funcName: funcName, generics: generics, args: args, fileID: fileID, file: file, line: line)
    }
    
    private func handleNonThrowingResult<Output>(
        result: Result<Output, Error>,
        funcName: String,
        fileID: String,
        file: String,
        line: UInt
    ) -> Output {
        switch result {
            case .success(let value): return value
            case .failure(let error):
                /// Log if the failure was due to a missing mock
                if (error as? MockError)?.shouldLogFailure == true {
                    failureReporter.reportFailure(
                        "\(error)",
                        fileID: fileID,
                        file: file,
                        line: line
                    )
                }
                
                /// Custom handle a `Void` return type before checking for Mocked conformance
                guard Output.self != Void.self else {
                    return () as! Output
                }
                
                if let fallbackValue: Output = MockFallbackRegistry.shared.makeFallback(for: Output.self) {
                    return fallbackValue
                }

                fatalError("FATAL: The return type '\(Output.self)' of the non-throwing function '\(funcName)' does not conform to 'Mocked' and has no custom fallback registered. The framework cannot produce a default value.")
            }
    }
}
