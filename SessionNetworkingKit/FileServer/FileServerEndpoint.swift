// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension Network.FileServer {
    enum Endpoint: EndpointType {
        case file
        case fileIndividual(String)
        case directUrl(URL)
        case sessionVersion
        
        public static var name: String { "FileServer.Endpoint" }
        
        public var path: String {
            switch self {
                case .file: return "file"
                case .fileIndividual(let fileId): return "file/\(fileId)"
                case .directUrl(let url): return url.path.removingPrefix("/")
                case .sessionVersion: return "session_version"
            }
        }
    }
}
