// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension URL {
    var queryParameters: [HTTPQueryParam: String] {
        guard
            let components: URLComponents = URLComponents(url: self, resolvingAgainstBaseURL: false),
            let queryItems: [URLQueryItem] = components.queryItems
        else { return [:] }
        
        return queryItems.reduce(into: [:]) { result, next in
            result[next.name] = next.value
        }
    }
    
    var fragmentParameters: [String: String] {
        guard let fragment = self.fragment else { return [:] }
        
        // Parse fragment as if it were a query string
        var components: URLComponents = URLComponents()
        components.query = fragment
        
        return (components.queryItems?.reduce(into: [:]) { $0[$1.name] = $1.value } ?? [:])
    }
}
