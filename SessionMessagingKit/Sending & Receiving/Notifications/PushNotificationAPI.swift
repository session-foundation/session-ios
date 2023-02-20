// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

public enum PushNotificationAPI {
    struct RegistrationRequestBody: Codable {
        let token: String
        let pubKey: String?
    }
    
    struct NotifyRequestBody: Codable {
        enum CodingKeys: String, CodingKey {
            case data
            case sendTo = "send_to"
        }
        
        let data: String
        let sendTo: String
    }
    
    struct ClosedGroupRequestBody: Codable {
        let closedGroupPublicKey: String
        let pubKey: String
    }

    // MARK: - Settings
    
    public static let server = "https://live.apns.getsession.org"
    public static let serverPublicKey = "642a6585919742e5a2d4dc51244964fbcd8bcab2b75612407de58b810740d049"
    
    private static let maxRetryCount: Int = 4
    private static let tokenExpirationInterval: TimeInterval = 12 * 60 * 60

    public enum ClosedGroupOperation: Int {
        case subscribe, unsubscribe
        
        public var endpoint: String {
            switch self {
                case .subscribe: return "subscribe_closed_group"
                case .unsubscribe: return "unsubscribe_closed_group"
            }
        }
    }
    
    // MARK: - Registration
    
    public static func unregister(_ token: Data) -> AnyPublisher<Void, Error> {
        let requestBody: RegistrationRequestBody = RegistrationRequestBody(token: token.toHexString(), pubKey: nil)
        
        guard let body: Data = try? JSONEncoder().encode(requestBody) else {
            return Fail(error: HTTPError.invalidJSON)
                .eraseToAnyPublisher()
        }
        
        // Unsubscribe from all closed groups (including ones the user is no longer a member of,
        // just in case)
        Storage.shared
            .readPublisher(receiveOn: DispatchQueue.global(qos: .background)) { db -> (String, Set<String>) in
                (
                    getUserHexEncodedPublicKey(db),
                    try ClosedGroup
                        .select(.threadId)
                        .asRequest(of: String.self)
                        .fetchSet(db)
                )
            }
            .flatMap { userPublicKey, closedGroupPublicKeys in
                Publishers
                    .MergeMany(
                        closedGroupPublicKeys
                            .map { closedGroupPublicKey -> AnyPublisher<Void, Error> in
                                PushNotificationAPI
                                    .performOperation(
                                        .unsubscribe,
                                        for: closedGroupPublicKey,
                                        publicKey: userPublicKey
                                    )
                            }
                    )
                    .collect()
                    .eraseToAnyPublisher()
            }
            .sinkUntilComplete()
        
        // Unregister for normal push notifications
        let url = URL(string: "\(server)/unregister")!
        var request: URLRequest = URLRequest(url: url)
        request.httpMethod = "POST"
        request.allHTTPHeaderFields = [ HTTPHeader.contentType: "application/json" ]
        request.httpBody = body
        
        return OnionRequestAPI
            .sendOnionRequest(request, to: server, with: serverPublicKey)
            .map { _, data -> Void in
                guard let response: PushServerResponse = try? data?.decoded(as: PushServerResponse.self) else {
                    return SNLog("Couldn't unregister from push notifications.")
                }
                guard response.code != 0 else {
                    return SNLog("Couldn't unregister from push notifications due to error: \(response.message ?? "nil").")
                }
                
                return ()
            }
            .retry(maxRetryCount)
            .handleEvents(
                receiveCompletion: { result in
                    switch result {
                        case .finished: break
                        case .failure: SNLog("Couldn't unregister from push notifications.")
                    }
                }
            )
            .eraseToAnyPublisher()
    }
    
