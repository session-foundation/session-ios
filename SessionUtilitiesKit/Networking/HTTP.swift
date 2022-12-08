// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine

public enum HTTP {
    private static let seedNodeURLSession = URLSession(configuration: .ephemeral, delegate: seedNodeURLSessionDelegate, delegateQueue: nil)
    private static let seedNodeURLSessionDelegate = SeedNodeURLSessionDelegateImplementation()
    private static let snodeURLSession = URLSession(configuration: .ephemeral, delegate: snodeURLSessionDelegate, delegateQueue: nil)
    private static let snodeURLSessionDelegate = SnodeURLSessionDelegateImplementation()

    // MARK: - Certificates
    
    private static let storageSeed1Cert: SecCertificate = {
        let path = Bundle.main.path(forResource: "storage-seed-1", ofType: "der")!
        let data = try! Data(contentsOf: URL(fileURLWithPath: path))
        return SecCertificateCreateWithData(nil, data as CFData)!
    }()
    
    private static let storageSeed3Cert: SecCertificate = {
        let path = Bundle.main.path(forResource: "storage-seed-3", ofType: "der")!
        let data = try! Data(contentsOf: URL(fileURLWithPath: path))
        return SecCertificateCreateWithData(nil, data as CFData)!
    }()
    
    private static let publicLokiFoundationCert: SecCertificate = {
        let path = Bundle.main.path(forResource: "public-loki-foundation", ofType: "der")!
        let data = try! Data(contentsOf: URL(fileURLWithPath: path))
        return SecCertificateCreateWithData(nil, data as CFData)!
    }()
    
    // MARK: - Settings
    
    public static let defaultTimeout: TimeInterval = 10

    // MARK: - Seed Node URL Session Delegate Implementation
    
    private final class SeedNodeURLSessionDelegateImplementation : NSObject, URLSessionDelegate {

        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            guard let trust = challenge.protectionSpace.serverTrust else {
                return completionHandler(.cancelAuthenticationChallenge, nil)
            }
            // Mark the seed node certificates as trusted
            let certificates = [ storageSeed1Cert, storageSeed3Cert, publicLokiFoundationCert ]
            guard SecTrustSetAnchorCertificates(trust, certificates as CFArray) == errSecSuccess else {
                return completionHandler(.cancelAuthenticationChallenge, nil)
            }
            // Check that the presented certificate is one of the seed node certificates
            var result: SecTrustResultType = .invalid
            guard SecTrustEvaluate(trust, &result) == errSecSuccess else {
                return completionHandler(.cancelAuthenticationChallenge, nil)
            }
            switch result {
            case .proceed, .unspecified:
                // Unspecified indicates that evaluation reached an (implicitly trusted) anchor certificate without
                // any evaluation failures, but never encountered any explicitly stated user-trust preference. This
                // is the most common return value. The Keychain Access utility refers to this value as the "Use System
                // Policy," which is the default user setting.
                return completionHandler(.useCredential, URLCredential(trust: trust))
            default: return completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }
    
    // MARK: - Snode URL Session Delegate Implementation
    
    private final class SnodeURLSessionDelegateImplementation : NSObject, URLSessionDelegate {

        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            // Snode to snode communication uses self-signed certificates but clients can safely ignore this
            completionHandler(.useCredential, URLCredential(trust: challenge.protectionSpace.serverTrust!))
        }
    }
    
    // MARK: - Execution
        
    public static func execute(
        _ method: HTTPMethod,
        _ url: String,
        timeout: TimeInterval = HTTP.defaultTimeout,
        useSeedNodeURLSession: Bool = false
    ) -> AnyPublisher<Data, Error> {
        return execute(
            method,
            url,
            body: nil,
            timeout: timeout,
            useSeedNodeURLSession: useSeedNodeURLSession
        )
    }
    
    public static func execute(
        _ method: HTTPMethod,
        _ url: String,
        body: Data?,
        timeout: TimeInterval = HTTP.defaultTimeout,
        useSeedNodeURLSession: Bool = false
    ) -> AnyPublisher<Data, Error> {
        guard let url: URL = URL(string: url) else {
            return Fail<Data, Error>(error: HTTPError.invalidURL)
                .eraseToAnyPublisher()
        }
        
        let urlSession: URLSession = (useSeedNodeURLSession ? seedNodeURLSession : snodeURLSession)
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.httpBody = body
        request.timeoutInterval = timeout
        request.allHTTPHeaderFields?.removeValue(forKey: "User-Agent")
        request.setValue("WhatsApp", forHTTPHeaderField: "User-Agent") // Set a fake value
        request.setValue("en-us", forHTTPHeaderField: "Accept-Language") // Set a fake value
        
        return urlSession
            .dataTaskPublisher(for: request)
            .mapError { error in
                SNLog("\(method.rawValue) request to \(url) failed due to error: \(error).")
                
                // Override the actual error so that we can correctly catch failed requests
                // in sendOnionRequest(invoking:on:with:)
                switch (error as NSError).code {
                    case NSURLErrorTimedOut: return HTTPError.timeout
                    default: return HTTPError.httpRequestFailed(statusCode: 0, data: nil)
                }
            }
            .flatMap { data, response in
                guard let response = response as? HTTPURLResponse else {
                    SNLog("\(method.rawValue) request to \(url) failed.")
                    return Fail<Data, Error>(error: HTTPError.httpRequestFailed(statusCode: 0, data: data))
                        .eraseToAnyPublisher()
                }
                let statusCode = UInt(response.statusCode)
                // TODO: Remove all the JSON handling?
                guard 200...299 ~= statusCode else {
                    var json: JSON? = nil
                    if let processedJson: JSON = try? JSONSerialization.jsonObject(with: data, options: [ .fragmentsAllowed ]) as? JSON {
                        json = processedJson
                    }
                    else if let result: String = String(data: data, encoding: .utf8) {
                        json = [ "result": result ]
                    }
                    
                    let jsonDescription: String = (json?.prettifiedDescription ?? "no debugging info provided")
                    SNLog("\(method.rawValue) request to \(url) failed with status code: \(statusCode) (\(jsonDescription)).")
                    return Fail<Data, Error>(error: HTTPError.httpRequestFailed(statusCode: statusCode, data: data))
                        .eraseToAnyPublisher()
                }
                
                return Just(data)
                    .setFailureType(to: Error.self)
                    .eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }
}
