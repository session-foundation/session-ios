// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension URL {
    var strippingQueryAndFragment: URL? {
        guard var components: URLComponents = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems = nil
        components.fragment = nil
        
        return components.url
    }
    
    var queryParameters: [HTTPQueryParam: String] {
        guard
            let components: URLComponents = URLComponents(url: self, resolvingAgainstBaseURL: false),
            let queryItems: [URLQueryItem] = components.queryItems
        else { return [:] }
        
        return queryItems.reduce(into: [:]) { result, next in
            result[HTTPQueryParam(next.name)] = (next.value ?? "")
        }
    }
    
    var fragmentParameters: [HTTPFragmentParam: String] {
        guard let fragment = self.fragment else { return [:] }
        
        // Parse fragment as if it were a query string
        var components: URLComponents = URLComponents()
        components.query = fragment
        
        guard let queryItems: [URLQueryItem] = components.queryItems else { return [:] }
        
        return queryItems.reduce(into: [:]) { result, next in
            result[HTTPFragmentParam(next.name)] = (next.value ?? "")
        }
    }
}
