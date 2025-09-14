// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import UIKit.UIApplication

// MARK: - Mocked

public protocol Mocked {
    static var any: Self { get }
    static var mock: Self { get }
    
    static var skipTypeMatchForAnyComparison: Bool { get }
}

public extension Mocked {
    static var skipTypeMatchForAnyComparison: Bool { false }
}

public enum MockHelper {
    /// This function is a hack to force Swift to think it has received a value, if we try to use the value it will crash but becasue this is only
    /// ever used for constructing stub calls (as opposed to calling mocked functions) the result will never be used so won't crash
    internal static func unsafePlaceholder<V>() -> V {
        let pointer = UnsafeMutablePointer<V>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        return pointer.move()
    }
    
    /// This function is similar to the above but can be used for `Bool` to generate an "invalid" value for the `any` case, using the value
    /// returned by this function outside of constructing stub calls will result in undefined behaviour or crashes
    ///
    /// This doesn't cause a crash because Swift essentially doesn't check that the underlying data matches (whereas for primitive-backed
    /// enum values it does, and structs must have the right memory size and alignment so we can't use this approach for them)
    public static func unsafeBoolValue() -> Bool {
        var rawValueToLoad: UInt8 = .any
        
        return withUnsafeBytes(of: &rawValueToLoad) {
            $0.load(as: Bool.self)
        }
    }
}

// MARK: - DSL

public func anyAny() -> Any { AnyValue.any }

/// This type is here to allow us to have some ability to match something passed to a function expecting an `Any` against a `.any` value,
/// since we can't extend `Any` this type will be returned by `anyAny` and will match regardless of what the parameter type is
public final class AnyValue: Mocked {
    public static var any: AnyValue { AnyValue(id: .any) }
    public static var mock: AnyValue { AnyValue(id: .mock) }
    public static var skipTypeMatchForAnyComparison: Bool { true }
    
    private let id: UUID
    private init(id: UUID) {
        self.id = id
    }
}

extension Optional: Mocked where Wrapped: Mocked {
    public static var any: Self { Wrapped.any }
    public static var mock: Self { Wrapped.mock }
}

extension Int: Mocked {
    public static let any: Int = (Int.max - 123)
    public static let mock: Int = 0
}
extension UInt: Mocked {
    public static let any: UInt = (UInt.max - 123)
    public static let mock: UInt = 0
}
extension Int8: Mocked {
    public static let any: Int8 = (Int8.max - 123)
    public static let mock: Int8 = 0
}
extension UInt8: Mocked {
    public static let any: UInt8 = (UInt8.max - 123)
    public static let mock: UInt8 = 0
}
extension Int16: Mocked {
    public static let any: Int16 = (Int16.max - 123)
    public static let mock: Int16 = 0
}
extension UInt16: Mocked {
    public static let any: UInt16 = (UInt16.max - 123)
    public static let mock: UInt16 = 0
}
extension Int32: Mocked {
    public static let any: Int32 = (Int32.max - 123)
    public static let mock: Int32 = 0
}
extension UInt32: Mocked {
    public static let any: UInt32 = (UInt32.max - 123)
    public static let mock: UInt32 = 0
}
extension Int64: Mocked {
    public static let any: Int64 = (Int64.max - 123)
    public static let mock: Int64 = 0
}
extension UInt64: Mocked {
    public static let any: UInt64 = (UInt64.max - 123)
    public static let mock: UInt64 = 0
}
extension Float: Mocked {
    public static let any: Float = (Float.greatestFiniteMagnitude - 123)
    public static let mock: Float = 0
}
extension Double: Mocked {
    public static let any: Double = (Double.greatestFiniteMagnitude - 123)
    public static let mock: Double = 0
}
extension String: Mocked {
    public static let any: String = "__MOCKED_ANY_VALUE__"
    public static let mock: String = ""
}
extension Data: Mocked {
    public static let any: Data = Data([1, 1, 1, 200, 200, 200, 1, 1, 1])
    public static let mock: Data = Data()
}
extension Bool: Mocked {
    public static let any: Bool = MockHelper.unsafeBoolValue()
    public static let mock: Bool = false
}

