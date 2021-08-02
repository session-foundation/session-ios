//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
// 

import PromiseKit

extension TSAccountManager {
    
    func getTurnServerInfo() -> Promise<TurnServerInfo> {
        let request = TSRequest(url: URL(string: "v1/accounts/turn")!, method: "GET", parameters: [:])
        return Promise { resolver in
            self.networkManager.makeRequest(request, success: { (_: URLSessionDataTask, responseObject: Any?) in
                guard responseObject != nil else {
                    return resolver.reject(OWSErrorMakeUnableToProcessServerResponseError())
                }

                if let responseDictionary = responseObject as? [String: AnyObject] {
                    if let turnServerInfo = TurnServerInfo(attributes: responseDictionary) {
                        return resolver.fulfill(turnServerInfo)
                    }
                    Logger.error("unexpected server response:\(responseDictionary)")
                }
                return resolver.reject(OWSErrorMakeUnableToProcessServerResponseError())
            }, failure: { (_: URLSessionDataTask, error: Error) in
                return resolver.reject(error)
            })
            }
        }
}
