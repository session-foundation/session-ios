// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

class ImagePickerHandler: NSObject, UIImagePickerControllerDelegate & UINavigationControllerDelegate {
    private let onTransition: (UIViewController, TransitionType) -> Void
    private let onImagePicked: (UIImage?, String?) -> Void
    
    // MARK: - Initialization
    
    init(
        onTransition: @escaping (UIViewController, TransitionType) -> Void,
        onImagePicked: @escaping (UIImage?, String?) -> Void
    ) {
        self.onTransition = onTransition
        self.onImagePicked = onImagePicked
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
                let type: Any = try? imageUrl.resourceValues(forKeys: [.typeIdentifierKey])
                    .allValues
                    .first,
                let typeString: String = type as? String,
                MIMETypeUtil.supportedAnimatedImageUTITypes().contains(typeString)
            else {
                let viewController: CropScaleImageViewController = CropScaleImageViewController(
                    srcImage: rawAvatar,
                    successCompletion: { resultImage in
                        self?.onImagePicked(resultImage, nil)
                    }
                )
                self?.onTransition(viewController, .present)
                return
            }
            
            self?.onImagePicked(nil, imageUrl.path)
        }
    }
}
