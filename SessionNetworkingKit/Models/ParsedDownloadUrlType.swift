// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public protocol ParsedDownloadUrlType {
    var originalUrlString: String { get }
    var url: URL { get }
    var fileId: String { get }
    var wantsStreamDecryption: Bool { get }
}

public extension Network {
    enum ParsedDownloadUrl {
        public enum Variant {
            case community
            case fileServer
        }
    }
    
    static func parsedDownloadUrl(for urlString: String?, authMethod: AuthenticationMethod?) -> (any ParsedDownloadUrlType)? {
        switch authMethod {
            case is Authentication.Community: return parsedDownloadUrl(for: urlString, variant: .community)
            default: return parsedDownloadUrl(for: urlString, variant: .fileServer)
        }
    }
    
    static func parsedDownloadUrl(for urlString: String?, variant: ParsedDownloadUrl.Variant) -> (any ParsedDownloadUrlType)? {
        guard let urlString else { return nil }
        
        switch variant {
            case .community: return Network.SOGS.parsedDownloadUrl(for: urlString)
            case .fileServer: return Network.FileServer.parsedDownloadUrl(for: urlString)
        }
    }
}
