// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public extension Dependencies {
    private func observe<T>(_ key: ObservableKey, defaultValue: T) async -> AsyncMapSequence<AsyncStream<Any?>, T> {
        return await self[singleton: .observationManager].observe(key).map { newValue in
            let newTypedValue: T? = (newValue as? T)
            
            if newValue != nil && newTypedValue == nil {
                Log.warn(.libSession, "Failed to cast new value for key \(key) to \(T.self), using default: \(defaultValue)")
            }
            
            return (newTypedValue ?? defaultValue)
        }
    }
    
    func observe(_ key: Setting.BoolKey) async -> AsyncMapSequence<AsyncStream<Any?>, Bool> {
        return await observe(.setting(key), defaultValue: false)
    }
    
    func observe<T: LibSessionConvertibleEnum>(_ key: Setting.EnumKey, defaultValue: T) async -> AsyncMapSequence<AsyncStream<Any?>, T> {
        return await observe(.setting(key), defaultValue: defaultValue)
    }
    
    func notifyAsync(_ key: ObservableKey) {
        Task(priority: .userInitiated) { [dependencies = self] in
            await dependencies[singleton: .observationManager].notify(key)
        }
    }
}
