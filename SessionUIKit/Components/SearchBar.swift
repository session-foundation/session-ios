// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Lucide

public final class SearchBar : UISearchBar {
    
    public override init(frame: CGRect) {
        super.init(frame: frame)
        setUpSessionStyle()
    }
    
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpSessionStyle()
    }
}

public final class ContactsSearchBar : UISearchBar {
    
    public init(searchBarThemeBackgroundColor: ThemeValue) {
        super.init(frame: .zero)
        setUpContactSearchStyle(searchBarThemeBackgroundColor: searchBarThemeBackgroundColor)
    }
    
    public override init(frame: CGRect) {
        super.init(frame: frame)
        setUpContactSearchStyle(searchBarThemeBackgroundColor: .backgroundPrimary)
    }
    
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpContactSearchStyle(searchBarThemeBackgroundColor: .backgroundPrimary)
    }
}

public extension UISearchBar {
    
    func setUpSessionStyle() {
        searchBarStyle = .minimal // Hide the border around the search bar
        barStyle = .black // Use Apple's black design as a base
        themeTintColor = .textPrimary // The cursor color
        
        setImage(Lucide.image(icon: .search, size: 18)?.withRenderingMode(.alwaysTemplate), for: .search, state: .normal)
        searchTextField.leftView?.themeTintColor = .textSecondary
        
        setImage(Lucide.image(icon: .x, size: 18)?.withRenderingMode(.alwaysTemplate), for: .clear, state: .normal)
        
        let searchTextField: UITextField = self.searchTextField
        searchTextField.themeBackgroundColor = .messageBubble_overlay // The search bar background color
        searchTextField.themeTextColor = .textPrimary
        searchTextField.themeAttributedPlaceholder = ThemedAttributedString(
            string: "search".localized(),
            attributes: [
                .themeForegroundColor: ThemeValue.textSecondary
            ]
        )
        setPositionAdjustment(UIOffset(horizontal: 4, vertical: 0), for: UISearchBar.Icon.search)
        searchTextPositionAdjustment = UIOffset(horizontal: 2, vertical: 0)
        setPositionAdjustment(UIOffset(horizontal: -4, vertical: 0), for: UISearchBar.Icon.clear)
    }
    
    func setUpContactSearchStyle(searchBarThemeBackgroundColor: ThemeValue) {
        searchBarStyle = .minimal
        barStyle = .default
        themeTintColor = .textPrimary
        
        setImage(Lucide.image(icon: .search, size: 18)?.withRenderingMode(.alwaysTemplate), for: .search, state: .normal)
        searchTextField.leftView?.themeTintColor = .textSecondary
        
        setImage(Lucide.image(icon: .x, size: 18)?.withRenderingMode(.alwaysTemplate), for: .clear, state: .normal)
        
        let searchTextField: UITextField = self.searchTextField
        searchTextField.borderStyle = .none
        searchTextField.layer.cornerRadius = 18
        searchTextField.themeBackgroundColor = searchBarThemeBackgroundColor
        searchTextField.themeTextColor = .textPrimary
        searchTextField.themeAttributedPlaceholder = ThemedAttributedString(
            string: "searchContacts".localized(),
            attributes: [
                .themeForegroundColor: ThemeValue.textSecondary
            ]
        )
        setPositionAdjustment(UIOffset(horizontal: 4, vertical: 0), for: UISearchBar.Icon.search)
        searchTextPositionAdjustment = UIOffset(horizontal: 2, vertical: 0)
        setPositionAdjustment(UIOffset(horizontal: -4, vertical: 0), for: UISearchBar.Icon.clear)
    }
}
