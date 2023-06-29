import Foundation
import GRDB
import SessionSnodeKit

final class IP2Country {
    static var isInitialized = false
    
    var countryNamesCache: Atomic<[String: String]> = Atomic([:])
    
    // MARK: - Tables
    /// This table has two columns: the "network" column and the "registered_country_geoname_id" column. The network column contains
    /// the **lower** bound of an IP range and the "registered_country_geoname_id" column contains the ID of the country corresponding
    /// to that range. We look up an IP by finding the first index in the network column where the value is greater than the IP we're looking
    /// up (converted to an integer). The IP we're looking up must then be in the range **before** that range.
    private lazy var ipv4Table: [String:[Int]] = {
        let url = Bundle.main.url(forResource: "GeoLite2-Country-Blocks-IPv4", withExtension: nil)!
        let data = try! Data(contentsOf: url)
        return try! NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data) as! [String:[Int]]
    }()
    
    private lazy var countryNamesTable: [String:[String]] = {
        let url = Bundle.main.url(forResource: "GeoLite2-Country-Locations-English", withExtension: nil)!
        let data = try! Data(contentsOf: url)
        return try! NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data) as! [String:[String]]
    }()

    // MARK: Lifecycle
    static let shared = IP2Country()

    private init() {
        NotificationCenter.default.addObserver(self, selector: #selector(populateCacheIfNeededAsync), name: .pathsBuilt, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Implementation
    
    @discardableResult private func cacheCountry(for ip: String, inCache cache: inout [String: String]) -> String {
        if let result: String = cache[ip] { return result }
        
        let ipAsInt: Int = IPv4.toInt(ip)
        
        guard
            let ipv4TableIndex = ipv4Table["network"]?.firstIndex(where: { $0 > ipAsInt }).map({ $0 - 1 }),
            let countryID: Int = ipv4Table["registered_country_geoname_id"]?[ipv4TableIndex],
            let countryNamesTableIndex = countryNamesTable["geoname_id"]?.firstIndex(of: String(countryID)),
            let result: String = countryNamesTable["country_name"]?[countryNamesTableIndex]
        else {
            return "Unknown Country" // Relies on the array being sorted
        }
        
        cache[ip] = result
        return result
    }

    @objc func populateCacheIfNeededAsync() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.populateCacheIfNeeded()
        }
    }

    @discardableResult func populateCacheIfNeeded() -> Bool {
        guard let pathToDisplay: [Snode] = OnionRequestAPI.paths.first else { return false }
        
        countryNamesCache.mutate { [weak self] cache in
            pathToDisplay.forEach { snode in
                self?.cacheCountry(for: snode.ip, inCache: &cache) // Preload if needed
            }
        }
        
        DispatchQueue.main.async {
            IP2Country.isInitialized = true
            NotificationCenter.default.post(name: .onionRequestPathCountriesLoaded, object: nil)
        }
        SNLog("Finished preloading onion request path countries.")
        return true
    }
}
