// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

// MARK: - Log.Category

public extension Log.Category {
    static let ip2Country: Log.Category = .create("IP2Country", defaultLevel: .info)
}

// MARK: - IP2Country

public enum IP2Country {
    @ThreadSafe public static var isInitialized: Bool = false
    @ThreadSafeObject private static var countryNamesCache: [String: String] = [:]
    @ThreadSafe private static var pathsChangedCallbackId: UUID? = nil
    private static let _cacheLoaded: CurrentValueSubject<Bool, Never> = CurrentValueSubject(false)
    public static var cacheLoaded: AnyPublisher<Bool, Never> {
        _cacheLoaded.filter { $0 }.eraseToAnyPublisher()
    }
    private static var currentLocale: String {
        let result: String? = Locale.current.identifier
            .components(separatedBy: "_")
            .first
            .map { identifier in
                switch identifier {
                    case "zh-Hans", "zh": return "zh-CN"  // Not ideal, but the best we can do
                    default: return identifier
                }
            }
        
        return (result ?? "en")  // Fallback to English
    }
    
    // MARK: - Tables
    
    /// This struct contains the data from two tables
    ///
    /// The `countryBlocks` has two columns: the "network" column and the "registered_country_geoname_id" column
    ///
    /// The network column contains the **lower** bound of an IP range and the "registered_country_geoname_id" column contains the
    /// ID of the country corresponding to that range. We look up an IP by finding the first index in the network column where the value is
    /// greater than the IP we're looking up (converted to an integer). The IP we're looking up must then be in the range **before** that range.
    ///
    /// The `countryLocations` has three columns: the "locale_code" column, the "geoname_id" column and the "country_name" column
    ///
    /// These are populated in such a way that you would retrieve in index range in `countryLocationsLocaleCode` for the current locale
    /// (or `en` as default), then find the `geonameId` index from `countryLocationsGeonameId` using the same range, and that index
    /// should be retrieved from `countryLocationsCountryName` in order to get the country name
    struct IP2CountryCache {
        var countryBlocksIPInt: [Int64] = []
        var countryBlocksGeonameId: [String] = []
        
        var countryLocationsLocaleCode: [String] = []
        var countryLocationsGeonameId: [String] = []
        var countryLocationsCountryName: [String] = []
    }
    
    private static var cache: IP2CountryCache = {
        guard
            let url: URL = Bundle.main.url(forResource: "GeoLite2-Country-Blocks-IPv4", withExtension: nil),
            let data: Data = try? Data(contentsOf: url)
        else { return IP2CountryCache() }
        
        /// Extract the number of IPs
        var countryBlockIPCount: Int32 = 0
        _ = withUnsafeMutableBytes(of: &countryBlockIPCount) { countBuffer in
            data.copyBytes(to: countBuffer, from: ..<MemoryLayout<Int32>.size)
        }
        
        /// Move past the IP count
        var remainingData: Data = data.advanced(by: MemoryLayout<Int32>.size)
        
        /// Extract the IPs
        var countryBlockIpInts: [Int64] = [Int64](repeating: 0, count: Int(countryBlockIPCount))
        remainingData.withUnsafeBytes { buffer in
            _ = countryBlockIpInts.withUnsafeMutableBytes { ipBuffer in
                memcpy(ipBuffer.baseAddress, buffer.baseAddress, Int(countryBlockIPCount) * MemoryLayout<Int64>.size)
            }
        }
        
        var countryBlockIpInts2: [Int] = [Int](repeating: 0, count: Int(countryBlockIPCount))
        remainingData.withUnsafeBytes { buffer in
            _ = countryBlockIpInts.withUnsafeMutableBytes { ipBuffer in
                memcpy(ipBuffer.baseAddress, buffer.baseAddress, Int(countryBlockIPCount) * MemoryLayout<Int>.size)
            }
        }
        
        /// Extract arrays from the parts
        func consumeStringArray(_ name: String, from targetData: inout Data) -> [String] {
            /// The data should have a count, followed by actual data (so should have more data than an Int32 would take
            guard targetData.count > MemoryLayout<Int32>.size else {
                Log.error(.ip2Country, "\(name) doesn't have enough data after the count.")
                return []
            }
            
            var targetCount: Int32 = targetData
                .prefix(MemoryLayout<Int32>.size)
                .withUnsafeBytes { bytes -> Int32 in
                    guard
                        bytes.count >= MemoryLayout<Int32>.size,
                        let baseAddress: UnsafePointer<Int32> = bytes
                            .bindMemory(to: Int32.self)
                            .baseAddress
                    else { return 0 }
                    
                    return baseAddress.pointee
                }
            
            /// Move past the count and extract the content data
            targetData = targetData.dropFirst(MemoryLayout<Int32>.size)
            let contentData: Data = targetData.prefix(Int(targetCount))
            
            guard
                !contentData.isEmpty,
                let contentString: String = String(data: contentData, encoding: .utf8)
            else {
                Log.error(.ip2Country, "\(name) failed to convert the content to a string.")
                return []
            }
            
            /// There was a crash related to advancing the data in an invalid way in `2.7.0`, if this does occur then
            /// we want to know about it so add a log
            if targetCount > targetData.count {
                Log.error(.ip2Country, "\(name) suggested it had mare data then was actually available (\(targetCount) vs. \(targetData.count)).")
            }
            
            /// Move past the data and return the result
            targetData = targetData.dropFirst(Int(targetCount))
            return contentString.components(separatedBy: "\0\0")
        }
        
        /// Move past the IP data
        remainingData = remainingData.advanced(by: (Int(countryBlockIPCount) * MemoryLayout<Int64>.size))
        let countryBlocksGeonameIds: [String] = consumeStringArray("CountryBlocks", from: &remainingData)
        let countryLocaleCodes: [String] = consumeStringArray("LocaleCodes", from: &remainingData)
        let countryGeonameIds: [String] = consumeStringArray("Geonames", from: &remainingData)
        let countryNames: [String] = consumeStringArray("CountryNames", from: &remainingData)

        return IP2CountryCache(
            countryBlocksIPInt: countryBlockIpInts,
            countryBlocksGeonameId: countryBlocksGeonameIds,
            countryLocationsLocaleCode: countryLocaleCodes,
            countryLocationsGeonameId: countryGeonameIds,
            countryLocationsCountryName: countryNames
        )
    }()
    
