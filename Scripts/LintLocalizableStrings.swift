#!/usr/bin/xcrun --sdk macosx swift

// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// This script is based on https://github.com/ginowu7/CleanSwiftLocalizableExample the main difference
// is canges to the localized usage regex

import Foundation

let fileManager = FileManager.default
let currentPath = (
    ProcessInfo.processInfo.environment["PROJECT_DIR"] ?? fileManager.currentDirectoryPath
)

/// List of files in currentPath - recursive
var pathFiles: [String] = {
    guard
        let enumerator: FileManager.DirectoryEnumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: currentPath),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ),
        let fileUrls: [URL] = enumerator.allObjects as? [URL]
    else { fatalError("Could not locate files in path directory: \(currentPath)") }
    
    return fileUrls
        .filter {
            ((try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == false) && // No directories
            !$0.path.contains("build/") &&                                // Exclude files under the build folder (CI)
            !$0.path.contains("Pods/") &&                                 // Exclude files under the pods folder
            !$0.path.contains(".xcassets") &&                             // Exclude asset bundles
            !$0.path.contains(".app/") &&                                 // Exclude files in the app build directories
            !$0.path.contains(".appex/") &&                               // Exclude files in the extension build directories
            !$0.path.localizedCaseInsensitiveContains("tests/") &&        // Exclude files under test directories
            !$0.path.localizedCaseInsensitiveContains("external/") && (   // Exclude files under external directories
                // Only include relevant files
                $0.path.hasSuffix("Localizable.strings") ||
                NSString(string: $0.path).pathExtension == "swift" ||
                NSString(string: $0.path).pathExtension == "m"
            )
        }
        .map { $0.path }
}()


/// List of localizable files - not including Localizable files in the Pods
var localizableFiles: [String] = {
    return pathFiles.filter { $0.hasSuffix("Localizable.strings") }
}()


/// List of executable files
var executableFiles: [String] = {
    return pathFiles.filter {
        $0.hasSuffix(".swift") ||
        $0.hasSuffix(".m")
    }
}()

/// Reads contents in path
///
/// - Parameter path: path of file
/// - Returns: content in file
func contents(atPath path: String) -> String {
    guard let data = fileManager.contents(atPath: path), let content = String(data: data, encoding: .utf8) else {
        fatalError("Could not read from path: \(path)")
    }
    
    return content
}

/// Returns a list of strings that match regex pattern from content
///
/// - Parameters:
///   - pattern: regex pattern
///   - content: content to match
/// - Returns: list of results
func regexFor(_ pattern: String, content: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
        fatalError("Regex not formatted correctly: \(pattern)")
    }
    
    let matches = regex.matches(in: content, options: [], range: NSRange(location: 0, length: content.utf16.count))
    
    return matches.map {
        guard let range = Range($0.range(at: 0), in: content) else {
            fatalError("Incorrect range match")
        }
        
        return String(content[range])
    }
}

func create() -> [LocalizationStringsFile] {
    return localizableFiles.map(LocalizationStringsFile.init(path:))
}

///
///
/// - Returns: A list of LocalizationCodeFile - contains path of file and all keys in it
func localizedStringsInCode() -> [LocalizationCodeFile] {
    return executableFiles.compactMap {
        let content = contents(atPath: $0)
        // Note: Need to exclude escaped quotation marks from strings
        let matchesOld = regexFor("(?<=NSLocalizedString\\()\\s*\"(?!.*?%d)(.*?)\"", content: content)
        let matchesNew = regexFor("\"(?!.*?%d)([^(\\\")]*?)\"(?=\\s*)(?=\\.localized)", content: content)
        let allMatches = (matchesOld + matchesNew)
        
        return allMatches.isEmpty ? nil : LocalizationCodeFile(path: $0, keys: Set(allMatches))
    }
}

/// Throws error if ALL localizable files does not have matching keys
///
/// - Parameter files: list of localizable files to validate
func validateMatchKeys(_ files: [LocalizationStringsFile]) {
    guard let base = files.first, files.count > 1 else { return }
    
    let files = Array(files.dropFirst())
    
    files.forEach {
        guard let extraKey = Set(base.keys).symmetricDifference($0.keys).first else { return }
        let incorrectFile = $0.keys.contains(extraKey) ? $0 : base
        printPretty("error: Found extra key: \(extraKey) in file: \(incorrectFile.path)")
    }
}

