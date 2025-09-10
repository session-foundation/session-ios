// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

public protocol ArgumentDescribing {
    var summary: String? { get }
}

internal func summary(for argument: Any?) -> String {
    guard let argument: Any = argument else { return "nil" }
    
    if isAnyValue(argument) {
        return "<any \(String(describing: type(of: argument)))>"
    }
    
    /// Then handle any `ArgumentDescribing` values
    if let customSummary: String = (argument as? ArgumentDescribing)?.summary {
        return customSummary
    }
    
    /// Finally try to process standard types
    switch argument {
        case let string as String: return string.debugDescription
        case let array as [Any]: return "[\(array.map { summary(for: $0) }.joined(separator: ", "))]"
            
        case let dict as [String: Any]:
            if dict.isEmpty { return "[:]" }
            
            let sortedValues: [String] = dict
                .map { key, value in "\(summary(for: key)):\(summary(for: value))" }
                .sorted()
            return "[\(sortedValues.joined(separator: ", "))]"
            
        case let data as Data: return "Data(base64Encoded: \(data.base64EncodedString()))"
        default: return recursiveSummary(for: argument)
    }
}

private func isAnyValue(_ value: Any) -> Bool {
    func open<T: Mocked & Equatable>(value: T) -> Bool {
        return value == T.any
    }
    
    if let mockedEquatableValue = value as? any (Mocked & Equatable) {
        return open(value: mockedEquatableValue)
    }
    
    return false
}

private func recursiveSummary(for subject: Any) -> String {
    let mirror: Mirror = Mirror(reflecting: subject)
    let typeName: String = String(describing: Swift.type(of: subject))

    /// Fall back to a simple description for types with no custom representation (eg. primitives)
    guard let displayStyle: Mirror.DisplayStyle = mirror.displayStyle else {
        return String(describing: subject)
    }

    switch displayStyle {
        case .struct, .class:
            /// If there are no properties, just print the type name
            guard !mirror.children.isEmpty else { return typeName }
            
            let properties: String = mirror.children
                .compactMap { child -> String? in
                    guard let label: String = child.label else {
                        return nil
                    }
                    
                    return "\(label): \(summary(for: child.value))"
                }
                .sorted()
                .joined(separator: ", ")
            
            return "\(typeName)(\(properties))"
            
        case .enum:
            // Handle associated values first
            if let child: Mirror.Child = mirror.children.first {
                if let label: String = child.label {
                    /// Enum case with one or more named associated values
                    let properties: String = mirror.children
                        .compactMap { child -> String? in
                            guard let label: String = child.label else {
                                return nil
                            }
                            
                            return "\(label): \(summary(for: child.value))"
                        }
                        .sorted()
                        .joined(separator: ", ")
                    
                    return ".\(label)(\(properties))"
                }
                
                /// Enum case with one or more unnamed associated values
                let values: String = mirror.children
                    .map { summary(for: $0.value) }
                    .joined(separator: ", ")
                
               return ".\(mirror.subjectType).\(subject)(\(values))"
            }
            
            /// Simple enum case with no associated value
            return ".\(subject)"
            
        case .tuple:
            let elements: String = mirror.children
                .map { child -> String in
                    if let label: String = child.label {
                        return "\(label): \(summary(for: child.value))"
                    }
                    
                    return summary(for: child.value)
                }
                .joined(separator: ", ")
            
            return "(\(elements))"
            
        /// For other collections like Set, fall back to the default but sort any dictionary content by keys
        default: return sortDictionariesInReflectedString(String(describing: subject))
    }
}

private func sortDictionariesInReflectedString(_ input: String) -> String {
    // Regular expression to match the headers dictionary
    let pattern = "\\[(.+?)\\]"
    let regex = try! NSRegularExpression(pattern: pattern, options: [])
    
    var result = ""
    var lastRange = input.startIndex..<input.startIndex
    
    regex.enumerateMatches(in: input, options: [], range: NSRange(input.startIndex..<input.endIndex, in: input)) { match, _, _ in
        guard let match = match, let range = Range(match.range, in: input) else { return }
        
        // Append the text before this match
        result += input[lastRange.upperBound..<range.lowerBound]
        
        // Extract the dictionary string
        if let innerRange = Range(match.range(at: 1), in: input) {
            let dictionaryString = String(input[innerRange])
            let sortedDictionaryString = sortDictionaryString(dictionaryString)
            result += (sortedDictionaryString.isEmpty ? "[:]" : "[\(sortedDictionaryString)]")
        } else {
            // If we can't extract the inner part, just use the original matched text
            result += input[range]
        }
        
        lastRange = range
    }

    // Append any remaining text after the last match
    result += input[lastRange.upperBound..<input.endIndex]
    
    return result
}

private func sortDictionaryString(_ dictionaryString: String) -> String {
    var pairs: [(String, String)] = []
    var currentKey = ""
    var currentValue = ""
    var inQuotes = false
    var parsingKey = true
    var nestedLevel = 0
    
    for char in dictionaryString {
        switch char {
            case "\"":
                inQuotes.toggle()
                if nestedLevel > 0 {
                    currentKey.append(char)
                    continue
                }
            
            case ":":
                if !inQuotes && nestedLevel == 0 {
                    parsingKey = false
                    continue
                }
            
            case ",":
                if !inQuotes && nestedLevel == 0 {
                    pairs.append((currentKey.trimmingCharacters(in: .whitespaces), currentValue.trimmingCharacters(in: .whitespaces)))
                    currentKey = ""
                    currentValue = ""
                    parsingKey = true
                    continue
                }
            
            case "[", "{": nestedLevel += (parsingKey ? 0 : 1)
            case "]", "}": nestedLevel -= (parsingKey ? 0 : 1)
            default: break
        }
        
        switch parsingKey {
            case true: currentKey.append(char)
            case false: currentValue.append(char)
        }
    }
    
    // Add the last pair if exists
    if !currentKey.isEmpty || !currentValue.isEmpty {
        pairs.append((currentKey.trimmingCharacters(in: .whitespaces), currentValue.trimmingCharacters(in: .whitespaces)))
    }
    
    // Sort pairs by key
    let sortedPairs = pairs.sorted { $0.0 < $1.0 }
    
    // Join sorted pairs back into a string
    return sortedPairs.map { "\($0): \($1)" }.joined(separator: ", ")
}
