#!/usr/bin/xcrun --sdk macosx swift

// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

let projectName = ProcessInfo.processInfo.environment["PROJECT_NAME"] ?? ""
let projectPath = ProcessInfo.processInfo.environment["PROJECT_DIR"] ?? FileManager.default.currentDirectoryPath

let packageResolutionFilePath = "\(projectPath)/\(projectName).xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
let outputPlistPath = "\(projectPath)/\(projectName)/Meta/Settings.bundle/ThirdPartyLicenses.plist"

/// `ThirdPartyLicenses.plist` is tracked in git, this phase runs on **every** build, and the licences it
/// carries are a distribution requirement. So every failure below has to stop the build rather than write
/// a shorter list: a plist that is merely *wrong* looks exactly like a plist that is right, and the diff
/// lands in whichever commit the developer makes next.
///
/// The `error:` prefix is what makes Xcode surface this in the Issue navigator instead of burying it in
/// the build log.
func fail(_ message: String) -> Never {
    print("error: \(message)")
    exit(1)
}

/// `SourcePackages` sits at the root of the build's derived data, which is found by walking up from
/// `BUILD_DIR` rather than by pattern-matching the path for a `DerivedData` component: a build invoked
/// with an explicit `-derivedDataPath` need not have one, and matching on the text finds nothing at all
/// for those builds.
func findSourcePackagesPath() -> String? {
    guard let buildDir = ProcessInfo.processInfo.environment["BUILD_DIR"] else { return nil }

    var directory: URL = URL(fileURLWithPath: buildDir).standardizedFileURL

    while directory.path != "/" {
        let candidate: URL = directory.appendingPathComponent("SourcePackages")
        var isDirectory: ObjCBool = false

        if
            FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        {
            return candidate.path
        }

        directory = directory.deletingLastPathComponent()
    }

    return nil
}

guard let sourcePackagesPath: String = findSourcePackagesPath() else {
    fail("No SourcePackages directory above BUILD_DIR (\(ProcessInfo.processInfo.environment["BUILD_DIR"] ?? "unset")); refusing to rewrite \(outputPlistPath)")
}

let packageCheckoutsPath = "\(sourcePackagesPath)/checkouts/"
let packageArtifactsPath = "\(sourcePackagesPath)/artifacts/"

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
    
    /// An empty result is always a broken lookup rather than a project with no dependencies, and writing
    /// it silently replaces the tracked plist with an empty list.
    guard !finalLicenses.isEmpty else {
        fail("No licences matched the \(resolvedPackageNames.count) resolved packages; refusing to rewrite \(outputPath)")
    }

    print("\(finalLicenses.count) being written to plist.")

    finalLicenses.forEach { license in
        plistArray.append([
            "Title": license.title,
            "License": license.licenseContent
        ])
    }

    do {
        let plistData: Data = try PropertyListSerialization.data(fromPropertyList: plistArray, format: .xml, options: 0)
        try plistData.write(to: URL(fileURLWithPath: outputPath))
    }
    catch { fail("Could not write \(outputPath): \(error)") }
}

// Execute the license discovery process
let licenses = findLicenses(in: packageCheckoutsPath) + findLicenses(in: packageArtifactsPath)
let resolvedPackageNames = try findPackageDependencyNames(in: packageResolutionFilePath)

writePlist(licenses: licenses, resolvedPackageNames: resolvedPackageNames, outputPath: outputPlistPath)

print("Licenses generated successfully at \(outputPlistPath)")
