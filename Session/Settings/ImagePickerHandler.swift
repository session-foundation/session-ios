// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

class ImagePickerHandler: NSObject, UIImagePickerControllerDelegate & UINavigationControllerDelegate {
    private let onTransition: (UIViewController, TransitionType) -> Void
    private let onImagePicked: (UIImage) -> Void
    private let onImageFilePicked: (String) -> Void
    
    // MARK: - Initialization
    
    init(
        onTransition: @escaping (UIViewController, TransitionType) -> Void,
        onImagePicked: @escaping (UIImage) -> Void,
        onImageFilePicked: @escaping (String) -> Void
    ) {
        self.onTransition = onTransition
        self.onImagePicked = onImagePicked
        self.onImageFilePicked = onImageFilePicked
    }
    
    // MARK: - UIImagePickerControllerDelegate
    
    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }
    
    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
        guard
            let imageUrl: URL = info[.imageURL] as? URL,
            let rawAvatar: UIImage = info[.originalImage] as? UIImage
        else {
            picker.presentingViewController?.dismiss(animated: true)
            return
        }
        
        picker.presentingViewController?.dismiss(animated: true) { [weak self] in
            // Check if the user selected an animated image (if so then don't crop, just
            // set the avatar directly
            guard
                let resourceValues: URLResourceValues = (try? imageUrl.resourceValues(forKeys: [.typeIdentifierKey])),
                let type: Any = resourceValues.allValues.first?.value,
                let typeString: String = type as? String,
                MIMETypeUtil.supportedAnimatedImageUTITypes().contains(typeString)
            else {
                let viewController: CropScaleImageViewController = CropScaleImageViewController(
                    srcImage: rawAvatar,
                    successCompletion: { resultImage in
                        self?.onImagePicked(resultImage)
                    }
                )
                self?.onTransition(viewController, .present)
                return
            }
            
            self?.onImageFilePicked(imageUrl.path)
        }
    }
}
