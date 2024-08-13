// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

public enum IPv4 {
    
    public static func toInt(_ ip: String) -> Int? {
        let octets: [Int] = ip.split(separator: ".").compactMap { Int($0) }
        guard octets.count > 1 else { return nil }
        var result: Int = 0
        for i in stride(from: 3, through: 0, by: -1) {
            result += octets[ 3 - i ] << (i * 8)
        }
        
        return (result > 0 ? result : nil)
    }
}
