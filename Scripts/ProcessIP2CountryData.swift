#!/usr/bin/xcrun --sdk macosx swift

// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.
//
// This script should be used to generate an updated IP2Country data file when the raw files
// get updated. This will create the `detinationFileName` in the directory one level above
// the `sourceFilename`
//
// stringlint:disable

import Foundation

#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

// Config

let rawFilesRelativePath: String = "/Session/Meta/Countries/SourceData"
let sourceFilename: String = "GeoLite2-Country-Blocks-IPv4.csv"
let countryNameFilePrefix: String = "GeoLite2-Country-Locations-"   // Last component will be used as Locale
let destinationFileName: String = "GeoLite2-Country-Blocks-IPv4"

// Types

struct IP2CountryCache {
    var countryBlocksIPInt: [Int] = []
    var countryBlocksGeonameId: [String] = []
    
    var countryLocationsLocaleCode: [String] = []
    var countryLocationsGeonameId: [String] = []
    var countryLocationsCountryName: [String] = []
}

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

// Logic

class Processor {
    static var keepRunning = true

    static func getTerminalWidth() -> Int {
        var w = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0 {
            return Int(w.ws_col)
        }
        return 80 // default width if unable to get the terminal width
    }

    static func printProgressBar(prefix: String, progress: Double, total: Int) {
        let barLength = (total - prefix.count - 10) // Leave some space for the percentage display
        let filledLength = Int(progress * Double(barLength))
        let bar = String(repeating: "=", count: filledLength) + String(repeating: " ", count: barLength - filledLength)
        print("\r\(prefix)[\(bar)] \(Int(progress * 100))%", terminator: "")
        fflush(stdout)
    }

