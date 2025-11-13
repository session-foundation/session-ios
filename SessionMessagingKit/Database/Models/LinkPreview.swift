// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import UniformTypeIdentifiers
import GRDB
import SessionUIKit
import SessionUtilitiesKit
import SessionNetworkingKit

public struct LinkPreview: Sendable, Codable, Equatable, Hashable, FetchableRecord, PersistableRecord, TableRecord, ColumnExpressible {
    public static var databaseTableName: String { "linkPreview" }
    
    /// We want to cache url previews to the nearest 100,000 seconds (~28 hours - simpler than 86,400) to ensure the user isn't shown a preview that is too stale
    public static let timstampResolution: Double = 100000
    internal static let maxImageDimension: CGFloat = 600
    
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case url
        case timestamp
        case variant
        case title
        case attachmentId
    }
    
    public enum Variant: Int, Sendable, Codable, Hashable, CaseIterable, DatabaseValueConvertible {
        case standard
        case openGroupInvitation
    }
    
    /// The url for the link preview
    public let url: String
    
    /// The number of seconds since epoch rounded down to the nearest 100,000 seconds (~day) - This
    /// allows us to optimise against duplicate urls without having "stale" data last too long
    public let timestamp: TimeInterval
    
    /// The type of link preview
    public let variant: Variant
    
    /// The title for the link
    public let title: String?
    
    /// The id for the attachment for the link preview image
    public let attachmentId: String?
    
    // MARK: - Initialization
    
    public init(
        url: String,
        timestamp: TimeInterval? = nil,
        variant: Variant = .standard,
        title: String?,
        attachmentId: String? = nil,
        using dependencies: Dependencies
    ) {
        self.url = url
        self.timestamp = (timestamp ?? LinkPreview.timestampFor(
            sentTimestampMs: dependencies[cache: .snodeAPI].currentOffsetTimestampMs()  // Default to now
        ))
        self.variant = variant
        self.title = title
        self.attachmentId = attachmentId
    }
}

// MARK: - Protobuf

public extension LinkPreview {
    init?(
        _ db: ObservingDatabase,
        linkPreview: VisibleMessage.VMLinkPreview,
        sentTimestampMs: UInt64
    ) throws {
        guard LinkPreview.isValidLinkUrl(linkPreview.url) else { throw LinkPreviewError.invalidInput }
        
        // Try to get an existing link preview first
        let timestamp: TimeInterval = LinkPreview.timestampFor(sentTimestampMs: sentTimestampMs)
        let maybeLinkPreview: LinkPreview? = try? LinkPreview
            .filter(LinkPreview.Columns.url == linkPreview.url)
            .filter(LinkPreview.Columns.timestamp == timestamp)
            .fetchOne(db)
        
        if let linkPreview: LinkPreview = maybeLinkPreview {
            self = linkPreview
            return
        }
        
        self.url = linkPreview.url
        self.timestamp = timestamp
        self.variant = .standard
        self.title = LinkPreview.normalizeTitle(title: linkPreview.title)
        
        if let attachment: Attachment = linkPreview.nonInsertedAttachment {
            try attachment.insert(db)
            
            self.attachmentId = attachment.id
        }
        else {
            self.attachmentId = nil
        }
        
        // Make sure the quote is valid before completing
        guard self.title != nil || self.attachmentId != nil else { throw LinkPreviewError.invalidInput }
    }
}

// MARK: - Convenience

public extension LinkPreview {
    struct URLMatchResult {
        let urlString: String
        let matchRange: NSRange
    }
    
    static func timestampFor(sentTimestampMs: UInt64) -> TimeInterval {
        // We want to round the timestamp down to the nearest 100,000 seconds (~28 hours - simpler
        // than 86,400) to optimise LinkPreview storage without having too stale data
        return (floor(Double(sentTimestampMs) / 1000 / LinkPreview.timstampResolution) * LinkPreview.timstampResolution)
    }
    
    static func prepareAttachmentIfPossible(
        urlString: String,
        imageSource: ImageDataManager.DataSource?,
        using dependencies: Dependencies
    ) async throws -> PreparedAttachment? {
        guard let imageSource: ImageDataManager.DataSource = imageSource, imageSource.contentExists else {
            return nil
        }
        
        let pendingAttachment: PendingAttachment = PendingAttachment(
            source: .media(imageSource),
            using: dependencies
        )
        let targetFormat: PendingAttachment.ConversionFormat = (dependencies[feature: .usePngInsteadOfWebPForFallbackImageType] ?
            .png(maxDimension: LinkPreview.maxImageDimension) : .webPLossy(maxDimension: LinkPreview.maxImageDimension)
        )
        
        return try await pendingAttachment.prepare(
            operations: [
                .convert(to: targetFormat),
                .stripImageMetadata
            ],
            /// We only call `prepareAttachmentIfPossible` before sending so always store at the pending upload path
            storeAtPendingAttachmentUploadPath: true,
            using: dependencies
        )
    }
    
    static func isValidLinkUrl(_ urlString: String) -> Bool {
        return URL(string: urlString) != nil
    }
    
