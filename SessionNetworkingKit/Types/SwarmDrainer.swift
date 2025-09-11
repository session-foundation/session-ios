// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public actor SwarmDrainer {
    public enum Strategy: Sendable {
        /// Select a new random node for each retry attempt
        case alwaysRandom
        
        /// Reuse the same node a number of times before picking a new one
        case limitedReuse(count: UInt)
    }
    
    /// The behaviour that should occur when attempting to retrieve the next snode after the swarm has been drained
    /// according to the `Stragegy`
    public enum AfterDrain: Sendable {
        case throwError
        case resetState
    }
    
    public struct LogDetails {
        let cat: Log.Category?
        let name: String?
        
        public init(cat: Log.Category?, name: String?) {
            self.cat = cat
            self.name = name
        }
        
        fileprivate func log(_ message: String) {
            switch cat {
                case .some(let cat): Log.info(cat, "\(name.map { "\($0) " } ?? "")\(message)")
                case .none: Log.info("\(name.map { "\($0) " } ?? "")\(message)")
            }
        }
    }
    
    private let dependencies: Dependencies
    private let strategy: Strategy
    private let nextRetrievalAfterDrain: AfterDrain
    private let logDetails: LogDetails?
    
    private var swarm: Set<LibSession.Snode>
    private var remainingSnodes: Set<LibSession.Snode>
    private var swarmHash: Int
    private var targetSnode: LibSession.Snode?
    private var targetUseCount: Int
    
    // MARK: - Initialization
    
    public init(
        swarm: Set<LibSession.Snode> = [],
        strategy: Strategy = .alwaysRandom,
        nextRetrievalAfterDrain: AfterDrain = .throwError,
        logDetails: LogDetails? = nil,
        using dependencies: Dependencies
    ) {
        self.dependencies = dependencies
        self.strategy = strategy
        self.nextRetrievalAfterDrain = nextRetrievalAfterDrain
        self.logDetails = logDetails
        
        self.swarm = swarm
        self.remainingSnodes = swarm
        self.swarmHash = swarm.hashValue
        self.targetSnode = nil
        self.targetUseCount = 0
    }
    
    // MARK: - Functions
    
    public func updateSwarmIfNeeded(_ swarm: Set<LibSession.Snode>) {
        guard swarmHash != swarm.hashValue else { return }
        
        self.swarm = swarm
        self.remainingSnodes = swarm
        self.swarmHash = swarm.hashValue
        self.targetSnode = nil
        self.targetUseCount = 0
    }
    
    public func selectNextNode() throws -> LibSession.Snode {
        /// If the swarm was changed then reset the state
        if self.swarmHash != swarm.hashValue {
            self.resetState()
        }
        
        /// If we have already drained the swarm then we need to behave as per the specified `nextRetrievalAfterDrain` behaviour
        if self.remainingSnodes.isEmpty {
            switch nextRetrievalAfterDrain {
                case .throwError: throw SnodeAPIError.ranOutOfRandomSnodes(nil)
                case .resetState:
                    logDetails?.log("drained the swarm, resetting state.")
                    self.resetState()
            }
        }
        
        switch self.strategy {
            case .alwaysRandom:
                /// Just pop a random element
                guard let snode: LibSession.Snode = dependencies.popRandomElement(&self.remainingSnodes) else {
                    throw SnodeAPIError.ranOutOfRandomSnodes(nil)
                }
                
                return snode
                
            case .limitedReuse(let maxUseCount):
                if let target: LibSession.Snode = self.targetSnode {
                    /// If we have more retries then just keep the same target
                    if self.targetUseCount < maxUseCount {
                        self.targetUseCount += 1
                        return target
                    }
                    
                    /// Otherwise log that we are switching
                    logDetails?.log("switching from \(target) to next snode.")
                }
                
                self.targetSnode = nil
                self.targetUseCount = 0
                
                /// Select the next node
                guard let newTarget: LibSession.Snode = dependencies.popRandomElement(&self.remainingSnodes) else {
                    throw SnodeAPIError.ranOutOfRandomSnodes(nil)
                }
                
                self.targetSnode = newTarget
                self.targetUseCount = 1
                
                return newTarget
        }
    }
    
    private func resetState() {
        self.remainingSnodes = swarm
        self.swarmHash = swarm.hashValue
        self.targetSnode = nil
        self.targetUseCount = 0
    }
}