    // MARK: - Implementation

    static func populateCacheIfNeededAsync() {
        DispatchQueue.global(qos: .utility).async {
            /// Ensure the lookup tables get loaded in the background
            _ = cache
            
            guard pathsChangedCallbackId == nil else { return }
            
            pathsChangedCallbackId = LibSession.onPathsChanged(callback: { paths, _ in
                self.populateCacheIfNeeded(paths: paths)
            })
        }
    }

    private static func populateCacheIfNeeded(paths: [[LibSession.Snode]]) {
        guard !paths.isEmpty else { return }
        
        _countryNamesCache.performUpdate { cache in
            var result: [String: String] = cache
            
            paths.forEach { path in
                path.forEach { snode in
                    self.cacheCountry(for: snode.ip, inCache: &result)
                }
            }
            
            return result
        }
        
        self._cacheLoaded.send(true)
        Log.info("Updated onion request path countries.")
    }
    
    private static func cacheCountry(for ip: String, inCache nameCache: inout [String: String]) {
        let currentLocale: String = self.currentLocale  // Store local copy for efficiency
        
        guard nameCache["\(ip)-\(currentLocale)"] == nil else { return }
        
        guard
            let ipAsInt: Int64 = IPv4.toInt(ip),
            let countryBlockGeonameIdIndex: Int = cache.countryBlocksIPInt.firstIndex(where: { $0 > ipAsInt }).map({ $0 - 1 }),
            let localeStartIndex: Int = cache.countryLocationsLocaleCode.firstIndex(where: { $0 == currentLocale }),
            let countryNameIndex: Int = Array(cache.countryLocationsGeonameId[localeStartIndex...]).firstIndex(where: { geonameId in
                geonameId == cache.countryBlocksGeonameId[countryBlockGeonameIdIndex]
            }),
            (localeStartIndex + countryNameIndex) < cache.countryLocationsCountryName.count
        else { return }
        
        let result: String = cache.countryLocationsCountryName[localeStartIndex + countryNameIndex]
        nameCache["\(ip)-\(currentLocale)"] = result
    }
    
    // MARK: - Functions
    
    public static func country(for ip: String) -> String {
        let fallback: String = "Resolving..."
        
        guard _cacheLoaded.value else { return fallback }
        
        return (countryNamesCache["\(ip)-\(currentLocale)"] ?? fallback)
    }
}