    static func allPreviewUrls(forMessageBodyText body: String) -> [String] {
        return allPreviewUrlMatches(forMessageBodyText: body).map { $0.urlString }
    }
    
    // MARK: - Private Methods
    
    private static func allPreviewUrlMatches(forMessageBodyText body: String) -> [URLMatchResult] {
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
            
            if isValidLinkUrl(urlString) {
                let matchResult = URLMatchResult(urlString: urlString, matchRange: match.range)
                urlMatches.append(matchResult)
            }
        }
        
        return urlMatches
    }
    
    fileprivate static func normalizeTitle(title: String?) -> String? {
        guard var result: String = title, !result.isEmpty else { return nil }
        
        // Truncate title after 2 lines of text.
        let maxLineCount = 2
        var components = result.components(separatedBy: .newlines)
        
        if components.count > maxLineCount {
            components = Array(components[0..<maxLineCount])
            result =  components.joined(separator: "\n")
        }
        
        let maxCharacterCount = 2048
        if result.count > maxCharacterCount {
            let endIndex = result.index(result.startIndex, offsetBy: maxCharacterCount)
            result = String(result[..<endIndex])
        }
        
        return result.filteredForDisplay
    }
    
    // MARK: - Text Parsing

    @ThreadSafeObject private static var previewUrlCache: LRUCache<String, String> = LRUCache()

    static func previewUrl(
        for body: String?,
        selectedRange: NSRange? = nil,
        using dependencies: Dependencies
    ) -> String? {
        guard dependencies.mutate(cache: .libSession, { $0.get(.areLinkPreviewsEnabled) }) else { return nil }
        guard let body: String = body else { return nil }

        if let cachedUrl = _previewUrlCache.performMap({ $0.get(key: body) }) {
            guard cachedUrl.count > 0 else {
                return nil
            }
            
            return cachedUrl
        }
        
        let previewUrlMatches: [URLMatchResult] = allPreviewUrlMatches(forMessageBodyText: body)
        
        guard let urlMatch: URLMatchResult = previewUrlMatches.first else {
            // Use empty string to indicate "no preview URL" in the cache.
            _previewUrlCache.performUpdate { $0.settingObject("", forKey: body) }
            return nil
        }

        if let selectedRange: NSRange = selectedRange {
            let cursorAtEndOfMatch: Bool = (
                (urlMatch.matchRange.location + urlMatch.matchRange.length) == selectedRange.location
            )
            
            if selectedRange.location != body.count, (urlMatch.matchRange.intersection(selectedRange) != nil || cursorAtEndOfMatch) {
                // we don't want to cache the result here, as we want to fetch the link preview
                // if the user moves the cursor.
                return nil
            }
        }

        _previewUrlCache.performUpdate {
            $0.settingObject(urlMatch.urlString, forKey: body)
        }
        
        return urlMatch.urlString
    }
}

// MARK: - Drafts

public extension LinkPreview {
    private struct Contents {
        public var title: String?
        public var imageUrl: String?

        public init(title: String?, imageUrl: String? = nil) {
            self.title = title
            self.imageUrl = imageUrl
        }
    }
    
    private static let serialQueue = DispatchQueue(label: "org.signal.linkPreview")
    
    // This cache should only be accessed on serialQueue.
    //
    // We should only maintain a "cache" of the last known draft.
    private static var linkPreviewDraftCache: LinkPreviewDraft?
    
    // Twitter doesn't return OpenGraph tags to Signal
    // `curl -A Signal "https://twitter.com/signalapp/status/1280166087577997312?s=20"`
    // If this ever changes, we can switch back to our default User-Agent
    private static let userAgentString = "WhatsApp"
    
    private static func cachedLinkPreview(forPreviewUrl previewUrl: String) -> LinkPreviewDraft? {
        return serialQueue.sync {
            guard let linkPreviewDraft = linkPreviewDraftCache,
                linkPreviewDraft.urlString == previewUrl else {
                return nil
            }
            return linkPreviewDraft
        }
    }
    
    private static func setCachedLinkPreview(
        _ linkPreviewDraft: LinkPreviewDraft,
        forPreviewUrl previewUrl: String,
        using dependencies: Dependencies
    ) {
        assert(previewUrl == linkPreviewDraft.urlString)

        // Exit early if link previews are not enabled in order to avoid
        // tainting the cache.
        guard dependencies.mutate(cache: .libSession, { $0.get(.areLinkPreviewsEnabled) }) else { return }

        serialQueue.sync {
            linkPreviewDraftCache = linkPreviewDraft
        }
    }
    
