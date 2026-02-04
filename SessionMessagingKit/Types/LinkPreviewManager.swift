// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUIKit
import SessionNetworkingKit
import SessionUtilitiesKit

// MARK: - Singleton

public extension Singleton {
    static let linkPreviewManager: SingletonConfig<LinkPreviewManagerType> = Dependencies.create(
        identifier: "linkPreviewManager",
        createInstance: { dependencies, _ in LinkPreviewManager(using: dependencies) }
    )
}

// MARK: - Log.Category

public extension Log.Category {
    static let linkPreview: Log.Category = .create("LinkPreview", defaultLevel: .info)
}

// MARK: - LinkPreviewManager

public actor LinkPreviewManager: LinkPreviewManagerType {
    /// Twitter doesn't return OpenGraph tags to Signal
    /// `curl -A Signal "https://twitter.com/signalapp/status/1280166087577997312?s=20"`
    /// If this ever changes, we can switch back to our default User-Agent
    private static let userAgentString: String = "WhatsApp" // strinlint:ignore
    
    private nonisolated let dependencies: Dependencies
    private let urlMatchCache: StringCache = StringCache(
        totalCostLimit: 5 * 1024 * 1024 /// Max 5MB of url match data
    )
    private let metadataCache: StringCache = StringCache(
        totalCostLimit: 5 * 1024 * 1024 /// Max 5MB of url metadata
    )
    
    public var areLinkPreviewsEnabled: Bool {
        get async {
            dependencies.mutate(cache: .libSession) { cache in
                cache.get(.areLinkPreviewsEnabled)
            }
        }
    }
    public var hasSeenLinkPreviewSuggestion: Bool {
        get async { dependencies[defaults: .standard, key: .hasSeenLinkPreviewSuggestion] }
    }
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
    }
    
    // MARK: - Functions
    
    public func setHasSeenLinkPreviewSuggestion(_ value: Bool) async {
        dependencies[defaults: .standard, key: .hasSeenLinkPreviewSuggestion] = value
    }
    
    public func allPreviewUrls(forMessageBodyText body: String) async -> [String] {
        return allPreviewUrlMatches(forMessageBodyText: body).map { $0.urlString }
    }
    
    public func previewUrl(for text: String?, selectedRange: NSRange?) async -> String? {
        guard let text: String = text, await areLinkPreviewsEnabled else { return nil }

        if let cachedUrl: String = urlMatchCache.object(forKey: text) {
            guard cachedUrl.count > 0 else {
                return nil
            }
            
            return cachedUrl
        }
        
        let previewUrlMatches: [URLMatchResult] = allPreviewUrlMatches(forMessageBodyText: text)
        
        guard let urlMatch: URLMatchResult = previewUrlMatches.first else {
            /// Use empty string to indicate "no preview URL" in the cache.
            urlMatchCache.setObject("", forKey: text)
            return nil
        }

        if let selectedRange: NSRange = selectedRange {
            let cursorAtEndOfMatch: Bool = (
                (urlMatch.matchRange.location + urlMatch.matchRange.length) == selectedRange.location
            )
            
            if selectedRange.location != text.count, (urlMatch.matchRange.intersection(selectedRange) != nil || cursorAtEndOfMatch) {
                // we don't want to cache the result here, as we want to fetch the link preview
                // if the user moves the cursor.
                return nil
            }
        }
        
        urlMatchCache.setObject(urlMatch.urlString, forKey: text)
        return urlMatch.urlString
    }
    
    public func ensureLinkPreviewsEnabled() async throws {
        if await !areLinkPreviewsEnabled {
            throw LinkPreviewError.featureDisabled
        }
    }
    
    public func tryToBuildPreviewInfo(
        previewUrl: String,
        skipImageDownload: Bool
    ) async throws -> LinkPreviewViewModel {
        try await ensureLinkPreviewsEnabled()
        
        /// Force the url to lowercase to ensure we casing doesn't result in redownloading the details
        let metadata: HTMLMetadata
        
        /// Check if we have an in-memory cache of the metadata (no point downloading it again if so)
        if
            let cachedMetadataJson: String = metadataCache.object(forKey: previewUrl),
            let cachedMetadataJsonData: Data = cachedMetadataJson.data(using: .utf8),
            let cachedMetadata: HTMLMetadata = try? JSONDecoder(using: dependencies)
                .decode(HTMLMetadata.self, from: cachedMetadataJsonData)
        {
            metadata = cachedMetadata
        }
        else {
            let (data, response) = try await downloadLink(url: previewUrl)
            try Task.checkCancellation()    /// No use trying to parse and potentially download an image if the task was cancelled
            
            guard let rawHTML: String = String(bytes: data, encoding: response.stringEncoding ?? .utf8) else {
                Log.verbose(.linkPreview, "Could not parse link text")
                throw LinkPreviewError.invalidInput
            }
            
            metadata = HTMLMetadata.construct(parsing: rawHTML)
        }
        
        /// Parse the `metadata` and construct a draft
        let title: String? = {
            let rawTitle: String? = (metadata.ogTitle ?? metadata.titleTag)
            
            guard
                let decodedTitle: String = decodeHTMLEntities(inString: rawTitle ?? ""),
                let normalizedTitle: String = LinkPreviewManager.normalizeTitle(title: decodedTitle),
                normalizedTitle.count > 0
            else { return nil }
            
            return normalizedTitle
        }()
        let imageUrlString: String? = {
            guard
                let rawImageUrlString: String = (metadata.ogImageUrlString ?? metadata.faviconUrlString),
                let imageUrlString: String = decodeHTMLEntities(inString: rawImageUrlString)?.stripped,
                imageUrlString.count > 0
            else { return nil }
            
            return imageUrlString
        }()
        
        Log.verbose(.linkPreview, "Title: \(String(describing: title)), URL: \(String(describing: imageUrlString))")
        
        let viewModel: LinkPreviewViewModel
        
        /// If we don't want to download the image, or the imageUrl isn't valid then just return the non-image content
        if !skipImageDownload, let imageUrl: URL = imageUrlString.map({ URL(string: $0) }) {
            do {
                // FIXME: Would be nice to check if we already have this image downloaded (and to use that one instead)
                let imageSource: ImageDataManager.DataSource = try await downloadImage(url: imageUrl)
                viewModel = LinkPreviewViewModel(
                    state: .draft,
                    urlString: previewUrl,
                    title: title,
                    imageSource: imageSource
                )
            }
            catch {
                viewModel =  LinkPreviewViewModel(
                    state: .draft,
                    urlString: previewUrl,
                    title: title
                )
            }
        }
        else {
            viewModel =  LinkPreviewViewModel(
                state: .draft,
                urlString: previewUrl,
                title: title
            )
        }
        
        guard viewModel.isValid else { throw LinkPreviewError.noPreview }

        /// Cache the metadata
        if
            let metadataJson: Data = try? JSONEncoder(using: dependencies).encode(metadata),
            let metadataJsonString: String = String(data: metadataJson, encoding: .utf8)
        {
            metadataCache.setObject(metadataJsonString, forKey: previewUrl)
        }
        
        return viewModel
    }
    
    // MARK: - Private Methods
    
    private struct URLMatchResult {
        let urlString: String
        let matchRange: NSRange
    }
    
    private func allPreviewUrlMatches(forMessageBodyText body: String) -> [URLMatchResult] {
        let detector: NSDataDetector
        do {
            detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        }
        catch {
            return []
        }

        var urlMatches: [URLMatchResult] = []
        let matches = detector.matches(in: body, options: [], range: NSRange(location: 0, length: body.count))
        for match in matches {
            guard let matchURL = match.url else { continue }
            
            // If the URL entered didn't have a scheme it will default to 'http', we want to catch this and
            // set the scheme to 'https' instead as we don't load previews for 'http' so this will result
            // in more previews actually getting loaded without forcing the user to enter 'https://' before
            // every URL they enter
            let urlString: String = (matchURL.absoluteString == "http://\(body)" ?
                "https://\(body)" :
                matchURL.absoluteString
            )
            
            if LinkPreviewManager.isValidLinkUrl(urlString) {
                let matchResult = URLMatchResult(urlString: urlString, matchRange: match.range)
                urlMatches.append(matchResult)
            }
        }
        
        return urlMatches
    }
    
    // stringlint:ignore_contents
    private func downloadLink(
        url urlString: String,
        remainingRetries: UInt = 3
    ) async throws -> (Data, URLResponse) {
        /// We only load Link Previews for HTTPS urls so append an explanation for not
        let httpsScheme: String = "https"

        guard URLComponents(string: urlString)?.scheme?.lowercased() == httpsScheme else {
            throw LinkPreviewError.insecureLink
        }

        Log.verbose(.linkPreview, "Download url: \(urlString)")
        
        /// Don't use any caching to protect privacy of these requests
        let sessionConfiguration: URLSessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.urlCache = nil
        
        guard
            var request: URLRequest = URL(string: urlString).map({ URLRequest(url: $0) }),
            request.url?.scheme != nil,
            (request.url?.host ?? "").isEmpty == false,
            ContentProxy.configureProxiedRequest(request: &request)
        else { throw LinkPreviewError.assertionFailure }
        
        request.setValue(LinkPreviewManager.userAgentString, forHTTPHeaderField: "User-Agent") /// Set a fake value

        let session: URLSession = URLSession(configuration: sessionConfiguration)
        
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let urlResponse: HTTPURLResponse = response as? HTTPURLResponse else {
                throw LinkPreviewError.assertionFailure
            }
            
            if let contentType: String = urlResponse.allHeaderFields["Content-Type"] as? String {
                guard contentType.lowercased().hasPrefix("text/") else {
                    throw LinkPreviewError.invalidContent
                }
            }
            
            guard data.count > 0 else { throw LinkPreviewError.invalidContent }
            
            return (data, response)
        }
        catch {
            /// Network failures are retried.
            guard (error as NSError).domain == kCFErrorDomainCFNetwork as String, remainingRetries > 0 else {
                throw LinkPreviewError.couldNotDownload
            }
            
            return try await downloadLink(
                url: urlString,
                remainingRetries: (remainingRetries - 1)
            )
        }
    }
    
    private func downloadImage(url: URL) async throws -> ImageDataManager.DataSource {
        guard let assetDescription: ProxiedContentAssetDescription = ProxiedContentAssetDescription(
            url: url as NSURL
        ) else { throw LinkPreviewError.invalidInput }
        
        do {
            let asset: ProxiedContentAsset = try await dependencies[singleton: .proxiedContentDownloader]
                .requestAsset(
                    assetDescription: assetDescription,
                    priority: .high,
                    shouldIgnoreSignalProxy: true
                )
            let pendingAttachment: PendingAttachment = PendingAttachment(
                source: .media(.url(URL(fileURLWithPath: asset.filePath))),
                using: dependencies
            )
            let preparedAttachment: PreparedAttachment = try await pendingAttachment.prepare(
                operations: [.convert(to: .webPLossy(maxDimension: 1024))],
                using: dependencies
            )
            
            return .url(URL(fileURLWithPath: preparedAttachment.filePath))
        }
        catch { throw LinkPreviewError.couldNotDownload }
    }
    
    private func decodeHTMLEntities(inString value: String) -> String? {
        guard let data = value.data(using: .utf8) else { return nil }

        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]

        guard let attributedString = try? NSAttributedString(data: data, options: options, documentAttributes: nil) else {
            return nil
        }

        return attributedString.string
    }
    
    public static func normalizeTitle(title: String?) -> String? {
        guard var result: String = title, !result.isEmpty else { return nil }
        
        /// Truncate title after 2 lines of text
        let maxLineCount: Int = 2
        var components: [String] = result.components(separatedBy: .newlines)
        
        if components.count > maxLineCount {
            components = Array(components[0..<maxLineCount])
            result = components.joined(separator: "\n")
        }
        
        let maxCharacterCount: Int = 2048
        if result.count > maxCharacterCount {
            let endIndex = result.index(result.startIndex, offsetBy: maxCharacterCount)
            result = String(result[..<endIndex])
        }
        
        return result.filteredForDisplay
    }
}
