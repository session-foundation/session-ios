// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit

public final class MentionSelectionView: UIView, UITableViewDataSource, UITableViewDelegate {
    public static let profilePictureViewSize: ProfilePictureView.Info.Size = .message
    
    public struct ViewModel {
        public static let mentionChar: String = "@" // stringlint:ignore
        
        public let profileId: String
        public let displayName: String
        public let profilePictureInfo: ProfilePictureView.Info
        
        public init(profileId: String, displayName: String, profilePictureInfo: ProfilePictureView.Info) {
            self.profileId = profileId
            self.displayName = displayName
            self.profilePictureInfo = profilePictureInfo
        }
    }
    
    private let dataManager: ImageDataManagerType
    public weak var delegate: MentionSelectionViewDelegate?
    public var candidates: [ViewModel] = [] {
        didSet {
            tableView.isScrollEnabled = (candidates.count > 4)
            tableView.reloadData()
        }
    }
    
    public var contentOffset: CGPoint {
        get { tableView.contentOffset }
        set { tableView.contentOffset = newValue }
    }

    // MARK: - Components
    
    private lazy var tableView: UITableView = {
        let result: UITableView = UITableView()
        result.dataSource = self
        result.delegate = self
        result.separatorStyle = .none
        result.themeBackgroundColor = .clear
        result.showsVerticalScrollIndicator = false
        result.register(view: Cell.self)
        
        return result
    }()

    // MARK: - Initialization
    
    public init(dataManager: ImageDataManagerType) {
        self.dataManager = dataManager
        
        super.init(frame: .zero)
        
        setUpViewHierarchy()
    }
    
    @available(*, unavailable, message: "use other init(dataManager:) instead.")
    required public init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setUpViewHierarchy() {
        // Table view
        addSubview(tableView)
        tableView.pin(to: self)
        
        // Top separator
        let topSeparator: UIView = UIView()
        topSeparator.themeBackgroundColor = .borderSeparator
        topSeparator.set(.height, to: Values.separatorThickness)
        addSubview(topSeparator)
        topSeparator.pin(.leading, to: .leading, of: self)
        topSeparator.pin(.top, to: .top, of: self)
        topSeparator.pin(.trailing, to: .trailing, of: self)
        
        // Bottom separator
        let bottomSeparator: UIView = UIView()
        bottomSeparator.themeBackgroundColor = .borderSeparator
        bottomSeparator.set(.height, to: Values.separatorThickness)
        addSubview(bottomSeparator)
        
        bottomSeparator.pin(.leading, to: .leading, of: self)
        bottomSeparator.pin(.trailing, to: .trailing, of: self)
        bottomSeparator.pin(.bottom, to: .bottom, of: self)
    }

    // MARK: - Data
    
    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return candidates.count
    }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell: Cell = tableView.dequeue(type: Cell.self, for: indexPath)
        cell.update(
            with: candidates[indexPath.row],
            isLast: (indexPath.row == (candidates.count - 1)),
            dataManager: dataManager
        )
        cell.accessibilityIdentifier = "Contact"
        cell.accessibilityLabel = candidates[indexPath.row].displayName
        cell.isAccessibilityElement = true
        
        return cell
    }

    // MARK: - Interaction
    
    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let mentionCandidate = candidates[indexPath.row]
        
        delegate?.handleMentionSelected(mentionCandidate, from: self)
    }
}

// MARK: - Cell

private extension MentionSelectionView {
    final class Cell: UITableViewCell {
        // MARK: - UI
        
        private lazy var profilePictureView: ProfilePictureView = ProfilePictureView(
            size: profilePictureViewSize,
            dataManager: nil
        )

        private lazy var displayNameLabel: UILabel = {
            let result: UILabel = UILabel()
            result.font = .systemFont(ofSize: Values.smallFontSize)
            result.themeTextColor = .textPrimary
            result.lineBreakMode = .byTruncatingTail
            
            return result
        }()

        lazy var separator: UIView = {
            let result: UIView = UIView()
            result.themeBackgroundColor = .borderSeparator
            result.set(.height, to: Values.separatorThickness)
            
            return result
        }()

        // MARK: - Initialization
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            
            setUpViewHierarchy()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            
            setUpViewHierarchy()
        }

        private func setUpViewHierarchy() {
            // Cell background color
            themeBackgroundColor = .settings_tabBackground
            
            // Highlight color
            let selectedBackgroundView = UIView()
            selectedBackgroundView.themeBackgroundColor = .highlighted(.settings_tabBackground)
            self.selectedBackgroundView = selectedBackgroundView
            
            // Main stack view
            let mainStackView = UIStackView(arrangedSubviews: [ profilePictureView, displayNameLabel ])
            mainStackView.axis = .horizontal
            mainStackView.alignment = .center
            mainStackView.spacing = Values.mediumSpacing
            mainStackView.set(.height, to: ProfilePictureView.Info.Size.message.viewSize)
            contentView.addSubview(mainStackView)
            mainStackView.pin(.leading, to: .leading, of: contentView, withInset: Values.mediumSpacing)
            mainStackView.pin(.top, to: .top, of: contentView, withInset: Values.smallSpacing)
            contentView.pin(.trailing, to: .trailing, of: mainStackView, withInset: Values.mediumSpacing)
            contentView.pin(.bottom, to: .bottom, of: mainStackView, withInset: Values.smallSpacing)
            mainStackView.set(.width, to: UIScreen.main.bounds.width - 2 * Values.mediumSpacing)
            
            // Separator
            addSubview(separator)
            separator.pin(.leading, to: .leading, of: self)
            separator.pin(.trailing, to: .trailing, of: self)
            separator.pin(.bottom, to: .bottom, of: self)
        }

        // MARK: - Updating
        
        fileprivate func update(
            with viewModel: MentionSelectionView.ViewModel,
            isLast: Bool,
            dataManager: ImageDataManagerType
        ) {
            displayNameLabel.text = viewModel.displayName
            profilePictureView.setDataManager(dataManager)
            profilePictureView.update(viewModel.profilePictureInfo)
            separator.isHidden = isLast
        }
    }
}

// MARK: - Delegate

public protocol MentionSelectionViewDelegate: AnyObject {
    @MainActor func handleMentionSelected(_ viewModel: MentionSelectionView.ViewModel, from view: MentionSelectionView)
}

// MARK: - Convenience

public extension Collection where Element == MentionSelectionView.ViewModel {
    func update(_ string: String) -> String {
        let mentionChar: String = MentionSelectionView.ViewModel.mentionChar
        var result: String = string
        
        for mention in self {
            guard let range: Range<String.Index> = result.range(of: "\(mentionChar)\(mention.displayName)") else {
                continue
            }
            
            result = result.replacingCharacters(in: range, with: "\(mentionChar)\(mention.profileId)")
        }
        
        return result
    }
}
