// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public final class MockHandler<T> {
    private let lock = NSLock()
    private let dummyProvider: (any MockFunctionHandler) -> T
    private let failureReporter: TestFailureReporter
    private let forwardingHandler: (any MockFunctionHandler)?
    private var stubs: [Key: [MockFunction]] = [:]
    private var calls: [Key: [RecordedCall]] = [:]
    
    // MARK: - Initialization
    
    public init(
        dummyProvider: @escaping (any MockFunctionHandler) -> T,
        failureReporter: TestFailureReporter = NimbleFailureReporter()
    ) {
        self.dummyProvider = dummyProvider
        self.failureReporter = failureReporter
        self.forwardingHandler = nil
    }
    
    public init(forwardingHandler: any MockFunctionHandler) {
        self.dummyProvider = { _ in fatalError("A dummy instance cannot create other dummies.") }
        self.failureReporter = NimbleFailureReporter()
        self.forwardingHandler = forwardingHandler
    }

    
    public static func invalid() -> MockHandler<T> {
        return MockHandler(dummyProvider: { _ in fatalError("Should not call mock on a mock") } )
    }
    
    // MARK: - Setup
    
    func createBuilder<R>(for callBlock: @escaping (T) async throws -> R) -> MockFunctionBuilder<T, R> {
        return MockFunctionBuilder(
            handler: self,
            callBlock: callBlock,
            dummyProvider: dummyProvider
        )
    }
    
    internal func register(stub: MockFunction) {
        let key: Key = Key(name: stub.name, generics: stub.generics, paramCount: stub.arguments.count)
        
        locked {
            stubs[key, default: []].append(stub)
        }
    }
    
    internal func removeStubs<R>(for functionBlock: @escaping (T) async throws -> R) async {
        let builder: MockFunctionBuilder<T, R> = createBuilder(for: functionBlock)
        
        guard let builtFunction: MockFunction = try? await builder.build() else { return }
        
        let key: Key = Key(
            name: builtFunction.name,
            generics: builtFunction.generics,
            paramCount: builtFunction.arguments.count
        )
        
        locked {
            stubs.removeValue(forKey: key)
        }
    }
    
    // MARK: - Verification
    
    func recordedCalls<R>(for functionBlock: @escaping (T) async throws -> R) async -> [RecordedCall]? {
        let builder: MockFunctionBuilder<T, R> = createBuilder(for: functionBlock)
        
        guard let builtFunction = try? await builder.build() else {
            return nil
        }
        
        let key: Key = Key(
            name: builtFunction.name,
            generics: builtFunction.generics,
            paramCount: builtFunction.arguments.count
        )
        
        guard let callsForKey: [RecordedCall] = locked({ calls[key] }) else { return [] }
        
        return callsForKey.filter { builtFunction.matches(args: $0.args) }
    }
    
    func allRecordedCalls<R>(for functionBlock: @escaping (T) async throws -> R) async -> [RecordedCall]? {
        let builder: MockFunctionBuilder<T, R> = createBuilder(for: functionBlock)
        
        guard let builtFunction = try? await builder.build() else {
            return nil
        }
        
        let key: Key = Key(
            name: builtFunction.name,
            generics: builtFunction.generics,
            paramCount: builtFunction.arguments.count
        )
        
        return locked {
            calls[key]
        }
    }
    
    // MARK: - Test Lifecycle
    
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
        args: [Any?],
        fileID: String,
        file: String,
        line: UInt
    ) -> Result<Output, Error> {
        let key: Key = Key(name: funcName, generics: generics, paramCount: args.count)
        let recordedCall: RecordedCall = RecordedCall(name: funcName, args: args)
        
        /// Get the `last` value as it was the one called most recently
        let maybeMatchingCall: MockFunction? = locked {
            calls[key, default: []].append(recordedCall)
            
            return stubs[key]?.last(where: { $0.matches(args: args) })
        }
        
        guard let matchingCall: MockFunction = maybeMatchingCall else {
            return .failure(MockError.noStubFound(function: funcName, args: args))
        }
        
        /// Perform any actions
        for action in matchingCall.actions {
            action(args)
        }
        
        return execute(stub: matchingCall)
    }
    
    private func execute<Output>(stub: MockFunction) -> Result<Output, Error> {
        if let error: Error = stub.returnError {
            return .failure(error)
        }
        
        /// Handle `Void` returns first
        guard Output.self != Void.self else {
            return .success(() as! Output)
        }
        
        /// Then handle the proper typed return value
        if let returnValue: Any = stub.returnValue, let typedValue: Output = returnValue as? Output {
            return .success(typedValue)
        }
        
        return .failure(MockError.stubbedValueIsWrongType(
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
        
        return handlingNonThrowingResult(
            result: findAndExecute(
                funcName: funcName,
                generics: generics,
                args: args,
                fileID: fileID,
                file: file,
                line: line
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
            args: args,
            fileID: fileID,
            file: file,
            line: line
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
    
    private func handlingNonThrowingResult<Output>(
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
                if case MockError.noStubFound(_, _) = error {
                    failureReporter.reportFailure(
                        "Mocking Error: An unstubbed function was called: `\(funcName)`",
                        fileID: fileID,
                        file: file,
                        line: line
                    )
                }
                
                /// Custom handle a `Void` return type before checking for Mocked conformance
                guard Output.self != Void.self else {
                    return () as! Output
                }
                
                guard let mockedType = Output.self as? Mocked.Type else {
                    fatalError("FATAL: The return type '\(Output.self)' of the non-throwing function '\(funcName)' does not conform to 'Mocked'. This conformance is required to provide a fallback value when a test fails due to a missing stub.")
                }
                
                return mockedType.mock as! Output
            }
    }
}
