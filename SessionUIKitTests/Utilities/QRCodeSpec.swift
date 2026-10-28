// Copyright © 2026 Session Technology Foundation. All rights reserved.

import UIKit
import Quick
import Nimble

@testable import SessionUIKit

class QRCodeSpec: QuickSpec {
    override class func spec() {
        // MARK: - a QRCode
        describe("a QRCode") {
            // MARK: -- only generates an image once for the same input
            it("only generates an image once for the same input") {
                let accountId: String = "05\(String(repeating: "a", count: 64))"
                let start: CFTimeInterval = CACurrentMediaTime()
                let first: UIImage = QRCode.generate(for: accountId, hasBackground: false, iconName: "SessionWhite40")
                let firstDuration: CFTimeInterval = (CACurrentMediaTime() - start)
                let images: [UIImage] = (0..<20).map { _ in
                    QRCode.generate(for: accountId, hasBackground: false, iconName: "SessionWhite40")
                }
                let repeatDuration: CFTimeInterval = (CACurrentMediaTime() - start - firstDuration)
                print("[QRCodeSpec] first generate \(Int(firstDuration * 1000))ms, 20 more \(Int(repeatDuration * 1000))ms")
                
                expect(images.allSatisfy { $0 === first }).to(beTrue())
            }
            
            // MARK: -- creates a QRCodeView without generating on the calling thread
            it("creates a QRCodeView without generating on the calling thread") {
                /// `QRCodeView` is created inside its parent's `body`, so generating there blocks the main thread
                let start: CFTimeInterval = CACurrentMediaTime()
                let view: QRCodeView = QRCodeView(
                    string: "05\(String(repeating: "d", count: 64))",
                    hasBackground: false,
                    logo: "SessionWhite40",
                    themeStyle: .dark
                )
                let duration: CFTimeInterval = (CACurrentMediaTime() - start)
                print("[QRCodeSpec] QRCodeView init \(Int(duration * 1000))ms")
                
                expect(duration).to(beLessThan(0.01))
                expect(view.themeStyle).to(equal(.dark))
            }
            
            // MARK: -- generates a different image for different input
            it("generates a different image for different input") {
                let first: UIImage = QRCode.generate(for: "05\(String(repeating: "b", count: 64))", hasBackground: false, iconName: nil)
                let second: UIImage = QRCode.generate(for: "05\(String(repeating: "c", count: 64))", hasBackground: false, iconName: nil)
                let third: UIImage = QRCode.generate(for: "05\(String(repeating: "b", count: 64))", hasBackground: true, iconName: nil)
                
                expect(first).toNot(beIdenticalTo(second))
                expect(first).toNot(beIdenticalTo(third))
            }
        }
    }
}
