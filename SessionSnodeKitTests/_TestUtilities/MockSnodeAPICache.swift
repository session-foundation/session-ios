// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

import Foundation
import Combine
import SessionUtilitiesKit

@testable import SessionSnodeKit

class MockSnodeAPICache: Mock<SnodeAPICacheType>, SnodeAPICacheType {
    var hasLoadedSnodePool: Bool {
        get { return accept() as! Bool }
        set { accept(args: [newValue]) }
    }
    
    var loadedSwarms: Set<String> {
        get { return accept() as! Set<String> }
        set { accept(args: [newValue]) }
    }
    
    var getSnodePoolPublisher: AnyPublisher<Set<Snode>, Error>? {
        get { return accept() as? AnyPublisher<Set<Snode>, Error> }
        set { accept(args: [newValue]) }
    }
    
    var snodeFailureCount: [Snode: UInt] {
        get { return accept() as! [Snode: UInt] }
        set { accept(args: [newValue]) }
    }
    
    var snodePool: Set<Snode> {
        get { return accept() as! Set<Snode> }
        set { accept(args: [newValue]) }
    }
    
    var clockOffsetMs: Int64 {
        get { return accept() as! Int64 }
        set { accept(args: [newValue]) }
    }
    
    var swarmCache: [String: Set<Snode>] {
        get { return accept() as! [String: Set<Snode>] }
        set { accept(args: [newValue]) }
    }
    
    var hasInsufficientSnodes: Bool {
        get { return accept() as! Bool }
        set { accept(args: [newValue]) }
    }
}
