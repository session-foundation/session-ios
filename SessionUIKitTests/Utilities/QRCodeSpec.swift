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
            
            // MARK: -- does not keep an image generated with shouldCache false
            it("does not keep an image generated with shouldCache false") {
                let recoveryPassword: String = String(repeating: "e", count: 64)
                let image: UIImage = QRCode.generate(for: recoveryPassword, hasBackground: false, iconName: nil, shouldCache: false)
                
                expect(image.size.width).to(beGreaterThan(0))
                expect(QRCode.cachedImage(for: recoveryPassword, hasBackground: false, iconName: nil)).to(beNil())
            }
            
            // MARK: -- does not keep every image it generates
            it("does not keep every image it generates") {
                let accountIds: [String] = (0..<12).map { "05\(String(format: "%064lx", 0x5eed00 + $0))" }
                accountIds.forEach { _ = QRCode.generate(for: $0, hasBackground: false, iconName: "SessionWhite40") }
                let cachedCount: Int = accountIds
                    .filter { QRCode.cachedImage(for: $0, hasBackground: false, iconName: "SessionWhite40") != nil }
                    .count
                print("[QRCodeSpec] \(cachedCount) of \(accountIds.count) generated images still cached")
                
                expect(cachedCount).to(beLessThan(accountIds.count))
                expect(QRCode.cachedImage(for: accountIds.last!, hasBackground: false, iconName: "SessionWhite40")).toNot(beNil())
            }
        }
    }
}
