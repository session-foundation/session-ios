// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import AVKit

class DismissCallbackAVPlayerViewController: AVPlayerViewController {
    private let onDismiss: () -> Void
    
    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        
        self.onDismiss()
    }
}
