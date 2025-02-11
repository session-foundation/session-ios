// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUtilitiesKit

public extension UIContextualAction {
    @ThreadSafeObject private static var lookupMap: [Int: [String: [Int: ThemeValue]]] = [:]
    
    enum Side: Int {
        case leading
        case trailing
        
        func key(for indexPath: IndexPath) -> String {
            return "\(indexPath.section)-\(indexPath.row)-\(rawValue)"
        }
        
        init?(for view: UIView) {
            guard view.frame.minX == 0 else {
                self = .trailing
                return
            }
            
            self = .leading
        }
    }
    
    convenience init(
        title: String? = nil,
        icon: UIImage? = nil,
        iconHeight: CGFloat = Values.mediumFontSize,
        themeTintColor: ThemeValue = .white,
        themeBackgroundColor: ThemeValue,
        side: Side,
        actionIndex: Int,
        indexPath: IndexPath,
        tableView: UITableView,
        handler: @escaping UIContextualAction.Handler
    ) {
        self.init(style: .normal, title: title, handler: handler)
        self.image = UIContextualAction
            .imageWith(
                title: title,
                icon: icon,
                iconHeight: iconHeight,
                themeTintColor: themeTintColor
            )?
            .withRenderingMode(.alwaysTemplate)
        self.themeBackgroundColor = themeBackgroundColor
        
        UIContextualAction._lookupMap.performUpdate {
            $0.setting(
                tableView.hashValue,
                ($0[tableView.hashValue] ?? [:])
                    .setting(
                        side.key(for: indexPath),
                        (($0[tableView.hashValue] ?? [:])[side.key(for: indexPath)] ?? [:])
                            .setting(actionIndex, themeTintColor)
                    )
            )
        }
    }
    
    private static func imageWith(
        title: String?,
        icon: UIImage?,
        iconHeight: CGFloat,
        themeTintColor: ThemeValue
    ) -> UIImage? {
        let stackView: UIStackView = UIStackView()
        stackView.axis = .vertical
        stackView.alignment = .center
        stackView.spacing = 4
        
        if let icon: UIImage = icon {
            let aspectRatio: CGFloat = (icon.size.width / icon.size.height)
            let imageView: UIImageView = UIImageView(image: icon)
            imageView.frame = CGRect(x: 0, y: 0, width: (iconHeight * aspectRatio), height: iconHeight)
            imageView.contentMode = .scaleAspectFit
            imageView.themeTintColor = themeTintColor
            stackView.addArrangedSubview(imageView)
        }
        
        if let title: String = title {
            let label: UILabel = UILabel()
            label.font = .systemFont(ofSize: Values.smallFontSize)
            label.text = title
            label.textAlignment = .center
            label.themeTextColor = themeTintColor
            label.minimumScaleFactor = 0.75
            label.numberOfLines = (title.components(separatedBy: " ").count > 1 ? 2 : 1)
            label.frame = CGRect(
                origin: .zero,
                // Note: It looks like there is a semi-max width of 68px for images in the swipe actions
                // if the image ends up larger then there an odd behaviour can occur where 8/10 times the
                // image is scaled down to fit, but ocassionally (primarily if you hide the action and
                // immediately swipe to show it again once the cell hits the edge of the screen) the image
                // won't be scaled down but will be full size - appearing as if two different images are used
                size: label.sizeThatFits(CGSize(width: 68, height: 999))
            )
            label.set(.width, to: label.frame.width)
            
            stackView.addArrangedSubview(label)
        }
        
        stackView.frame = CGRect(
            origin: .zero,
            size: stackView.systemLayoutSizeFitting(CGSize(width: 999, height: 999))
        )
        
        // Based on https://stackoverflow.com/a/41288197/1118398
        let renderFormat: UIGraphicsImageRendererFormat = UIGraphicsImageRendererFormat()
        renderFormat.scale = UIScreen.main.scale
        
        let renderer: UIGraphicsImageRenderer = UIGraphicsImageRenderer(
            size: stackView.bounds.size,
            format: renderFormat
        )
        return renderer.image { rendererContext in
            stackView.layer.render(in: rendererContext.cgContext)
        }
    }
    
    private static func firstSubviewOfType<T>(in superview: UIView) -> T? {
        guard !(superview is T) else { return superview as? T }
        guard !superview.subviews.isEmpty else { return nil }
        
        for subview in superview.subviews {
            if let result: T = firstSubviewOfType(in: subview) {
                return result
            }
        }
        
        return nil
    }
    
    static func willBeginEditing(indexPath: IndexPath, tableView: UITableView) {
        guard
            let targetCell: UITableViewCell = tableView.cellForRow(at: indexPath),
            targetCell.superview != tableView,
            let targetSuperview: UIView = targetCell.superview?
                .subviews
                .filter({ $0 != targetCell })
                .first,
            let side: Side = Side(for: targetSuperview),
            let themeMap: [Int: ThemeValue] = UIContextualAction.lookupMap
                .getting(tableView.hashValue)?
                .getting(side.key(for: indexPath)),
            targetSuperview.subviews.count == themeMap.count
        else { return }
        
        let targetViews: [UIImageView] = targetSuperview.subviews
            .compactMap { subview in firstSubviewOfType(in: subview) }
        
        guard targetViews.count == themeMap.count else { return }
        
        // Set the imageView and background colours (so they change correctly when the theme changes)
        targetViews.enumerated().forEach { index, targetView in
            guard let themeTintColor: ThemeValue = themeMap[index] else { return }
            
            targetView.themeTintColor = themeTintColor
        }
    }
    
    static func didEndEditing(indexPath: IndexPath?, tableView: UITableView) {
        guard let indexPath: IndexPath = indexPath else { return }
        
        let leadingKey: String = Side.leading.key(for: indexPath)
        let trailingKey: String = Side.trailing.key(for: indexPath)
        
        guard
            UIContextualAction.lookupMap[tableView.hashValue]?[leadingKey] != nil ||
            UIContextualAction.lookupMap[tableView.hashValue]?[trailingKey] != nil
        else { return }
        
        UIContextualAction._lookupMap.performUpdate { lookupMap in
            var updatedLookupMap: [Int: [String: [Int: ThemeValue]]] = lookupMap
            updatedLookupMap[tableView.hashValue]?[leadingKey] = nil
            updatedLookupMap[tableView.hashValue]?[trailingKey] = nil
            
            if updatedLookupMap[tableView.hashValue]?.isEmpty == true {
                updatedLookupMap[tableView.hashValue] = nil
            }
            
            return updatedLookupMap
        }
    }
}