    public static func register(
        with token: Data,
        publicKey: String,
        isForcedUpdate: Bool
    ) -> AnyPublisher<Void, Error> {
        let hexEncodedToken: String = token.toHexString()
        let requestBody: RegistrationRequestBody = RegistrationRequestBody(token: hexEncodedToken, pubKey: publicKey)
        
        guard let body: Data = try? JSONEncoder().encode(requestBody) else {
            return Fail(error: HTTPError.invalidJSON)
                .eraseToAnyPublisher()
        }
        
        let oldToken: String? = UserDefaults.standard[.deviceToken]
        let lastUploadTime: Double = UserDefaults.standard[.lastDeviceTokenUpload]
        let now: TimeInterval = Date().timeIntervalSince1970
        
        guard isForcedUpdate || hexEncodedToken != oldToken || now - lastUploadTime > tokenExpirationInterval else {
            SNLog("Device token hasn't changed or expired; no need to re-upload.")
            return Just(())
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
        
        let url = URL(string: "\(server)/register")!
        var request: URLRequest = URLRequest(url: url)
        request.httpMethod = "POST"
        request.allHTTPHeaderFields = [ HTTPHeader.contentType: "application/json" ]
        request.httpBody = body
        
        return Publishers
            .MergeMany(
                [
                    OnionRequestAPI
                        .sendOnionRequest(request, to: server, with: serverPublicKey)
                        .map { _, data -> Void in
                            guard let response: PushServerResponse = try? data?.decoded(as: PushServerResponse.self) else {
                                return SNLog("Couldn't register device token.")
                            }
                            guard response.code != 0 else {
                                return SNLog("Couldn't register device token due to error: \(response.message ?? "nil").")
                            }
                            
                            UserDefaults.standard[.deviceToken] = hexEncodedToken
                            UserDefaults.standard[.lastDeviceTokenUpload] = now
                            UserDefaults.standard[.isUsingFullAPNs] = true
                            return ()
                        }
                        .retry(maxRetryCount)
                        .handleEvents(
                            receiveCompletion: { result in
                                switch result {
                                    case .finished: break
                                    case .failure: SNLog("Couldn't register device token.")
                                }
                            }
                        )
                        .eraseToAnyPublisher()
                ].appending(
                    contentsOf: Storage.shared
                        .read { db -> [String] in
                            try ClosedGroup
                                .select(.threadId)
                                .joining(
                                    required: ClosedGroup.members
                                        .filter(GroupMember.Columns.profileId == getUserHexEncodedPublicKey(db))
                                )
                                .asRequest(of: String.self)
                                .fetchAll(db)
                        }
                        .defaulting(to: [])
                        .map { closedGroupPublicKey -> AnyPublisher<Void, Error> in
                            PushNotificationAPI
                                .performOperation(
                                    .subscribe,
                                    for: closedGroupPublicKey,
                                    publicKey: publicKey
                                )
                        }
                )
            )
            .collect()
            .map { _ in () }
            .eraseToAnyPublisher()
    }

    public static func performOperation(
        _ operation: ClosedGroupOperation,
        for closedGroupPublicKey: String,
        publicKey: String
    ) -> AnyPublisher<Void, Error> {
        let isUsingFullAPNs = UserDefaults.standard[.isUsingFullAPNs]
        let requestBody: ClosedGroupRequestBody = ClosedGroupRequestBody(
            closedGroupPublicKey: closedGroupPublicKey,
            pubKey: publicKey
        )
        
        guard isUsingFullAPNs else {
            return Just(())
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
        guard let body: Data = try? JSONEncoder().encode(requestBody) else {
            return Fail(error: HTTPError.invalidJSON)
                .eraseToAnyPublisher()
        }
        
        let url = URL(string: "\(server)/\(operation.endpoint)")!
        var request: URLRequest = URLRequest(url: url)
        request.httpMethod = "POST"
        request.allHTTPHeaderFields = [ HTTPHeader.contentType: "application/json" ]
        request.httpBody = body
        
        return OnionRequestAPI
            .sendOnionRequest(request, to: server, with: serverPublicKey)
            .map { _, data in
                guard let response: PushServerResponse = try? data?.decoded(as: PushServerResponse.self) else {
                    return SNLog("Couldn't subscribe/unsubscribe for closed group: \(closedGroupPublicKey).")
                }
                guard response.code != 0 else {
                    return SNLog("Couldn't subscribe/unsubscribe for closed group: \(closedGroupPublicKey) due to error: \(response.message ?? "nil").")
                }
                
                return ()
            }
            .retry(maxRetryCount)
            .handleEvents(
                receiveCompletion: { result in
                    switch result {
                        case .finished: break
                        case .failure:
                            SNLog("Couldn't subscribe/unsubscribe for closed group: \(closedGroupPublicKey).")
                    }
                }
            )
            .eraseToAnyPublisher()
    }
    
    // MARK: - Notify
    
    public static func notify(
        recipient: String,
        with message: String,
        maxRetryCount: Int? = nil
    ) -> AnyPublisher<Void, Error> {
        let requestBody: NotifyRequestBody = NotifyRequestBody(data: message, sendTo: recipient)
        
        guard let body: Data = try? JSONEncoder().encode(requestBody) else {
            return Fail(error: HTTPError.invalidJSON)
                .eraseToAnyPublisher()
        }
        
        let url = URL(string: "\(server)/notify")!
        var request: URLRequest = URLRequest(url: url)
        request.httpMethod = "POST"
        request.allHTTPHeaderFields = [ HTTPHeader.contentType: "application/json" ]
        request.httpBody = body
        
        return OnionRequestAPI
            .sendOnionRequest(request, to: server, with: serverPublicKey)
            .map { _, data -> Void in
                guard let response: PushServerResponse = try? data?.decoded(as: PushServerResponse.self) else {
                    return SNLog("Couldn't send push notification.")
                }
                guard response.code != 0 else {
                    return SNLog("Couldn't send push notification due to error: \(response.message ?? "nil").")
                }
                
                return ()
            }
            .retry(maxRetryCount ?? PushNotificationAPI.maxRetryCount)
            .eraseToAnyPublisher()
    }
}
