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
        
        // MARK: Variables
        
        var requiresReadAuthentication: Bool {
            switch self {
                case .legacyClosedGroup: return false
                default: return true
            }
        }
        
        var requiresWriteAuthentication: Bool {
            switch self {
                // Not in use until we can batch delete and store config messages
                case .default, .legacyClosedGroup: return false
                default: return true
            }
        }
        
        var verificationString: String {
            switch self {
                case .`default`: return ""
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
                    .configClosedGroupInfo:
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