    static func tryToBuildPreviewInfo(
        previewUrl: String?,
        skipImageDownload: Bool,
        using dependencies: Dependencies
    ) async throws -> LinkPreviewDraft {
        guard dependencies.mutate(cache: .libSession, { $0.get(.areLinkPreviewsEnabled) }) else {
            throw LinkPreviewError.featureDisabled
        }
        
        // Force the url to lowercase to ensure we casing doesn't result in redownloading the
        // details
        guard let previewUrl: String = previewUrl?.lowercased() else {
            throw LinkPreviewError.invalidInput
        }
        
        if let cachedInfo = cachedLinkPreview(forPreviewUrl: previewUrl) {
            return cachedInfo
        }
        
        let (data, response) = try await downloadLink(url: previewUrl)
        try Task.checkCancellation()    /// No use trying to parse and potentially download an image if the task was cancelled
        
        let linkPreviewDraft: LinkPreviewDraft = try await parseLinkDataAndBuildDraft(
            linkData: data,
            response: response,
            linkUrlString: previewUrl,
            skipImageDownload: skipImageDownload,
            using: dependencies
        )
        
        guard linkPreviewDraft.isValid() else { throw LinkPreviewError.noPreview }
                
        setCachedLinkPreview(linkPreviewDraft, forPreviewUrl: previewUrl, using: dependencies)
        
        return linkPreviewDraft
    }

    private static func downloadLink(
        url urlString: String,
        remainingRetries: UInt = 3
    ) async throws -> (Data, URLResponse) {
        Log.verbose("[LinkPreview] Download url: \(urlString)")

        // let sessionConfiguration = ContentProxy.sessionConfiguration() // Loki: Signal's proxy appears to have been banned by YouTube
        let sessionConfiguration = URLSessionConfiguration.ephemeral

        // Don't use any caching to protect privacy of these requests.
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.urlCache = nil
        
        guard
            var request: URLRequest = URL(string: urlString).map({ URLRequest(url: $0) }),
            request.url?.scheme != nil,
            (request.url?.host ?? "").isEmpty == false,
            ContentProxy.configureProxiedRequest(request: &request)
        else { throw LinkPreviewError.assertionFailure }
        
        request.setValue(self.userAgentString, forHTTPHeaderField: "User-Agent") // Set a fake value

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
            guard isRetryable(error: error), remainingRetries > 0 else {
                throw LinkPreviewError.couldNotDownload
            }
            
            return try await LinkPreview.downloadLink(
                url: urlString,
                remainingRetries: (remainingRetries - 1)
            )
        }
    }
    
    private static func parseLinkDataAndBuildDraft(
        linkData: Data,
        response: URLResponse,
        linkUrlString: String,
        skipImageDownload: Bool,
        using dependencies: Dependencies
    ) async throws -> LinkPreviewDraft {
        let contents: LinkPreview.Contents = try parse(linkData: linkData, response: response)
        let title: String? = contents.title
        
        /// If we don't want to download the image then just return the non-image content
        guard !skipImageDownload else {
            return LinkPreviewDraft(urlString: linkUrlString, title: title)
        }
        
        do {
            /// If the image isn't valid then just return the non-image content
            let imageUrl: URL = try contents.imageUrl.map({ URL(string: $0) }) ?? {
                throw LinkPreviewError.invalidContent
            }()
            let imageSource: ImageDataManager.DataSource = try await downloadImage(
                url: imageUrl,
                using: dependencies
            )
            
            return LinkPreviewDraft(urlString: linkUrlString, title: title, imageSource: imageSource)
        }
        catch {
            return LinkPreviewDraft(urlString: linkUrlString, title: title)
        }
    }
    
    private static func parse(linkData: Data, response: URLResponse) throws -> Contents {
        guard let linkText = String(bytes: linkData, encoding: response.stringEncoding ?? .utf8) else {
            Log.verbose("[LinkPreview] Could not parse link text.")
            throw LinkPreviewError.invalidInput
        }
        
        let content = HTMLMetadata.construct(parsing: linkText)

        var title: String?
        let rawTitle = content.ogTitle ?? content.titleTag
        if
            let decodedTitle: String = decodeHTMLEntities(inString: rawTitle ?? ""),
            let normalizedTitle: String = LinkPreview.normalizeTitle(title: decodedTitle),
            normalizedTitle.count > 0
        {
            title = normalizedTitle
        }

        Log.verbose("[LinkPreview] Title: \(String(describing: title))")

        guard let rawImageUrlString = content.ogImageUrlString ?? content.faviconUrlString else {
            return Contents(title: title)
        }
        guard let imageUrlString = decodeHTMLEntities(inString: rawImageUrlString)?.stripped else {
            return Contents(title: title)
        }

        return Contents(title: title, imageUrl: imageUrlString)
    }
    
    private static func downloadImage(
        url: URL,
        using dependencies: Dependencies
    ) async throws -> ImageDataManager.DataSource {
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
    
    private static func isRetryable(error: Error) -> Bool {
        if (error as NSError).domain == kCFErrorDomainCFNetwork as String {
            // Network failures are retried.
            return true
        }
        
        return false
    }
    
    private static func fileExtension(forImageUrl urlString: String) -> String? {
        guard let imageUrl = URL(string: urlString) else { return nil }
        
        let imageFilename = imageUrl.lastPathComponent
        let imageFileExtension = (imageFilename as NSString).pathExtension.lowercased()
        
        guard imageFileExtension.count > 0 else {
            // TODO: For those links don't have a file extension, we should figure out a way to know the image mime type
            return UTType.fileExtensionDefaultImage
        }
        
        return imageFileExtension
    }
    
    private static func decodeHTMLEntities(inString value: String) -> String? {
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
}
