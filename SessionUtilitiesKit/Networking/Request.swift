import Foundation

// MARK: - Convenience Types

public struct Empty: Codable {
    public init() {}
}

public typealias NoBody = Empty
public typealias NoResponse = Empty

public protocol EndpointType: Hashable {
    var path: String { get }
}

// MARK: - Request

public struct Request<T: Encodable, Endpoint: EndpointType> {
    public let method: HTTPMethod
    public let server: String
    public let endpoint: Endpoint
    public let queryParameters: [HTTPQueryParam: String]
    public let headers: [HTTPHeader: String]
    /// This is the body value sent during the request
    ///
    /// **Warning:** The `bodyData` value should be used to when making the actual request instead of this as there
    /// is custom handling for certain data types
    public let body: T?
    
    // MARK: - Initialization

    public init(
        method: HTTPMethod = .get,
        server: String,
        endpoint: Endpoint,
        queryParameters: [HTTPQueryParam: String] = [:],
        headers: [HTTPHeader: String] = [:],
        body: T? = nil
    ) {
        self.method = method
        self.server = server
        self.endpoint = endpoint
        self.queryParameters = queryParameters
        self.headers = headers
        self.body = body
    }
    
    // MARK: - Internal Methods
    
    private var url: URL? {
        return URL(string: "\(server)\(urlPathAndParamsString)")
    }
    
    private func bodyData() throws -> Data? {
        // Note: Need to differentiate between JSON, b64 string and bytes body values to ensure they are
        // encoded correctly so the server knows how to handle them
        switch body {
            case let bodyString as String:
                // The only acceptable string body is a base64 encoded one
                guard let encodedData: Data = Data(base64Encoded: bodyString) else {
                    throw HTTPError.parsingFailed
                }
                
                return encodedData
                
            case let bodyBytes as [UInt8]:
                return Data(bodyBytes)
                
            default:
                // Having no body is fine so just return nil
                guard let body: T = body else { return nil }

                return try JSONEncoder().encode(body)
        }
    }
    
    // MARK: - Request Generation
    
    public var urlPathAndParamsString: String {
        return [
            "/\(endpoint.path)",
            queryParameters
                .map { key, value in "\(key)=\(value)" }
                .joined(separator: "&")
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: "?")
    }
    
    public func generateUrlRequest() throws -> URLRequest {
        guard let url: URL = url else { throw HTTPError.invalidURL }
        
        var urlRequest: URLRequest = URLRequest(url: url)
        urlRequest.httpMethod = method.rawValue
        urlRequest.allHTTPHeaderFields = headers.toHTTPHeaders()
        urlRequest.httpBody = try bodyData()
        
        return urlRequest
    }
}

extension Request: Equatable where T: Equatable {}
