// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

public struct QRCodeView: View {
    let string: String
    let hasBackground: Bool
    let logo: String?
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
        string: String,
        hasBackground: Bool,
        logo: String?,
        themeStyle: UIUserInterfaceStyle
    ) {
        self.string = string
        self.hasBackground = hasBackground
        self.logo = logo
        self.themeStyle = themeStyle
    }
    
    public var body: some View {
        ZStack(alignment: .center) {
            ZStack(alignment: .center) {
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .fill(themeColor: backgroundThemeColor)
                
                Image(uiImage: QRCode.generate(for: string, hasBackground: hasBackground, iconName: logo))
                    .resizable()
                    .renderingMode(.template)
                    .foregroundColor(themeColor: qrCodeThemeColor)
                    .scaledToFit()
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity
                    )
                    .padding(.vertical, Values.smallSpacing)
                
//                if let logo = logo {
//                    ZStack(alignment: .center) {
//                        Rectangle()
//                            .fill(themeColor: backgroundThemeColor)
//                        
//                        Image(logo)
//                            .resizable()
//                            .renderingMode(.template)
//                            .foregroundColor(themeColor: qrCodeThemeColor)
//                            .scaledToFit()
//                            .frame(
//                                maxWidth: .infinity,
//                                maxHeight: .infinity
//                            )
//                            .padding(.all, 4)
//                    }
//                    .frame(
//                        width: Self.logoSize,
//                        height: Self.logoSize
//                    )
//                }
            }
            .frame(
                maxWidth: 400,
                maxHeight: 400
            )
        }
        .frame(maxWidth: .infinity)
    }
}
