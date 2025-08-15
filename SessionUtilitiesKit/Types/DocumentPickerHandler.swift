// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit

public class DocumentPickerHandler: NSObject, UIDocumentPickerDelegate {
    private let didPickDocumentsAt: ((UIDocumentPickerViewController, [URL]) -> Void)?
    private let wasCancelled: ((UIDocumentPickerViewController) -> Void)?
    
    // MARK: - Initialization
    
    public init(
        didPickDocumentsAt: ((UIDocumentPickerViewController, [URL]) -> Void)? = nil,
        wasCancelled: ((UIDocumentPickerViewController) -> Void)? = nil
    ) {
        self.didPickDocumentsAt = didPickDocumentsAt
        self.wasCancelled = wasCancelled
    }
    
    // MARK: - UIDocumentPickerDelegate
    
    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        didPickDocumentsAt?(controller, urls)
    }
    
    public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        wasCancelled?(controller)
    }
}
