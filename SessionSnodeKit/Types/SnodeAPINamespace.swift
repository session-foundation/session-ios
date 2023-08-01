// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension SnodeAPI {
    enum Namespace: Int, Codable, Hashable {
        case `default` = 0
        
        case configUserProfile = 2
        case configContacts = 3
        case configConvoInfoVolatile = 4
        case configUserGroups = 5
        case configClosedGroupInfo = 11
        
        case legacyClosedGroup = -10
        
        case all = -9999990
        
        // MARK: Variables
        
        var requiresReadAuthentication: Bool {
            switch self {
                // Legacy closed groups don't support authenticated retrieval
                case .legacyClosedGroup: return false
                default: return true
            }
        }
        
        var requiresWriteAuthentication: Bool {
            switch self {
                // Legacy closed groups don't support authenticated storage
                case .legacyClosedGroup: return false
                default: return true
            }
        }
        
        /// This flag indicates whether we should provide a `lastHash` when retrieving messages from the specified
        /// namespace, when `true` we will only receive messages added since the provided `lastHash`, otherwise
        /// we will retrieve **all** messages from the namespace
        public var shouldFetchSinceLastHash: Bool { true }
        
        /// This flag indicates whether we should dedupe messages from the specified namespace, when `true` we will
        /// store a `SnodeReceivedMessageInfo` record for the message and check for a matching record whenever
        /// we receive a message from this namespace
        ///
        /// **Note:** An additional side-effect of this flag is that when we poll for messages from the specified namespace
        /// we will always retrieve **all** messages from the namespace (instead of just new messages since the last one
        /// we have seen)
        public var shouldDedupeMessages: Bool {
            switch self {
                case .`default`, .legacyClosedGroup: return true
                    
                case .configUserProfile, .configContacts,
                    .configConvoInfoVolatile, .configUserGroups,
                    .configClosedGroupInfo, .all:
                    return false
            }
        }
        
        var verificationString: String {
            switch self {
                case .`default`: return ""
                case .all: return "all"
                default: return "\(self.rawValue)"
            }
        }
        
        /// When performing a batch request we want to try to use the amount of data available in the response as effectively as possible
        /// this priority allows us to split the response effectively between the number of namespaces we are requesting from where
        /// namespaces with the same priority will be given the same response size divider, for example:
        /// ```
        /// default          = 1
        /// config1, config2 = 2
        /// config3, config4 = 3
        ///
        /// Response data split:
        ///  _____________________________
        /// |                             |
        /// |           default           |
        /// |_____________________________|
        /// |         |         | config3 |
        /// | config1 | config2 | config4 |
        /// |_________|_________|_________|
        ///
        var batchRequestSizePriority: Int64 {
            switch self {
                case .`default`, .legacyClosedGroup: return 10
                    
                case .configUserProfile, .configContacts,
                    .configConvoInfoVolatile, .configUserGroups,
                    .configClosedGroupInfo, .all:
                    return 1
            }
        }
        
        static func maxSizeMap(for namespaces: [Namespace]) -> [Namespace: Int64] {
            var lastSplit: Int64 = 1
            let namespacePriorityGroups: [Int64: [Namespace]] = namespaces
                .grouped { $0.batchRequestSizePriority }
            let lowestPriority: Int64 = (namespacePriorityGroups.keys.min() ?? 1)
            
            return namespacePriorityGroups
                .map { $0 }
                .sorted(by: { lhs, rhs -> Bool in lhs.key > rhs.key })
                .flatMap { priority, namespaces -> [(namespace: Namespace, maxSize: Int64)] in
                    lastSplit *= Int64(namespaces.count + (priority == lowestPriority ? 0 : 1))

                    return namespaces.map { ($0, lastSplit) }
                }
                .reduce(into: [:]) { result, next in
                    result[next.namespace] = -next.maxSize
                }
        }
    }
}
