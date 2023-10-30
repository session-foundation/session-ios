// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionUIKit
import SessionMessagingKit

struct VoiceMessageView_SwiftUI: View {
    
    private static let width: CGFloat = 160
    private static let toggleContainerSize: CGFloat = 20
    
    var body: some View {
        HStack(
            alignment: .center,
            spacing: Values.mediumSpacing
        ) {
            
        }.frame(
            width: Self.width
        )
    }
}

struct VoiceMessageView_SwiftUI_Previews: PreviewProvider {
    static var previews: some View {
        VoiceMessageView_SwiftUI()
    }
}
