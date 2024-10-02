#!/usr/bin/xcrun --sdk macosx swift

// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

// Get the Derived Data path and the project's name
let derivedDataPath = getDerivedDataPath() ?? ""
let projectName = ProcessInfo.processInfo.environment["PROJECT_NAME"] ?? ""
let projectPath = "\(ProcessInfo.processInfo.environment["PROJECT_DIR"] ?? FileManager.default.currentDirectoryPath)/\(projectName)"

let packageCheckoutsPath = "\(derivedDataPath)/SourcePackages/checkouts/"
let packageArtifactsPath = "\(derivedDataPath)/SourcePackages/artifacts/"

func getDerivedDataPath() -> String? {
    // Define the regular expression pattern to extract the DerivedData path
    let regexPattern = ".*DerivedData/[^/]*"
    guard
        let buildDir = ProcessInfo.processInfo.environment["BUILD_DIR"],
        let regex = try? NSRegularExpression(pattern: regexPattern)
    else { return nil }
    
    let range = NSRange(location: 0, length: buildDir.utf16.count)
    
    // Perform the regex matching
    if let match = regex.firstMatch(in: buildDir, options: [], range: range) {
        // Extract the matching portion (the DerivedData path)
        if let range = Range(match.range, in: buildDir) {
            return String(buildDir[range])
        }
    } else {
        print("No DerivedData path found in BUILD_DIR")
    }
    
    return nil
}

// Function to list all directories (Swift package checkouts) inside the SourcePackages/checkouts directory
func listDirectories(atPath path: String) -> [String] {
    let fileManager = FileManager.default
    do {
        let items = try fileManager.contentsOfDirectory(atPath: path)
        return items.filter { item in
            var isDir: ObjCBool = false
            let fullPath = path + "/" + item
            return fileManager.fileExists(atPath: fullPath, isDirectory: &isDir) && isDir.boolValue
        }
    } catch {
        print("Error reading contents of directory: \(error)")
        return []
    }
}

// Function to find and read LICENSE files in each package
func findLicenses(in packagesPath: String) -> [(package: String, licenseContent: String)] {
    var licenses: [(package: String, licenseContent: String)] = []
    let packages: [String] = listDirectories(atPath: packagesPath)
    
    print("\(packages.count) packages found in \(packagesPath)")

    packages.forEach { package in
        let packagePath = "\(packagesPath)/\(package)"
        scanDirectory(atPath: packagePath) { filePath in
            if filePath.lowercased().contains("license") || filePath.lowercased().contains("copying") {
                if let licenseContent = try? String(contentsOfFile: filePath, encoding: .utf8) {
                    licenses.append((package, licenseContent))
                }
            }
        }
    }

    return licenses
}

func scanDirectory(atPath path: String, foundFile: (String) -> Void) {
    if let enumerator = FileManager.default.enumerator(atPath: path) {
        for case let file as String in enumerator {
            let fullPath = "\(path)/\(file)"
            if FileManager.default.fileExists(atPath: fullPath, isDirectory: nil) {
                foundFile(fullPath)
            }
        }
    }
}

// Write licenses to a plist file
func writePlist(licenses: [(package: String, licenseContent: String)], outputPath: String) {
    var plistArray: [[String: String]] = []
    
    for license in licenses {
        plistArray.append([
            "Title": license.package,
            "License": license.licenseContent
        ])
    }
    
    let plistData = try! PropertyListSerialization.data(fromPropertyList: plistArray, format: .xml, options: 0)
    let plistURL = URL(fileURLWithPath: outputPath)
    try? plistData.write(to: plistURL)
}

// Execute the license discovery process
let licenses = findLicenses(in: packageCheckoutsPath) + findLicenses(in: packageArtifactsPath)

// Specify the path for the output plist
let outputPlistPath = "\(projectPath)/Meta/Settings.bundle/ThirdPartyLicenses.plist"
writePlist(licenses: licenses, outputPath: outputPlistPath)

print("Licenses generated successfully at \(outputPlistPath)")