    static func processFiles() {
        print("Searching For files")
        let path: String = {
            switch ProcessInfo.processInfo.environment["PROJECT_DIR"] {
                case .some(let projectDir): return "\(projectDir)\(rawFilesRelativePath)"
                case .none:
                    let currentDir: String = FileManager.default.currentDirectoryPath
                    
                    guard currentDir.hasSuffix("/Scripts") else {
                        return "\(currentDir)\(rawFilesRelativePath)"
                    }
                    
                    return "\(currentDir.dropLast("/Scripts".count))\(rawFilesRelativePath)"
            }
        }()
        guard keepRunning else { return }

        guard
            let enumerator: FileManager.DirectoryEnumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: path),
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ),
            let fileUrls: [URL] = enumerator.allObjects as? [URL]
        else { fatalError("Could not locate files in path directory: \(path)") }

        guard keepRunning else { return }
        print("Found country blocks file ✅")

        /// Ensure we have the `sourceFilename`
        guard let sourceFileUrl: URL = fileUrls.first(where: { fileUrl in
            ((try? fileUrl.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == false) &&
            fileUrl.path.lowercased().hasSuffix(sourceFilename.lowercased())
        }) else { fatalError("Could not locate source file") }
        
        guard keepRunning else { return }

        /// Filter down the files to find the country name files
        let localisedCountryNameFileUrls: [URL] = fileUrls.filter { fileUrl in
            ((try? fileUrl.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == false) &&
            fileUrl.lastPathComponent.lowercased().hasPrefix(countryNameFilePrefix.lowercased()) &&
            fileUrl.lastPathComponent.lowercased().hasSuffix(".csv")
        }

        guard keepRunning else { return }
        
        let languageCodes: String = localisedCountryNameFileUrls
            .map { url in String(url.lastPathComponent.dropFirst(countryNameFilePrefix.count).dropLast(".csv".count)) }
            .sorted()
            .joined(separator: ", ")
        print("Found \(localisedCountryNameFileUrls.count) language files ✅ (\(languageCodes))")
        
        guard keepRunning else { return }

        /// This function can be used to regenerate the `GeoLite2-Country-Blocks-IPv4` file given a `SourceData/GeoLite2-Country-Blocks-IPv4.csv`
        /// file (loading the csv directly takes `5+ seconds` whereas loading the binary output of this function takes `~850ms`
        guard
            let sourceData: Data = try? Data(contentsOf: sourceFileUrl),
            let sourceDataString: String = String(data: sourceData, encoding: .utf8)
        else { fatalError("Could not load source file") }

        guard keepRunning else { return }
        
        let terminalWidth: Int = getTerminalWidth()
        
        /// Header line plus at least one line of content
        let lines: [String] = sourceDataString.components(separatedBy: "\n")
        guard lines.count > 1 else { fatalError("Source file had no content") }

        /// Create the cache object
        var cache: IP2CountryCache = IP2CountryCache()

        /// Structure of the data should be `network,registered_country_geoname_id`
        let countryBlockPrefix: String = "Processing country blocks: "
        lines[1...].enumerated().forEach { index, line in
            guard keepRunning else { return }
            
            let values: [String] = line
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: ",")
            
            guard
                values.count == 2,
                let ipNoSubnetMask: String = values[0].components(separatedBy: "/").first,
                let ipAsInt: Int = IPv4.toInt(ipNoSubnetMask)
            else { return }
            
            cache.countryBlocksIPInt.append(ipAsInt)
            cache.countryBlocksGeonameId.append(values[1])
            
            let progress = (Double(index) / Double(lines.count))
            printProgressBar(prefix: countryBlockPrefix, progress: progress, total: (terminalWidth - 10))
        }
        guard keepRunning else { return }
        print("\r\u{1B}[2KProcessing country blocks completed ✅")
        
        /// Structure of the data should be `geoname_id,locale_code,continent_code,continent_name,country_iso_code,country_name,is_in_european_union`
        let languagesPrefix: String = "Processing languages: "
        localisedCountryNameFileUrls.enumerated().forEach { fileIndex, fileUrl in
            guard keepRunning else { return }
            guard
                let localisedData: Data = try? Data(contentsOf: fileUrl),
                let localisedDataString: String = String(data: localisedData, encoding: .utf8)
            else { fatalError("Could not load localised country name file") }

            /// Header line plus at least one line of content
            let lines: [String] = localisedDataString.components(separatedBy: "\n")
            guard lines.count > 1 else { fatalError("Localised country file had no content") }
            
            lines[1...].enumerated().forEach { index, line in
                let values: [String] = line
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: ",")
                guard values.count == 7 else { return }
                
                cache.countryLocationsLocaleCode.append(values[1])
                cache.countryLocationsGeonameId.append(values[0])
                cache.countryLocationsCountryName.append(values[5].trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
                
                let progress = (Double((fileIndex * lines.count) + index) / Double(localisedCountryNameFileUrls.count * lines.count))
                printProgressBar(prefix: languagesPrefix, progress: progress, total: (terminalWidth - 10))
            }
        }
        guard keepRunning else { return }
        print("\r\u{1B}[2KProcessing languages completed ✅")

        /// Generate the binary data
        var outputData: Data = Data()
        var ipCount = Int32(cache.countryBlocksIPInt.count)
        outputData.append(Data(bytes: &ipCount, count: MemoryLayout<Int32>.size))
        outputData.append(Data(bytes: cache.countryBlocksIPInt, count: cache.countryBlocksIPInt.count * MemoryLayout<Int>.size))
        
        let geonameIdData: Data = cache.countryBlocksGeonameId.joined(separator: "\0\0").data(using: .utf8)!
        var geonameIdCount = Int32(geonameIdData.count)
        outputData.append(Data(bytes: &geonameIdCount, count: MemoryLayout<Int32>.size))
        outputData.append(geonameIdData)
        
        let localeCodeData: Data = cache.countryLocationsLocaleCode.joined(separator: "\0\0").data(using: .utf8)!
        var localeCodeCount = Int32(localeCodeData.count)
        outputData.append(Data(bytes: &localeCodeCount, count: MemoryLayout<Int32>.size))
        outputData.append(localeCodeData)
        
        let locationGeonameData: Data = cache.countryLocationsGeonameId.joined(separator: "\0\0").data(using: .utf8)!
        var locationGeonameCount = Int32(locationGeonameData.count)
        outputData.append(Data(bytes: &locationGeonameCount, count: MemoryLayout<Int32>.size))
        outputData.append(locationGeonameData)
        
        let countryNameData: Data = cache.countryLocationsCountryName.joined(separator: "\0\0").data(using: .utf8)!
        var countryNameCount = Int32(countryNameData.count)
        outputData.append(Data(bytes: &countryNameCount, count: MemoryLayout<Int32>.size))
        outputData.append(countryNameData)
        
        guard keepRunning else { return }

        /// Write the outputData to disk
        let destinaitonFileUrl: URL = sourceFileUrl
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("GeoLite2-Country-Blocks-IPv4")
        try? outputData.write(to: destinaitonFileUrl)
        print("Saved output to \(destinaitonFileUrl.absoluteString)")
    }
}

// Handle SIGINT (Ctrl+C)
func handleSIGINT(signal: Int32) {
    Processor.keepRunning = false
    print("\nProcess interrupted. Exiting...")
}

signal(SIGINT, handleSIGINT)
Processor.processFiles()
