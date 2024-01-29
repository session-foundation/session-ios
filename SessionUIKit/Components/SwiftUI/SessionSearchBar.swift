// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

struct SessionSearchBar: View {
    @Binding var searchText: String
    
    let cancelAction: () -> ()
    
    let height: CGFloat = 40
    let cornerRadius: CGFloat = 7
    var body: some View {
        HStack(
            alignment: .center,
            spacing: 0
        ) {
            HStack(
                alignment: .center,
                spacing: Values.verySmallSpacing
            ) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: Values.smallFontSize))
                    .foregroundColor(themeColor: .textSecondary)
                    .padding(.horizontal, Values.smallSpacing)
                
                ZStack(alignment: .leading) {
                    if searchText.isEmpty {
                        Text("Search")
                            .font(.system(size: Values.smallFontSize))
                            .foregroundColor(themeColor: .textSecondary)
                    }
                    
                    SwiftUI.TextField(
                        "",
                        text: $searchText
                    )
                    .font(.system(size: Values.smallFontSize))
                    .foregroundColor(themeColor: .textPrimary)
                }
            }
            .background(
                RoundedRectangle(
                    cornerSize: CGSize(
                        width: self.cornerRadius,
                        height: self.cornerRadius
                    )
                )
                .fill(themeColor: .backgroundSecondary)
                .frame(height: self.height)
            )
            
            Button {
                cancelAction()
            } label: {
                Text("cancel".localized())
                    .font(.system(size: Values.smallFontSize))
                    .foregroundColor(themeColor: .textSecondary)
                    .padding(.leading, Values.mediumSpacing)
            }
        }
        .padding(.horizontal, Values.mediumSpacing)
    }
}

struct SessionSearchBar_Previews: PreviewProvider {
    @State static var searchText: String = ""
    
    static var previews: some View {
        SessionSearchBar(searchText: $searchText) {}
    }
}
