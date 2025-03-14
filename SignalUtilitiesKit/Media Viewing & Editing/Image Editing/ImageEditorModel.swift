//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.

import UIKit
import UniformTypeIdentifiers
import SessionUtilitiesKit

// Used to represent undo/redo operations.
//
// Because the image editor's "contents" and "items"
// are immutable, these operations simply take a
// snapshot of the current contents which can be used
// (multiple times) to preserve/restore editor state.
private class ImageEditorOperation: NSObject {

    let operationId: String

    let contents: ImageEditorContents

    required init(contents: ImageEditorContents) {
        self.operationId = UUID().uuidString
        self.contents = contents
    }
}

// MARK: -

public protocol ImageEditorModelObserver: AnyObject {
    // Used for large changes to the model, when the entire
    // model should be reloaded.
    func imageEditorModelDidChange(before: ImageEditorContents, after: ImageEditorContents)

    // Used for small narrow changes to the model, usually
    // to a single item.
    func imageEditorModelDidChange(changedItemIds: [String])
}

// MARK: -

public class ImageEditorModel {

    public static var isFeatureEnabled: Bool {
        return true
    }

    private let dependencies: Dependencies
    public let srcImagePath: String
    public let srcImageSizePixels: CGSize
    private var contents: ImageEditorContents
    private var transform: ImageEditorTransform
    private var undoStack = [ImageEditorOperation]()
    private var redoStack = [ImageEditorOperation]()

    // We don't want to allow editing of images if:
    //
    // * They are invalid.
    // * We can't determine their size / aspect-ratio.
    public required init(srcImagePath: String, using dependencies: Dependencies) throws {
        self.dependencies = dependencies
        self.srcImagePath = srcImagePath

        let srcFileName = (srcImagePath as NSString).lastPathComponent
        let srcFileExtension = (srcFileName as NSString).pathExtension
        
        guard let type: UTType = UTType(sessionFileExtension: srcFileExtension) else {
            Log.error("[ImageEditorModel] Couldn't determine UTType for file.")
            throw ImageEditorError.invalidInput
        }
        guard type.isImage && !type.isAnimated else {
            Log.error("[ImageEditorModel] Invalid MIME type: \(type.preferredMIMEType ?? "unknown").")
            throw ImageEditorError.invalidInput
        }

        let srcImageSizePixels = Data.imageSize(for: srcImagePath, type: type, using: dependencies)
        guard srcImageSizePixels.width > 0, srcImageSizePixels.height > 0 else {
            Log.error("[ImageEditorModel] Couldn't determine image size.")
            throw ImageEditorError.invalidInput
        }
        self.srcImageSizePixels = srcImageSizePixels

        self.contents = ImageEditorContents()
        self.transform = ImageEditorTransform.defaultTransform(srcImageSizePixels: srcImageSizePixels)
    }

    public func currentTransform() -> ImageEditorTransform {
        return transform
    }

    public func isDirty() -> Bool {
        if itemCount() > 0 {
            return true
        }
        return transform != ImageEditorTransform.defaultTransform(srcImageSizePixels: srcImageSizePixels)
    }

    public func itemCount() -> Int {
        return contents.itemCount()
    }

    public func items() -> [ImageEditorItem] {
        return contents.items()
    }

    public func itemIds() -> [String] {
        return contents.itemIds()
    }

    public func has(itemForId itemId: String) -> Bool {
        return item(forId: itemId) != nil
    }

    public func item(forId itemId: String) -> ImageEditorItem? {
        return contents.item(forId: itemId)
    }

    public func canUndo() -> Bool {
        return !undoStack.isEmpty
    }

    public func canRedo() -> Bool {
        return !redoStack.isEmpty
    }

    public func currentUndoOperationId() -> String? {
        guard let operation = undoStack.last else {
            return nil
        }
        return operation.operationId
    }

    // MARK: - Observers

    private var observers = [Weak<ImageEditorModelObserver>]()

    public func add(observer: ImageEditorModelObserver) {
        observers.append(Weak(value: observer))
    }

    private func fireModelDidChange(before: ImageEditorContents, after: ImageEditorContents) {
        // We could diff here and yield a more narrow change event.
        for weakObserver in observers {
            guard let observer = weakObserver.value else {
                continue
            }
            observer.imageEditorModelDidChange(before: before, after: after)
        }
    }

    private func fireModelDidChange(changedItemIds: [String]) {
        // We could diff here and yield a more narrow change event.
        for weakObserver in observers {
            guard let observer = weakObserver.value else {
                continue
            }
            observer.imageEditorModelDidChange(changedItemIds: changedItemIds)
        }
    }

    // MARK: -

    public func undo() {
        guard let undoOperation = undoStack.popLast() else {
            Log.error("[ImageEditorModel] Cannot undo.")
            return
        }

        let redoOperation = ImageEditorOperation(contents: contents)
        redoStack.append(redoOperation)

        let oldContents = self.contents
        self.contents = undoOperation.contents

        // We could diff here and yield a more narrow change event.
        fireModelDidChange(before: oldContents, after: self.contents)
    }

