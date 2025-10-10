// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

public struct QRCodeView: View {
    let qrCodeImage: UIImage?
    let themeStyle: UIUserInterfaceStyle
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
    static private var logoSize: CGFloat = 66
    
    public init(
        qrCodeImage: UIImage?,
        themeStyle: UIUserInterfaceStyle
    ) {
        self.qrCodeImage = qrCodeImage
        self.themeStyle = themeStyle
    }
    
    public init(
        string: String,
        hasBackground: Bool,
        logo: String?,
        themeStyle: UIUserInterfaceStyle
    ) {
        self.qrCodeImage = QRCode.generate(for: string, hasBackground: hasBackground, iconName: logo)
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
    }
}
