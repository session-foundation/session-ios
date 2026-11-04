// Copyright © 2026 Session Technology Foundation. All rights reserved.

import UIKit
import Quick
import Nimble
import SessionUIKit
import SessionUtilitiesKit
import TestUtilities

@testable import SessionMessagingKit
@testable import Session

class VoiceMessageViewSpec: AsyncSpec {
    override class func spec() {
        // MARK: Configuration
        
        typealias Rendered = (isShowingLoader: Bool, accessibilityValue: String?)
        
        /// The loader is private and its type comes from a package this target doesn't link, so it's found by name
        @MainActor func render(_ state: Attachment.State) -> Rendered {
            let view: VoiceMessageView = VoiceMessageView()
            view.update(
                with: Attachment(
                    variant: .voiceMessage,
                    state: state,
                    contentType: "audio/mpeg",
                    byteCount: 1234,
                    duration: 7
                ),
                isPlaying: false,
                progress: 0,
                playbackRate: 1,
                oldPlaybackRate: 1
            )
            let loader: UIView? = view.subviews
                .first { String(describing: type(of: $0)) == "NVActivityIndicatorView" }
            
            return ((loader.map { !$0.isHidden } == true), view.accessibilityValue)
        }
        
        // MARK: - a VoiceMessageView
        describe("a VoiceMessageView") {
            // MARK: -- shows the loader while downloading
            it("shows the loader while downloading") {
                let result: Rendered = await render(.downloading)
                
                expect(result.isShowingLoader).to(beTrue())
                expect(result.accessibilityValue).to(beNil())
            }
            
            // MARK: -- shows a retry state when the download failed
            it("shows a retry state when the download failed") {
                let result: Rendered = await render(.failedDownload)
                
                expect(result.isShowingLoader).to(beFalse())
                expect(result.accessibilityValue).to(equal("tapToRetry".localized()))
            }
            
            // MARK: -- shows a failed state when the upload failed
            it("shows a failed state when the upload failed") {
                let result: Rendered = await render(.failedUpload)
                
                expect(result.isShowingLoader).to(beFalse())
                expect(result.accessibilityValue).to(equal("messageStatusFailedToSend".localized()))
            }
            
            // MARK: -- shows an unavailable state when the attachment is invalid
            it("shows an unavailable state when the attachment is invalid") {
                let result: Rendered = await render(.invalid)
                
                expect(result.isShowingLoader).to(beFalse())
                expect(result.accessibilityValue).to(equal("unavailable".localized()))
            }
        }
    }
}