/// Throws error if localizable files are missing keys
///
/// - Parameters:
///   - codeFiles: Array of LocalizationCodeFile
///   - localizationFiles: Array of LocalizableStringFiles
func validateMissingKeys(_ codeFiles: [LocalizationCodeFile], localizationFiles: [LocalizationStringsFile]) {
    guard let baseFile = localizationFiles.first else {
        fatalError("Could not locate base localization file")
    }
    
    let baseKeys = Set(baseFile.keys)
    
    codeFiles.forEach {
        let extraKeys = $0.keys.subtracting(baseKeys)
        if !extraKeys.isEmpty {
            printPretty("error: Found keys in code missing in strings file: \(extraKeys) from \($0.path)")
        }
    }
}

/// Throws warning if keys exist in localizable file but are not being used
///
/// - Parameters:
///   - codeFiles: Array of LocalizationCodeFile
///   - localizationFiles: Array of LocalizableStringFiles
func validateDeadKeys(_ codeFiles: [LocalizationCodeFile], localizationFiles: [LocalizationStringsFile]) {
    guard let baseFile = localizationFiles.first else {
        fatalError("Could not locate base localization file")
    }
    
    let baseKeys: Set<String> = Set(baseFile.keys)
    let allCodeFileKeys: [String] = codeFiles.flatMap { $0.keys }
    let deadKeys: [String] = Array(baseKeys.subtracting(allCodeFileKeys))
        .sorted()
        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
    
    if !deadKeys.isEmpty {
        printPretty("warning: \(deadKeys) - Suggest cleaning dead keys")
    }
}

protocol Pathable {
    var path: String { get }
}

struct LocalizationStringsFile: Pathable {
    let path: String
    let kv: [String: String]
    let duplicates: [(key: String, path: String)]

    var keys: [String] {
        return Array(kv.keys)
    }

    init(path: String) {
        let result = ContentParser.parse(path)
        
        self.path = path
        self.kv = result.kv
        self.duplicates = result.duplicates
    }

    /// Writes back to localizable file with sorted keys and removed whitespaces and new lines
    func cleanWrite() {
        print("------------ Sort and remove whitespaces: \(path) ------------")
        let content = kv.keys.sorted().map { "\($0) = \(kv[$0]!);" }.joined(separator: "\n")
        try! content.write(toFile: path, atomically: true, encoding: .utf8)
    }

}

struct LocalizationCodeFile: Pathable {
    let path: String
    let keys: Set<String>
}

struct ContentParser {

    /// Parses contents of a file to localizable keys and values - Throws error if localizable file have duplicated keys
    ///
    /// - Parameter path: Localizable file paths
    /// - Returns: localizable key and value for content at path
    static func parse(_ path: String) -> (kv: [String: String], duplicates: [(key: String, path: String)]) {
        let content = contents(atPath: path)
        let trimmed = content
            .replacingOccurrences(of: "\n+", with: "", options: .regularExpression, range: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let keys = regexFor("\"([^\"]*?)\"(?= =)", content: trimmed)
        let values = regexFor("(?<== )\"(.*?)\"(?=;)", content: trimmed)
        
        if keys.count != values.count {
            fatalError("Error parsing contents: Make sure all keys and values are in correct format (this could be due to extra spaces between keys and values)")
        }
        
        var duplicates: [(key: String, path: String)] = []
        let kv: [String: String] = zip(keys, values)
            .reduce(into: [:]) { results, keyValue in
                guard results[keyValue.0] == nil else {
                    duplicates.append((keyValue.0, path))
                    return
                }
                
                results[keyValue.0] = keyValue.1
            }
        
        return (kv, duplicates)
    }
}

func printPretty(_ string: String) {
    print(string.replacingOccurrences(of: "\\", with: ""))
}

// MARK: - Processing

let stringFiles: [LocalizationStringsFile] = create()

if !stringFiles.isEmpty {
    print("------------ Found \(stringFiles.count) file(s) - checking for duplicate, extra, missing and dead keys ------------")
    
    stringFiles.forEach { file in
        file.duplicates.forEach { key, path in
            printPretty("error: Found duplicate key: \(key) in file: \(path)")
        }
    }
    
    validateMatchKeys(stringFiles)

    // Note: Uncomment the below file to clean out all comments from the localizable file (we don't want this because comments make it readable...)
    // stringFiles.forEach { $0.cleanWrite() }

    let codeFiles: [LocalizationCodeFile] = localizedStringsInCode()
    validateMissingKeys(codeFiles, localizationFiles: stringFiles)
    validateDeadKeys(codeFiles, localizationFiles: stringFiles)
}

print("------------ Complete ------------")
