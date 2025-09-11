// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import TestUtilities

@testable import SessionUtilitiesKit

extension SessionId: @retroactive Mocked {
    public static let any: SessionId = SessionId(.standard, publicKey: [255, 255, 255, 255, 255])
    public static let mock: SessionId = SessionId(.standard, publicKey: [
        1, 2, 3, 4, 5, 6, 7, 8, 1, 2, 3, 4, 5, 6, 7, 8,
        1, 2, 3, 4, 5, 6, 7, 8, 1, 2, 3, 4, 5, 6, 7, 8
    ])
}

extension Dependencies {
    static var any: Dependencies {
        TestDependencies { dependencies in
            dependencies.dateNow = Date(timeIntervalSince1970: 1234567890)
            dependencies.forceSynchronous = true
        }
    }
}

extension ObservingDatabase: @retroactive Mocked {
    public static var any: Self {
        var result: Database!
        try! DatabaseQueue().read { result = $0 }
        return ObservingDatabase.create(result!, id: .any, using: .any) as! Self
    }
    public static var mock: Self {
        var result: Database!
        try! DatabaseQueue().read { result = $0 }
        return ObservingDatabase.create(result!, id: .mock, using: .any) as! Self
    }
}

extension ObservableKey: @retroactive Mocked {
    public static var any: ObservableKey = "__MOCKED_ANY_KEY_VALUE__"
    public static var mock: ObservableKey = "mockObservableKey"
}

extension ObservedEvent: @retroactive Mocked {
    public static var any: ObservedEvent { return ObservedEvent(key: "__MOCKED_ANY_KEY_VALUE__", value: nil) }
    public static var mock: ObservedEvent = ObservedEvent(key: "mock", value: nil)
}

extension KeyPair: @retroactive Mocked {
    public static var any: KeyPair = KeyPair(publicKey: Array(Data.any), secretKey: Array(Data.any))
    public static var mock: KeyPair = KeyPair(
        publicKey: Data(hex: TestConstants.publicKey).bytes,
        secretKey: Data(hex: TestConstants.edSecretKey).bytes
    )
}

extension Job: @retroactive Mocked {
    public static var any: Job = Job(variant: .any)
    public static var mock: Job = Job(variant: .mock)
}

extension Job.Variant: @retroactive Mocked {
    public static var any: Job.Variant = ._legacy_notifyPushServer
    public static var mock: Job.Variant = .messageSend
}

extension JobRunner.JobResult: @retroactive Mocked {
    public static var any: JobRunner.JobResult = .failed(MockError.any, false)
    public static var mock: JobRunner.JobResult = .succeeded
}

extension Log.Category: @retroactive Mocked {
    public static var any: Log.Category = .create(.any, defaultLevel: .debug)
    public static var mock: Log.Category = .create("mock", defaultLevel: .debug)
}

extension Setting.BoolKey: @retroactive Mocked {
    public static var any: Setting.BoolKey = "__MOCKED_ANY_BOOL_KEY_VALUE__"
    public static var mock: Setting.BoolKey = "mockBool"
}

extension Setting.EnumKey: @retroactive Mocked {
    public static var any: Setting.EnumKey = "__MOCKED_ANY_ENUM_KEY_VALUE__"
    public static var mock: Setting.EnumKey = "mockEnum"
}

// MARK: - Encodable Convenience

extension Mocked where Self: Encodable {
    func encoded(using dependencies: Dependencies) -> Data {
        try! JSONEncoder(using: dependencies).with(outputFormatting: .sortedKeys).encode(self)
    }
}

extension MockedGeneric where Self: Encodable {
    func encoded(using dependencies: Dependencies) -> Data {
        try! JSONEncoder(using: dependencies).with(outputFormatting: .sortedKeys).encode(self)
    }
}

extension Array where Element: Encodable {
    func encoded(using dependencies: Dependencies) -> Data {
        try! JSONEncoder(using: dependencies).with(outputFormatting: .sortedKeys).encode(self)
    }
}