extension Dictionary: Mocked {
    public static var any: Self {
        if let mockedKeyType = Key.self as? any (Mocked & Hashable).Type, let mockedValueType = Value.self as? any Mocked.Type {
            let anyKey = mockedKeyType.any
            let anyValue = mockedValueType.any
            
            guard let hashableKey = anyKey as? AnyHashable else {
                return [:]
            }

            return [hashableKey: anyValue] as! Self
        }
        
        /// Try to handle generic dictionaries
        if Key.self == AnyHashable.self && (Value.self == AnyHashable.self || Value.self == Any.self) {
            return [String.any: String.any] as! Self
        }
        
        return [:]
    }
    public static var mock: Self { [:] }
}
extension Array: Mocked {
    public static var any: Self {
        if let mockedType = Element.self as? any Mocked.Type {
            return [mockedType.any] as! Self
        }
        
        return []
    }
    public static var mock: Self { [] }
}
extension Set: Mocked {
    public static var any: Self {
        if let mockedType = Element.self as? any Mocked.Type {
            return [mockedType.any] as! Self
        }
        
        return []
    }
    public static var mock: Self { [] }
}

extension UIApplication.State: Mocked {
    public static let any: UIApplication.State = .inactive
    public static let mock: UIApplication.State = .active
}

private final class MockPointerHolder {
    static let anyObjCBoolPointer: UnsafeMutablePointer<ObjCBool> = {
        let pointer = UnsafeMutablePointer<ObjCBool>.allocate(capacity: 1)
        pointer.initialize(to: ObjCBool(false))
        return pointer
    }()
    static let mockObjCBoolPointer: UnsafeMutablePointer<ObjCBool> = {
        let pointer = UnsafeMutablePointer<ObjCBool>.allocate(capacity: 1)
        pointer.initialize(to: ObjCBool(false))
        return pointer
    }()
}

extension UnsafeMutablePointer: Mocked where Pointee == ObjCBool {
    public static var any: UnsafeMutablePointer<ObjCBool> {
        return MockPointerHolder.anyObjCBoolPointer
    }
    
    public static var mock: UnsafeMutablePointer<ObjCBool> {
        return MockPointerHolder.mockObjCBoolPointer
    }
}


extension UUID: Mocked {
    public static let any: UUID = UUID(uuidString: "12300099-0099-0000-0000-990099000321")!
    public static let mock: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
}

extension URL: Mocked {
    public static let any: URL = URL(fileURLWithPath: "__MOCKED_ANY_VALUE__")
    public static let mock: URL = URL(fileURLWithPath: "mock")
}

extension URLRequest: Mocked {
    public static let any: URLRequest = URLRequest(url: URL(fileURLWithPath: "__MOCKED_ANY_VALUE__"))
    public static let mock: URLRequest = URLRequest(url: URL(fileURLWithPath: "mock"))
}

extension AnyPublisher: Mocked where Failure == Error {
    public static var any: AnyPublisher<Output, Error> { Fail(error: MockError.any).eraseToAnyPublisher() }
    public static var mock: AnyPublisher<Output, Error> { Fail(error: MockError.mock).eraseToAnyPublisher() }
}

extension AsyncStream: Mocked {
    public static var any: AsyncStream<Element> { AsyncStream { $0.finish() } }
    public static var mock: AsyncStream<Element> { AsyncStream { $0.finish() } }
}

extension FileManager.ItemReplacementOptions: Mocked {
    public static let any: FileManager.ItemReplacementOptions = FileManager.ItemReplacementOptions(rawValue: .any)
    public static let mock: FileManager.ItemReplacementOptions = FileManager.ItemReplacementOptions()
}

extension FileProtectionType: Mocked {
    public static let any: FileProtectionType = FileProtectionType(rawValue: .any)
    public static let mock: FileProtectionType = .complete
}

extension Data.WritingOptions: Mocked {
    public static let any: Data.WritingOptions = Data.WritingOptions(rawValue: .any)
    public static let mock: Data.WritingOptions = .atomic
}
