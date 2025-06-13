// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public struct BencodeResponse<T: Decodable> {
    public let info: T
    public let data: Data?
}

extension BencodeResponse: Decodable {
    public init(from decoder: Decoder) throws {
        var container: UnkeyedDecodingContainer = try decoder.unkeyedContainer()
        
        do {
            /// Try to decode the first element as `T` directly (this will increment the decoder past the first element whether it
            /// succeeds or fails)
            self.info = try container.decode(T.self)
        }
        catch {
            /// If that failed then we need a new container in order to try to decode the first element again, so create a new one and
            /// try decode the first element as a JSON string
            var retryContainer: UnkeyedDecodingContainer = try decoder.unkeyedContainer()
            let infoString: String = try retryContainer.decode(String.self)
            let infoData: Data = try infoString.data(using: .ascii) ?? { throw NetworkError.parsingFailed }()
            
            /// Pass the `dependencies` through to the `JSONDecoder` if we have them, if
            /// we don't then it's the responsibility of the decoding type to throw when `dependencies`
            /// isn't present but is required
            let jsonDecoder: JSONDecoder = (decoder.dependencies.map { JSONDecoder(using: $0) } ?? JSONDecoder())
            self.info = try jsonDecoder.decode(T.self, from: infoData)
        }
        
        /// The second element (if present) will be the response data and should just decode directly (we can use the initial
        /// `container` since it should be sitting at the second element)
        self.data = (container.isAtEnd ? nil : try container.decode(Data.self))
    }
}

extension BencodeResponse: Equatable where T: Equatable {}
extension BencodeResponse: Encodable where T: Encodable {}
