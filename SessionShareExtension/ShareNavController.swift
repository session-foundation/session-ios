// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import AVFoundation
import Combine
import CoreServices
import UniformTypeIdentifiers
import SignalUtilitiesKit
import SessionUIKit
import SessionNetworkingKit
import SessionUtilitiesKit
import SessionMessagingKit

final class ShareNavController: UINavigationController {
    @MainActor public static var pendingAttachments: CurrentValueAsyncStream<[PendingAttachment]?> = CurrentValueAsyncStream(nil)
    
    /// The `ShareNavController` is initialized from a storyboard so we need to manually initialize this
    private let dependencies: Dependencies = Dependencies.createEmpty()
    private var processPendingAttachmentsTask: Task<Void, Never>?
    
    // MARK: - Error
    
    enum ShareViewControllerError: Error {
        case assertionError(description: String)
        case unsupportedMedia
        case notRegistered
        case obsoleteShare
    }
    
    // MARK: - Lifecycle
    
    override func loadView() {
        super.loadView()
        
        view.themeBackgroundColor = .backgroundPrimary

        /// This should be the first thing we do (Note: If you leave the share context and return to it the context will already exist, trying
        /// to override it results in the share context crashing so ensure it doesn't exist first)
        if !dependencies.has(singleton: .appContext) {
            dependencies.set(singleton: .appContext, to: ShareAppExtensionContext(rootViewController: self, using: dependencies))
            Dependencies.setIsRTLRetriever(requiresMainThread: false) { ShareAppExtensionContext.determineDeviceRTL() }
        }

        guard !SNUtilitiesKit.isRunningTests else { return }
        
        dependencies.warmCache(cache: .appVersion)

        AppSetup.setupEnvironment(
            appSpecificBlock: { [dependencies] in
                // stringlint:ignore_start
                if !Log.loggerExists(withPrefix: "SessionShareExtension") {
                    Log.setup(with: Logger(
                        primaryPrefix: "SessionShareExtension",
                        customDirectory: "\(dependencies[singleton: .fileManager].appSharedDataDirectoryPath)/Logs/ShareExtension",
                        using: dependencies
                    ))
                    LibSession.clearLoggers()
                    LibSession.setupLogger(using: dependencies)
                }
                // stringlint:ignore_stop
                
                // Setup LibSession
                dependencies.warmCache(cache: .libSessionNetwork)
                
                // Configure the different targets
                SNUtilitiesKit.configure(
                    networkMaxFileSize: Network.maxFileSize,
                    maxValidImageDimention: ImageDataManager.DataSource.maxValidDimension,
                    using: dependencies
                )
                SNMessagingKit.configure(using: dependencies)
            },
            migrationsCompletion: { [weak self, dependencies] result in
                switch result {
                    case .failure: Log.error("Failed to complete migrations")
                    case .success:
                        DispatchQueue.main.async {
                            /// Because the `SessionUIKit` target doesn't depend on the `SessionUtilitiesKit` dependency (it shouldn't
                            /// need to since it should just be UI) but since the theme settings are stored in the database we need to pass these through
                            /// to `SessionUIKit` and expose a mechanism to save updated settings - this is done here (once the migrations complete)
                            SNUIKit.configure(
                                with: SAESNUIKitConfig(using: dependencies),
                                themeSettings: dependencies.mutate(cache: .libSession) { cache -> ThemeSettings in
                                    (
                                        cache.get(.theme),
                                        cache.get(.themePrimaryColor),
                                        cache.get(.themeMatchSystemDayNightCycle)
                                    )
                                }
                            )
                            
                            let maybeUserMetadata: ExtensionHelper.UserMetadata? = dependencies[singleton: .extensionHelper]
                                .loadUserMetadata()
                            
                            self?.versionMigrationsDidComplete(userMetadata: maybeUserMetadata)
                        }
                }
            },
            using: dependencies
        )

        // We don't need to use "screen protection" in the SAE.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidEnterBackground),
            name: .sessionDidEnterBackground,
            object: nil
        )
    }
    
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        
        // Note: The share extension doesn't have a proper window so we need to manually update
        // the ThemeManager from here
        ThemeManager.traitCollectionDidChange(previousTraitCollection)
    }

    func versionMigrationsDidComplete(userMetadata: ExtensionHelper.UserMetadata?) {
        Log.assertOnMainThread()

        /// Now that the migrations are completed schedule config syncs for **all** configs that have pending changes to
        /// ensure that any pending local state gets pushed and any jobs waiting for a successful config sync are run
        ///
        /// **Note:** We only want to do this if the app is active and ready for app extensions to run
        if dependencies[singleton: .appContext].isAppForegroundAndActive && userMetadata != nil {
            dependencies[singleton: .storage].writeAsync { [dependencies] db in
                dependencies.mutate(cache: .libSession) { $0.syncAllPendingPushes(db) }
            }
        }

        checkIsAppReady(migrationsCompleted: true, userMetadata: userMetadata)
    }

    func checkIsAppReady(migrationsCompleted: Bool, userMetadata: ExtensionHelper.UserMetadata?) {
        Log.assertOnMainThread()

        // If something went wrong during startup then show the UI still (it has custom UI for
        // this case) but don't mark the app as ready or trigger the 'launchDidComplete' logic
        guard
            migrationsCompleted,
            dependencies[singleton: .storage].isValid,
            !dependencies[singleton: .appReadiness].isAppReady,
            userMetadata != nil
        else { return showLockScreenOrMainContent(userMetadata: userMetadata) }

        // Note that this does much more than set a flag;
        // it will also run all deferred blocks.
        dependencies[singleton: .appReadiness].setAppReady()
        dependencies.mutate(cache: .appVersion) { $0.saeLaunchDidComplete() }

        showLockScreenOrMainContent(userMetadata: userMetadata)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        Log.appResumedExecution()
    }

    @objc
    public func applicationDidEnterBackground() {
        Log.assertOnMainThread()
        Log.flush()
        
        if dependencies.mutate(cache: .libSession, { $0.get(.isScreenLockEnabled) }) {
            self.dismiss(animated: false) { [weak self] in
                Log.assertOnMainThread()
                self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
            }
        }
    }

    deinit {
        processPendingAttachmentsTask?.cancel()
        NotificationCenter.default.removeObserver(self)
        Log.flush()

        // Share extensions reside in a process that may be reused between usages.
        // That isn't safe; the codebase is full of statics (e.g. singletons) which
        // we can't easily clean up.
        exit(0)
    }
    
    // MARK: - Updating
    
    private func showLockScreenOrMainContent(userMetadata: ExtensionHelper.UserMetadata?) {
        if dependencies.mutate(cache: .libSession, { $0.get(.isScreenLockEnabled) }) {
            showLockScreen(userMetadata: userMetadata)
        }
        else {
            showMainContent(userMetadata: userMetadata)
        }
    }
    
    private func showLockScreen(userMetadata: ExtensionHelper.UserMetadata?) {
        let screenLockVC = SAEScreenLockViewController(
            hasUserMetadata: userMetadata != nil,
            onUnlock: { [weak self] in self?.showMainContent(userMetadata: userMetadata) },
            onCancel: { [weak self] in
                self?.shareViewWasCompleted(threadId: nil, interactionId: nil)
            }
        )
        setViewControllers([ screenLockVC ], animated: false)
    }
    
    private func showMainContent(userMetadata: ExtensionHelper.UserMetadata?) {
        let threadPickerVC: ThreadPickerVC = ThreadPickerVC(
            userMetadata: userMetadata,
            itemProviders: try? extractItemProviders(),
            using: dependencies
        )
        threadPickerVC.shareNavController = self
        
        setViewControllers([ threadPickerVC ], animated: false)
        
        let indicator: ModalActivityIndicatorViewController = ModalActivityIndicatorViewController()
        present(indicator, animated: false)
        
        processPendingAttachmentsTask?.cancel()
        processPendingAttachmentsTask = Task.detached(priority: .userInitiated) { [weak self, indicator] in
            guard let self = self else { return }
            
            do {
                let attachments: [PendingAttachment] = try await buildAttachments()
                
                /// Validate the expected attachment sizes before proceeding
                try attachments.forEach { attachment in
                    try attachment.ensureExpectedEncryptedSize(
                        domain: .attachment,
                        maxFileSize: Network.maxFileSize,
                        using: self.dependencies
                    )
                }
                
                await ShareNavController.pendingAttachments.send(attachments)
                await indicator.dismiss()
            }
            catch {
                await indicator.dismiss { [weak self] in
                    self?.shareViewFailed(error: error)
                }
            }
        }
    }
    
    func shareViewWasCompleted(threadId: String?, interactionId: Int64?) {
        dependencies[defaults: .appGroup, key: .lastSharedThreadId] = threadId
        
        if let interactionId: Int64 = interactionId {
            dependencies[defaults: .appGroup, key: .lastSharedMessageId] = Int(interactionId)
        }
        
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
    
    func shareViewFailed(error: Error) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.shareViewFailed(error: error)
            }
            return
        }
        
        Log.error("Failed to share due to error: \(error)")
        let errorTitle: String = {
            switch error {
                case NetworkError.maxFileSizeExceeded, AttachmentError.fileSizeTooLarge:
                    return "attachmentsErrorSending".localized()
                case AttachmentError.noAttachment, AttachmentError.encryptionFailed:
                    return Constants.app_name
                
                case is AttachmentError: return "attachmentsErrorSending".localized()
                
                default: return Constants.app_name
            }
        }()
        let errorText: String = {
            switch error {
                case NetworkError.maxFileSizeExceeded, AttachmentError.fileSizeTooLarge:
                    return "attachmentsErrorSize".localized()
                    
                case AttachmentError.noAttachment, AttachmentError.encryptionFailed:
                    return "attachmentsErrorSending".localized()
                
                default: return "\(error)"
            }
        }()
        let modal: ConfirmationModal = ConfirmationModal(
            targetView: self.view,
            info: ConfirmationModal.Info(
                title: errorTitle,
                body: .text(errorText),
                cancelTitle: "okay".localized(),
                cancelStyle: .alert_text,
                afterClosed: { [weak self] in self?.extensionContext?.cancelRequest(withError: error) }
            )
        )
        self.present(modal, animated: true)
    }
    
    // MARK: Attachment Prep
    
    private func extractItemProviders() throws -> [NSItemProvider]? {
        guard let inputItems = self.extensionContext?.inputItems else {
            throw ShareViewControllerError.assertionError(description: "no input item")
        }

        for inputItemRaw in inputItems {
            guard let inputItem = inputItemRaw as? NSExtensionItem else {
                Log.error("invalid inputItem \(inputItemRaw)")
                continue
            }
            
            return ShareNavController.preferredItemProviders(inputItem: inputItem)
        }
        
        throw ShareViewControllerError.assertionError(description: "no input item")
    }

    private class func preferredItemProviders(inputItem: NSExtensionItem) -> [NSItemProvider]? {
        guard let attachments = inputItem.attachments else { return nil }

        var visualMediaItemProviders = [NSItemProvider]()
        var hasNonVisualMedia = false
        
        for attachment in attachments {
            if attachment.isVisualMediaItem {
                visualMediaItemProviders.append(attachment)
            }
            else {
                hasNonVisualMedia = true
            }
        }
        
        // Only allow multiple-attachment sends if all attachments
        // are visual media.
        if visualMediaItemProviders.count > 0 && !hasNonVisualMedia {
            return visualMediaItemProviders
        }

        // A single inputItem can have multiple attachments, e.g. sharing from Firefox gives
        // one url attachment and another text attachment, where the the url would be https://some-news.com/articles/123-cat-stuck-in-tree
        // and the text attachment would be something like "Breaking news - cat stuck in tree"
        //
        // FIXME: For now, we prefer the URL provider and discard the text provider, since it's more useful to share the URL than the caption
        // but we *should* include both. This will be a bigger change though since our share extension is currently heavily predicated
        // on one itemProvider per share.

        // Prefer a URL provider if available
        if let preferredAttachment = attachments.first(where: { (attachment: Any) -> Bool in
            guard let itemProvider = attachment as? NSItemProvider else {
                return false
            }
            
            return itemProvider.matches(type: .url)
        }) {
            return [preferredAttachment]
        }

        // else return whatever is available
        if let itemProvider = inputItem.attachments?.first {
            return [itemProvider]
        }
        else {
            Log.error("Missing attachment.")
        }
        
        return []
    }
    
    // MARK: - LoadedItem

    private struct LoadedItem {
        let itemProvider: NSItemProvider
        let itemUrl: URL
        let type: UTType

        init(
            itemProvider: NSItemProvider,
            itemUrl: URL,
            type: UTType
        ) {
            self.itemProvider = itemProvider
            self.itemUrl = itemUrl
            self.type = type
        }
    }
    
    private func pendingAttachment(itemProvider: NSItemProvider) async throws -> PendingAttachment {
        Log.info("utiTypes for attachment: \(itemProvider.registeredTypeIdentifiers)")

        // We need to be very careful about which UTI type we use.
        //
        // * In the case of "textual" shares (e.g. web URLs and text snippets), we want to
        //   coerce the UTI type to kUTTypeURL or kUTTypeText.
        // * We want to treat shared files as file attachments.  Therefore we do not
        //   want to treat file URLs like web URLs.
        // * UTIs aren't very descriptive (there are far more MIME types than UTI types)
        //   so in the case of file attachments we try to refine the attachment type
        //   using the file extension.
        guard let srcType: UTType = itemProvider.type else {
            throw ShareViewControllerError.unsupportedMedia
        }
        Log.debug("matched UTType: \(srcType.identifier)")
        
        let pendingAttachment: PendingAttachment = try await withCheckedThrowingContinuation { [itemProvider, dependencies] continuation in
            itemProvider.loadItem(forTypeIdentifier: srcType.identifier, options: nil) { value, error in
                if let error: Error = error {
                    return continuation.resume(throwing: error)
                }
                
                switch value {
                    case .none:
                        return continuation.resume(
                            throwing: ShareViewControllerError.assertionError(
                                description: "missing item provider"
                            )
                        )
                        
                    case let data as Data:
                        guard let tempFilePath = try? dependencies[singleton: .fileManager].write(dataToTemporaryFile: data) else {
                            return continuation.resume(
                                throwing: ShareViewControllerError.assertionError(
                                    description: "Error writing item data"
                                )
                            )
                        }
                        
                        return continuation.resume(
                            returning: PendingAttachment(
                                source: .file(URL(fileURLWithPath: tempFilePath)),
                                utType: srcType,
                                using: dependencies
                            )
                        )

                    case let string as String:
                        Log.debug("string provider: \(string)")
                        return continuation.resume(
                            returning: PendingAttachment(
                                source: .text(string.filteredForDisplay),
                                utType: srcType,
                                using: dependencies
                            )
                        )
                        
                    case let url as URL:
                        /// If it's not a file URL then the user is sharing a website so we should handle it as text
                        guard url.isFileURL else {
                            return continuation.resume(
                                returning: PendingAttachment(
                                    source: .text(url.absoluteString),
                                    utType: srcType,
                                    using: dependencies
                                )
                            )
                        }
                        
                        /// Otherwise we should copy the content into a temporary directory so we don't need to worry about
                        /// weird system file security issues when trying to eventually share it
                        let tmpPath: String = dependencies[singleton: .fileManager]
                            .temporaryFilePath(fileExtension: url.pathExtension)
                        
                        do {
                            try dependencies[singleton: .fileManager].copyItem(at: url, to: URL(fileURLWithPath: tmpPath))
                            
                            return continuation.resume(
                                returning: PendingAttachment(
                                    source: .file(URL(fileURLWithPath: tmpPath)),
                                    utType: (UTType(sessionFileExtension: url.pathExtension) ?? .url),
                                    sourceFilename: url.lastPathComponent,
                                    using: dependencies
                                )
                            )
                        }
                        catch {
                            return continuation.resume(
                                throwing: ShareViewControllerError.assertionError(
                                    description: "Failed to copy temporary file: \(error)"
                                )
                            )
                        }
                        
                    case let image as UIImage:
                        return continuation.resume(
                            returning: PendingAttachment(
                                source: .media(.image(UUID().uuidString, image)),
                                utType: srcType,
                                using: dependencies
                            )
                        )
                        
                    default:
                        // It's unavoidable that we may sometimes receives data types that we
                        // don't know how to handle.
                        return continuation.resume(
                            throwing: ShareViewControllerError.assertionError(
                                description: "Unexpected value: \(String(describing: value))"
                            )
                        )
                }
            }
        }
        
        /// Apple likes to use special formats for media so in order to maintain compatibility with other clients we want to
        /// convert videos to `MPEG4` and images to `WebP` if it's not one of the supported output types
        let utType: UTType = pendingAttachment.utType
        let frameCount: Int = {
            switch pendingAttachment.metadata {
                case .media(let metadata): return metadata.frameCount
                default: return 1
            }
        }()

        if utType.isVideo && !UTType.supportedOutputVideoTypes.contains(utType) {
            /// Since we need to convert the file we should clean up the temporary one we created earlier (the conversion will create
            /// a new one)
            defer {
                switch pendingAttachment.source {
                    case .file(let url), .media(.url(let url)), .media(.videoUrl(let url, _, _, _)):
                        if dependencies[singleton: .fileManager].isLocatedInTemporaryDirectory(url.path) {
                            try? dependencies[singleton: .fileManager].removeItem(atPath: url.path)
                        }
                    default: break
                }
            }
            
            let preparedAttachment: PreparedAttachment = try await pendingAttachment.prepare(
                operations: [.convert(to: .mp4)],
                using: dependencies
            )
            
            return PendingAttachment(
                source: .media(
                    .videoUrl(
                        URL(fileURLWithPath: preparedAttachment.filePath),
                        .mpeg4Movie,
                        pendingAttachment.sourceFilename,
                        dependencies[singleton: .attachmentManager]
                    )
                ),
                utType: .mpeg4Movie,
                sourceFilename: pendingAttachment.sourceFilename,
                using: dependencies
            )
        }
        
        if utType.isImage && frameCount == 1 && !UTType.supportedOutputImageTypes.contains(utType) {
            /// Since we need to convert the file we should clean up the temporary one we created earlier (the conversion will create
            /// a new one)
            defer {
                switch pendingAttachment.source {
                    case .file(let url), .media(.url(let url)), .media(.videoUrl(let url, _, _, _)):
                        if dependencies[singleton: .fileManager].isLocatedInTemporaryDirectory(url.path) {
                            try? dependencies[singleton: .fileManager].removeItem(atPath: url.path)
                        }
                    default: break
                }
            }
            
            let targetFormat: PendingAttachment.ConversionFormat = (dependencies[feature: .usePngInsteadOfWebPForFallbackImageType] ?
                .png : .webPLossy
            )
            let preparedAttachment: PreparedAttachment = try await pendingAttachment.prepare(
                operations: [.convert(to: targetFormat)],
                using: dependencies
            )
            
            return PendingAttachment(
                source: .media(.url(URL(fileURLWithPath: preparedAttachment.filePath))),
                utType: .webP,
                sourceFilename: pendingAttachment.sourceFilename,
                using: dependencies
            )
        }
        
        return pendingAttachment
    }

    private func buildAttachments() async throws -> [PendingAttachment] {
        let itemProviders: [NSItemProvider] = try extractItemProviders() ?? {
            throw ShareViewControllerError.assertionError(description: "no input item")
        }()
        
        var result: [PendingAttachment] = []

        for itemProvider in itemProviders.prefix(AttachmentManager.maxAttachmentsAllowed) {
            let attachment: PendingAttachment = try await pendingAttachment(itemProvider: itemProvider)

            result.append(attachment)
        }
        
        guard !result.isEmpty else {
            throw ShareViewControllerError.assertionError(description: "no valid attachments")
        }
        
        return result
    }

    // Some host apps (e.g. iOS Photos.app) sometimes auto-converts some video formats (e.g. com.apple.quicktime-movie)
    // into mp4s as part of the NSItemProvider `loadItem` API. (Some files the Photo's app doesn't auto-convert)
    //
    // However, when using this url to the converted item, AVFoundation operations such as generating a
    // preview image and playing the url in the AVMoviePlayer fails with an unhelpful error: "The operation could not be completed"
    //
    // We can work around this by first copying the media into our container.
    //
    // I don't understand why this is, and I haven't found any relevant documentation in the NSItemProvider
    // or AVFoundation docs.
    //
    // Notes:
    //
    // These operations succeed when sending a video which initially existed on disk as an mp4.
    // (e.g. Alice sends a video to Bob through the main app, which ensures it's an mp4. Bob saves it, then re-shares it)
    //
    // I *did* verify that the size and SHA256 sum of the original url matches that of the copied url. So there
    // is no difference between the contents of the file, yet one works one doesn't.
    // Perhaps the AVFoundation APIs require some extra file system permssion we don't have in the
    // passed through URL.
    private func isVideoNeedingRelocation(itemProvider: NSItemProvider, itemUrl: URL) -> Bool {
        let pathExtension = itemUrl.pathExtension
        guard pathExtension.count > 0 else {
            Log.verbose("item URL has no file extension: \(itemUrl).")
            return false
        }
        guard let typeForURL: UTType = UTType(sessionFileExtension: pathExtension) else {
            Log.verbose("item has unknown UTI type: \(itemUrl).")
            return false
        }
        Log.verbose("typeForURL: \(typeForURL.identifier)")
        guard typeForURL == .mpeg4Movie else {
            // Either it's not a video or it was a video which was not auto-converted to mp4.
            // Not affected by the issue.
            return false
        }

        // If video file already existed on disk as an mp4, then the host app didn't need to
        // apply any conversion, so no need to relocate the app.
        return !itemProvider.registeredTypeIdentifiers.contains(UTType.mpeg4Movie.identifier)
    }
}

