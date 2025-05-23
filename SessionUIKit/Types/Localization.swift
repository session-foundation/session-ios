// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

// stringlint:disable

import UIKit

// MARK: - LocalizationHelper

final public class LocalizationHelper: CustomStringConvertible {
    private static let bundle: Bundle = {
        let bundleName = "SessionUIKit"
        
        let candidates: [URL?] = [
            Bundle.main.resourceURL,
            Bundle(for: LocalizationHelper.self).resourceURL,
            Bundle.main.bundleURL
        ]
        
        for candidate in candidates {
            let bundlePath = candidate?.appendingPathComponent(bundleName + ".bundle")
            if let bundle = bundlePath.flatMap(Bundle.init(url:)) {
                return bundle
            }
        }
        
        return Bundle(identifier: "com.loki-project.SessionUIKit")!
    }()
    
    private let template: String
    private var replacements: [String : String] = [:]
    private var numbers: [Int] = []

    // MARK: - Initialization

    public init(template: String) {
        self.template = template
    }

    // MARK: - DSL

    public func put(key: String, value: CustomStringConvertible) -> LocalizationHelper {
        replacements[key] = value.description
        return self
    }
    
    public func putNumber(_ number: Int, index: Int) -> LocalizationHelper {
        self.numbers.insert(number, at: index)
        return self
    }

    public func localized() -> String {
        guard !SNUIKit.shouldShowStringKeys() else {
            return "[\(template)]"
        }
        
        // Use English as the default string if the translation is empty
        let defaultString: String = {
            guard
                let englishPath: String = LocalizationHelper.bundle.path(forResource: "en", ofType: "lproj"),
                let englishBundle: Bundle = Bundle(path: englishPath)
            else { return "" }
            
            return englishBundle.localizedString(forKey: template, value: template, table: nil)
        }()
        
        // If the localized string matches the key provided then the localisation failed
        var localizedString: String = NSLocalizedString(template, bundle: LocalizationHelper.bundle, value: defaultString, comment: "")
        
        // Deal with plurals
        // Note: We have to deal with plurals first, so we can get the correct string
        if !self.numbers.isEmpty {
            localizedString = String(
                format: localizedString,
                locale: .current,
                arguments: self.numbers
            )
        }
        
        for (key, value) in replacements {
            localizedString = localizedString.replacingOccurrences(of: tokenize(key), with: value)
        }
        
        // Replace html tag "<br/>" with "\n"
        localizedString = localizedString.replacingOccurrences(of: "<br/>", with: "\n")

        return localizedString
    }

    // MARK: - Internal functions

    private func tokenize(_ key: String) -> String {
        return "{" + key + "}"
    }

    // MARK: - CustomStringConvertible

    public var description: String {
        // Fallback to the localized
        return self.localized()
    }
}

// MARK: - Convenience

public extension LocalizationHelper {
    func localizedDeformatted() -> String {
        return NSAttributedString(stringWithHTMLTags: localized(), font: .systemFont(ofSize: 14)).string
    }
    
    func localizedFormatted(baseFont: UIFont) -> NSAttributedString {
        return NSAttributedString(stringWithHTMLTags: localized(), font: baseFont)
    }
    
    func localizedFormatted(in view: FontAccessible) -> NSAttributedString {
        return localizedFormatted(baseFont: (view.fontValue ?? .systemFont(ofSize: 14)))
    }
    
    func localizedFormatted(_ font: UIFont = .systemFont(ofSize: 14)) -> NSAttributedString {
        return localizedFormatted(baseFont: font)
    }
}

public extension String {
    func put(key: String, value: CustomStringConvertible) -> LocalizationHelper {
        return LocalizationHelper(template: self).put(key: key, value: value)
    }
    
    func putNumber(_ number: Int, index: Int = 0) -> LocalizationHelper {
        return LocalizationHelper(template: self).putNumber(number, index: index)
    }

    func localized() -> String {
        return LocalizationHelper(template: self).localized()
    }
    
    func localizedFormatted(baseFont: UIFont) -> NSAttributedString {
        return LocalizationHelper(template: self).localizedFormatted(baseFont: baseFont)
    }
    
    func localizedFormatted(in view: FontAccessible) -> NSAttributedString {
        return LocalizationHelper(template: self).localizedFormatted(in: view)
    }
    
    func localizedDeformatted() -> String {
        return LocalizationHelper(template: self).localizedDeformatted()
    }
}
