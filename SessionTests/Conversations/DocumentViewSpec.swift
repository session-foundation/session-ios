// Copyright © 2026 Session Technology Foundation. All rights reserved.

import UIKit
import Quick
import Nimble
import SessionUIKit
import SessionUtilitiesKit
import TestUtilities

@testable import SessionMessagingKit
@testable import Session

class DocumentViewSpec: AsyncSpec {
    override class func spec() {
        // MARK: Configuration
        
        func attachment(state: Attachment.State) -> Attachment {
            return Attachment(
                variant: .standard,
                state: state,
                contentType: "application/pdf",
                byteCount: 1234
            )
        }
        
        @MainActor func visibleLabelText(for state: Attachment.State) -> [String] {
            func labels(in view: UIView) -> [UILabel] {
                return view.subviews.flatMap { subview -> [UILabel] in
                    guard !subview.isHidden else { return [] }
                    
                    return ((subview as? UILabel).map { [$0] } ?? []) + labels(in: subview)
                }
            }
            
            let view: DocumentView = DocumentView(
                attachment: attachment(state: state),
                textColor: .textPrimary
            )
            
            return labels(in: view).compactMap { $0.text }
        }
        
        // MARK: - a DocumentView
        describe("a DocumentView") {
            // MARK: -- shows the file size and a retry hint when the download failed
            it("shows the file size and a retry hint when the download failed") {
                let text: [String] = await visibleLabelText(for: .failedDownload)
                
                expect(text).to(contain(attachment(state: .downloaded).documentFileInfo))
                expect(text).to(contain("tapToRetry".localized()))
            }
            
            // MARK: -- does not show a retry hint once downloaded
            it("does not show a retry hint once downloaded") {
                let text: [String] = await visibleLabelText(for: .downloaded)
                
                expect(text).to(contain(attachment(state: .downloaded).documentFileInfo))
                expect(text).toNot(contain("tapToRetry".localized()))
            }
            
            // MARK: -- does not show a retry hint when the upload failed
            it("does not show a retry hint when the upload failed") {
                let text: [String] = await visibleLabelText(for: .failedUpload)
                
                expect(text).toNot(contain("tapToRetry".localized()))
            }
        }
    }
}