// MARK: - NSItemProvider Convenience

private extension NSItemProvider {
    var isVisualMediaItem: Bool {
        hasItemConformingToTypeIdentifier(UTType.image.identifier) ||
        hasItemConformingToTypeIdentifier(UTType.movie.identifier)
    }
    
    func matches(type: UTType) -> Bool {
        // URLs, contacts and other special items have to be detected separately.
        // Many shares (e.g. pdfs) will register many UTI types and/or conform to kUTTypeData.
        guard
            registeredTypeIdentifiers.count == 1,
            let firstTypeIdentifier: String = registeredTypeIdentifiers.first
        else { return false }
        
        return (firstTypeIdentifier == type.identifier)
    }

    var type: UTType? {
        switch (matches(type: .url), matches(type: .contact)) {
            case (true, _): return .url
            case (_, true): return .contact
            
            // Use the first UTI that conforms to "data".
            default:
                return registeredTypeIdentifiers
                    .compactMap { UTType($0) }
                    .first { $0.conforms(to: .data) }
        }
    }
}

// MARK: - SAESNUIKitConfig

private struct SAESNUIKitConfig: SNUIKit.ConfigType {
    private let dependencies: Dependencies
    
    var maxFileSize: UInt { Network.maxFileSize }
    var isStorageValid: Bool { dependencies[singleton: .storage].isValid }
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
    }
    
    // MARK: - Functions
    
    /// Unable to change the theme from the Share extension
    func themeChanged(_ theme: Theme, _ primaryColor: Theme.PrimaryColor, _ matchSystemNightModeSetting: Bool) {}
    
    func navBarSessionIcon() -> NavBarSessionIcon {
        switch (dependencies[feature: .serviceNetwork], dependencies[feature: .forceOffline]) {
            case (.mainnet, false): return NavBarSessionIcon()
            case (.testnet, _), (.mainnet, true):
                return NavBarSessionIcon(
                    showDebugUI: true,
                    serviceNetworkTitle: dependencies[feature: .serviceNetwork].title,
                    isMainnet: (dependencies[feature: .serviceNetwork] == .mainnet)
                )
        }
    }
    
    func persistentTopBannerChanged(warningKey: String?) {
        dependencies[defaults: .appGroup, key: .topBannerWarningToShow] = warningKey
    }
    
    func cachedContextualActionInfo(tableViewHash: Int, sideKey: String) -> [Int: Any]? {
        Log.warn("[SAESNUIKitConfig] Attempted to retrieve ContextualActionInfo when it's not supported.")
        return nil
    }
    
    func cacheContextualActionInfo(tableViewHash: Int, sideKey: String, actionIndex: Int, actionInfo: Any) {
        Log.warn("[SAESNUIKitConfig] Attempted to cache ContextualActionInfo when it's not supported.")
    }
    
    func removeCachedContextualActionInfo(tableViewHash: Int, keys: [String]) {}
    
    func shouldShowStringKeys() -> Bool {
        return dependencies[feature: .showStringKeys]
    }
    
    func assetInfo(for path: String, utType: UTType, sourceFilename: String?) -> (asset: AVURLAsset, isValidVideo: Bool, cleanup: () -> Void)? {
        guard
            let result: (asset: AVURLAsset, utType: UTType, cleanup: () -> Void) = AVURLAsset.asset(
                for: path,
                utType: utType,
                sourceFilename: sourceFilename,
                using: dependencies
            )
        else { return nil }
        
        return (result.asset, MediaUtils.isValidVideo(asset: result.asset, utType: result.utType), result.cleanup)
    }
    
    func mediaDecoderDefaultImageOptions() -> CFDictionary {
        return dependencies[singleton: .mediaDecoder].defaultImageOptions
    }
    
    func mediaDecoderDefaultThumbnailOptions(maxDimension: CGFloat) -> CFDictionary {
        return dependencies[singleton: .mediaDecoder].defaultThumbnailOptions(maxDimension: maxDimension)
    }
    
    func mediaDecoderSource(for url: URL) -> CGImageSource? {
        return dependencies[singleton: .mediaDecoder].source(for: url)
    }
    
    func mediaDecoderSource(for data: Data) -> CGImageSource? {
        return dependencies[singleton: .mediaDecoder].source(for: data)
    }
}
