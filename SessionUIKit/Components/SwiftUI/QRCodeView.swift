// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

public struct QRCodeView: View {
    private struct GenerationInput: Equatable {
        let string: String
        let hasBackground: Bool
        let logo: String?
        let shouldCache: Bool
    }
    
    private let providedImage: UIImage?
    private let generationInput: GenerationInput?
    @State private var generatedImage: UIImage?
    let themeStyle: UIUserInterfaceStyle
    
    private var qrCodeImage: UIImage? { providedImage ?? generatedImage }
    var backgroundThemeColor: ThemeValue {
        switch themeStyle {
            case .light:
                return .backgroundSecondary
            default:
                return .textPrimary
        }
    }
    var qrCodeThemeColor: ThemeValue {
        switch themeStyle {
            case .light:
                return .textPrimary
            default:
                return .backgroundPrimary
        }
    }
    
    static private var cornerRadius: CGFloat = 10
    
    public init(
        qrCodeImage: UIImage?,
        themeStyle: UIUserInterfaceStyle
    ) {
        self.providedImage = qrCodeImage
        self.generationInput = nil
        self.themeStyle = themeStyle
    }
    
    public init(
        string: String,
        hasBackground: Bool,
        logo: String?,
        shouldCache: Bool = true,
        themeStyle: UIUserInterfaceStyle
    ) {
        /// Generating on the main thread takes up to a second on older devices (this `init` runs inside the parent's `body`),
        /// so only take an already generated image here and generate any other in `body`'s `task`
        self.providedImage = nil
        self.generationInput = GenerationInput(string: string, hasBackground: hasBackground, logo: logo, shouldCache: shouldCache)
        self._generatedImage = State(
            initialValue: (shouldCache ? QRCode.cachedImage(for: string, hasBackground: hasBackground, iconName: logo) : nil)
        )
        self.themeStyle = themeStyle
    }
    
    public var body: some View {
        ZStack(alignment: .center) {
            ZStack(alignment: .center) {
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .fill(themeColor: backgroundThemeColor)
                
                if let qrCodeImage: UIImage = self.qrCodeImage {
                    Image(uiImage: qrCodeImage)
                        .resizable()
                        .renderingMode(.template)
                        .foregroundColor(themeColor: qrCodeThemeColor)
                        .scaledToFit()
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity
                        )
                        .padding(.vertical, Values.smallSpacing)
                }
            }
            .frame(
                maxWidth: 400,
                maxHeight: 400
            )
        }
        .frame(maxWidth: .infinity)
        .task(id: generationInput) {
            guard let input: GenerationInput = generationInput else { return }
            
            generatedImage = await Task.detached(priority: .userInitiated) {
                QRCode.generate(
                    for: input.string,
                    hasBackground: input.hasBackground,
                    iconName: input.logo,
                    shouldCache: input.shouldCache
                )
            }.value
        }
    }
}
