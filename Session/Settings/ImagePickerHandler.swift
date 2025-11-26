// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import PhotosUI
import UniformTypeIdentifiers
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

class ImagePickerHandler: PHPickerViewControllerDelegate {
    private let dependencies: Dependencies
    private let onTransition: (UIViewController, TransitionType) -> Void
    private let onImagePicked: (ImageDataManager.DataSource, CGRect?) -> Void
    
    // MARK: - Initialization
    
    init(
        onTransition: @escaping (UIViewController, TransitionType) -> Void,
        onImagePicked: @escaping (ImageDataManager.DataSource, CGRect?) -> Void,
        using dependencies: Dependencies
    ) {
        self.dependencies = dependencies
        self.onTransition = onTransition
        self.onImagePicked = onImagePicked
    }
    
    // MARK: - UIImagePickerControllerDelegate
    
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        guard
            let result: PHPickerResult = results.first,
            let typeIdentifier: String = result.itemProvider.registeredTypeIdentifiers.first
        else {
            picker.dismiss(animated: true)
            return
        }
        
        picker.dismiss(animated: true) { [weak self] in
            result.itemProvider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                guard let self = self else { return }
                guard let url: URL = url else {
                    Log.debug("[ImagePickHandler] Error loading file: \(error?.localizedDescription ?? "unknown")")
                    return
                }
                
                do {
                    let onImagePicked: (ImageDataManager.DataSource, CGRect?) -> Void = self.onImagePicked
                    let filePath: String = self.dependencies[singleton: .fileManager].temporaryFilePath()
                    try self.dependencies[singleton: .fileManager].copyItem(
                        atPath: url.path,
                        toPath: filePath
                    )
                    // TODO: Need to remove file when we are done
                    DispatchQueue.main.async { [weak self, dataManager = self.dependencies[singleton: .imageDataManager]] in
                        let viewController: CropScaleImageViewController = CropScaleImageViewController(
                            source: .url(URL(fileURLWithPath: filePath)),
                            dstSizePixels: CGSize(
                                width: DisplayPictureManager.maxDimension,
                                height: DisplayPictureManager.maxDimension
                            ),
                            dataManager: dataManager,
                            successCompletion: onImagePicked
                        )
                        
                        self?.onTransition(
                            StyledNavigationController(rootViewController: viewController),
                            .present
                        )
                    }
                }
                catch {
                    Log.debug("[ImagePickHandler] Error copying file: \(error)")
                }
            }
        }
    }
}