    public func redo() {
        guard let redoOperation = redoStack.popLast() else {
            Log.error("[ImageEditorModel] Cannot redo.")
            return
        }

        let undoOperation = ImageEditorOperation(contents: contents)
        undoStack.append(undoOperation)

        let oldContents = self.contents
        self.contents = redoOperation.contents

        // We could diff here and yield a more narrow change event.
        fireModelDidChange(before: oldContents, after: self.contents)
    }

    public func append(item: ImageEditorItem) {
        performAction({ (oldContents) in
            let newContents = oldContents.clone()
            newContents.append(item: item)
            return newContents
        }, changedItemIds: [item.itemId])
    }

    public func replace(item: ImageEditorItem, suppressUndo: Bool = false) {
        performAction({ (oldContents) in
            let newContents = oldContents.clone()
            newContents.replace(item: item)
            return newContents
        }, changedItemIds: [item.itemId],
           suppressUndo: suppressUndo)
    }

    public func remove(item: ImageEditorItem) {
        performAction({ (oldContents) in
            let newContents = oldContents.clone()
            newContents.remove(item: item)
            return newContents
        }, changedItemIds: [item.itemId])
    }

    public func replace(transform: ImageEditorTransform) {
        self.transform = transform

        // The contents haven't changed, but this event prods the
        // observers to reload everything, which is necessary if
        // the transform changes.
        fireModelDidChange(before: self.contents, after: self.contents)
    }

    // MARK: - Temp Files

    private var temporaryFilePaths = [String]()

    public func temporaryFilePath(withFileExtension fileExtension: String) -> String {
        Log.assertOnMainThread()

        let filePath = dependencies[singleton: .fileManager].temporaryFilePath(fileExtension: fileExtension)
        temporaryFilePaths.append(filePath)
        return filePath
    }

    deinit {
        Log.assertOnMainThread()

        let temporaryFilePaths = self.temporaryFilePaths

        DispatchQueue.global(qos: .background).async { [dependencies] in
            for filePath in temporaryFilePaths {
                do { try dependencies[singleton: .fileManager].removeItem(atPath: filePath) }
                catch { Log.error("[ImageEditorModel] Could not delete temp file: \(filePath)") }
            }
        }
    }

    private func performAction(_ action: (ImageEditorContents) -> ImageEditorContents,
                               changedItemIds: [String]?,
                               suppressUndo: Bool = false) {
        if !suppressUndo {
            let undoOperation = ImageEditorOperation(contents: contents)
            undoStack.append(undoOperation)
            redoStack.removeAll()
        }

        let oldContents = self.contents
        let newContents = action(oldContents)
        contents = newContents

        if let changedItemIds = changedItemIds {
            fireModelDidChange(changedItemIds: changedItemIds)
        } else {
            fireModelDidChange(before: oldContents,
                               after: self.contents)
        }
    }

    // MARK: - Utilities

    // Returns nil on error.
    private class func crop(imagePath: String, unitCropRect: CGRect) -> UIImage? {
        // TODO: Do we want to render off the main thread?
        Log.assertOnMainThread()

        guard let srcImage = UIImage(contentsOfFile: imagePath) else {
            Log.error("[ImageEditorModel] Could not load image")
            return nil
        }
        let srcImageSize = srcImage.size
        // Convert from unit coordinates to src image coordinates.
        let cropRect = CGRect(x: round(unitCropRect.origin.x * srcImageSize.width),
                              y: round(unitCropRect.origin.y * srcImageSize.height),
                              width: round(unitCropRect.size.width * srcImageSize.width),
                              height: round(unitCropRect.size.height * srcImageSize.height))

        guard cropRect.origin.x >= 0,
            cropRect.origin.y >= 0,
            cropRect.origin.x + cropRect.size.width <= srcImageSize.width,
            cropRect.origin.y + cropRect.size.height <= srcImageSize.height else {
            Log.error("[ImageEditorModel] Invalid crop rectangle.")
            return nil
        }
        guard cropRect.size.width > 0,
            cropRect.size.height > 0 else {
            // Not an error; indicates that the user tapped rather
            // than dragged.
            Log.warn("[ImageEditorModel] Empty crop rectangle.")
            return nil
        }

        let hasAlpha = Data.hasAlpha(forValidImageFilePath: imagePath)

        UIGraphicsBeginImageContextWithOptions(cropRect.size, !hasAlpha, srcImage.scale)
        defer { UIGraphicsEndImageContext() }

        guard let context = UIGraphicsGetCurrentContext() else {
            Log.error("[ImageEditorModel] context was unexpectedly nil")
            return nil
        }
        context.interpolationQuality = .high

        // Draw source image.
        let dstFrame = CGRect(origin: cropRect.origin.inverted(), size: srcImageSize)
        srcImage.draw(in: dstFrame)

        let dstImage = UIGraphicsGetImageFromCurrentImageContext()
        if dstImage == nil {
            Log.error("[ImageEditorModel] could not generate dst image.")
        }
        return dstImage
    }
}
