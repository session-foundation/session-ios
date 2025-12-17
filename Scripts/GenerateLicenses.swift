#!/usr/bin/xcrun --sdk macosx swift

// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

// Get the Derived Data path and the project's name
let derivedDataPath = getDerivedDataPath() ?? ""
let projectName = ProcessInfo.processInfo.environment["PROJECT_NAME"] ?? ""
let projectPath = ProcessInfo.processInfo.environment["PROJECT_DIR"] ?? FileManager.default.currentDirectoryPath

let packageResolutionFilePath = "\(projectPath)/\(projectName).xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
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
func findLicenses(in packagesPath: String) -> [(package: String, library: String?, licenseContent: String)] {
    var licenses: [(package: String, library: String?, licenseContent: String)] = []
    let packages: [String] = listDirectories(atPath: packagesPath)
    
    print("\(packages.count) packages found in \(packagesPath)")

    packages.forEach { package in
        let packagePath = "\(packagesPath)/\(package)"
        scanDirectory(atPath: packagePath) { filePath in
            // Exclude licences for test and doc libs (not included in prod build)
            guard
                !filePath.lowercased().contains(".gitignore") &&
                !filePath.lowercased().contains(".licenseignore") &&
                !filePath.lowercased().contains("test") &&
                !filePath.lowercased().contains("docs")
            else { return }
            
            let possibleLicenceFiles: [String] = ["license", "copying"]
            
            if let licenceFilename: String =  possibleLicenceFiles.first(where: { filePath.lowercased().contains($0) }) {
                if
                    let licenseContent = try? String(contentsOfFile: filePath, encoding: .utf8),
                    !licenseContent.isEmpty
                {
                    let licenceLibName: String? = filePath.lowercased()
                        .split(separator: licenceFilename)
                        .first?
                        .split(separator: "/")
                        .last
                        .map { String($0) }
                    
                    licenses.append((package, licenceLibName, licenseContent))
                }
            }
        }
    }

    return licenses
}

func findPackageDependencyNames(in resolutionFilePath: String) throws -> Set<String> {
    struct ResolvedPackages: Codable {
        struct Pin: Codable {
            struct State: Codable {
                let branch: String?
                let revision: String
                let version: String?
            }
            
            let identity: String
            let kind: String
            let location: String
            let state: State
        }
        
        let originHash: String
        let pins: [Pin]
        let version: Int
    }
    
    do {
        let data: Data = try Data(contentsOf: URL(fileURLWithPath: resolutionFilePath))
        let resolvedPackages: ResolvedPackages = try JSONDecoder().decode(ResolvedPackages.self, from: data)
        
        print("Found \(resolvedPackages.pins.count) resolved packages.")
        return Set(resolvedPackages.pins.map { $0.identity.lowercased() })
    }
    catch {
        print("error: Failed to load list of resolved packages")
        throw error
    }
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
func writePlist(licenses: [(package: String, library: String?, licenseContent: String)], resolvedPackageNames: Set<String>, outputPath: String) {
    var plistArray: [[String: String]] = []
    let finalLicenses: [(title: String, licenseContent: String)] = licenses
        .filter { resolvedPackageNames.contains($0.package.lowercased()) }
        .map { package, library, content -> (title: String, licenseContent: String) in
            guard
                let library: String = library,
                library.lowercased() != package.lowercased()
            else { return (package, content) }
            
            return ("\(package) - \(library)", content)
        }
        .sorted(by: { $0.title.lowercased() < $1.title.lowercased() })
    
    print("\(finalLicenses.count) being written to plist.")
    
    finalLicenses.forEach { license in
        plistArray.append([
            "Title": license.title,
            "License": license.licenseContent
        ])
    }
    
    let plistData = try! PropertyListSerialization.data(fromPropertyList: plistArray, format: .xml, options: 0)
    let plistURL = URL(fileURLWithPath: outputPath)
    try? plistData.write(to: plistURL)
}

// Execute the license discovery process
let licenses = findLicenses(in: packageCheckoutsPath) + findLicenses(in: packageArtifactsPath)
let resolvedPackageNames = try findPackageDependencyNames(in: packageResolutionFilePath)

// Specify the path for the output plist
let outputPlistPath = "\(projectPath)/\(projectName)/Meta/Settings.bundle/ThirdPartyLicenses.plist"
writePlist(licenses: licenses, resolvedPackageNames: resolvedPackageNames, outputPath: outputPlistPath)

print("Licenses generated successfully at \(outputPlistPath)")
