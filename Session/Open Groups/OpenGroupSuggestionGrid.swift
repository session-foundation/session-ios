// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import Combine
import NVActivityIndicatorView
import SessionNetworkingKit
import SessionMessagingKit
import SessionUIKit
import SessionUtilitiesKit

final class OpenGroupSuggestionGrid: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    private let dependencies: Dependencies
    private let itemsPerSection: Int = (UIDevice.current.isIPad ? 4 : 2)
    private var maxWidth: CGFloat
    private var state: State
    private var heightConstraint: NSLayoutConstraint!
    private var defaultRoomObservationTask: Task<Void, Never>?
    private var defaultRoomDisplayPictureObservationTask: Task<Void, Never>?
    
    var delegate: OpenGroupSuggestionGridDelegate?
    
    struct State: ObservableKeyProvider {
        let server: String
        let skipAuthentication: Bool
        let data: [Network.SOGS.Room]
        
        var observedKeys: Set<ObservableKey> {
            return Set(data.map {
                let id: String = OpenGroup.idFor(roomToken: $0.token, server: server)
                
                return ObservableKey.conversationUpdated(id)
            })
        }
    }
    
    // MARK: - UI
    
    private static let cellHeight: CGFloat = 40
    private static let separatorWidth = Values.separatorThickness
    fileprivate static let numHorizontalCells: Int = (UIDevice.current.isIPad ? 4 : 2)
    
    private lazy var layout: LastRowCenteredLayout = {
        let result = LastRowCenteredLayout()
        result.minimumLineSpacing = Values.mediumSpacing
        result.minimumInteritemSpacing = Values.mediumSpacing
        
        return result
    }()
    
    private lazy var collectionView: UICollectionView = {
        let result = UICollectionView(frame: .zero, collectionViewLayout: layout)
        result.themeBackgroundColor = .clear
        result.isScrollEnabled = false
        result.register(view: Cell.self)
        result.dataSource = self
        result.delegate = self
        
        return result
    }()
    
    private let spinner: NVActivityIndicatorView = {
        let result: NVActivityIndicatorView = NVActivityIndicatorView(
            frame: CGRect.zero,
            type: .circleStrokeSpin,
            color: .black,
            padding: nil
        )
        result.set(.width, to: OpenGroupSuggestionGrid.cellHeight)
        result.set(.height, to: OpenGroupSuggestionGrid.cellHeight)
        
        ThemeManager.onThemeChange(observer: result) { [weak result] theme, _, resolve in
            guard let textPrimary: UIColor = resolve(.textPrimary) else { return }
            
            result?.color = textPrimary
        }
        
        return result
    }()

    private lazy var errorView: UIView = {
        let result: UIView = UIView()
        result.isHidden = true
        
        return result
    }()
    
    private lazy var errorImageView: UIImageView = {
        let result: UIImageView = UIImageView(image: #imageLiteral(resourceName: "warning").withRenderingMode(.alwaysTemplate))
        result.themeTintColor = .danger
        
        return result
    }()
    
    private lazy var errorTitleLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = .systemFont(ofSize: Values.mediumFontSize, weight: .medium)
        result.text = "communityError".localized()
        result.themeTextColor = .textPrimary
        result.textAlignment = .center
        result.numberOfLines = 0
        
        return result
    }()
    
    private lazy var errorSubtitleLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = .systemFont(ofSize: Values.smallFontSize, weight: .medium)
        result.text = "communityErrorDescription".localized()
        result.themeTextColor = .textPrimary
        result.textAlignment = .center
        result.numberOfLines = 0
        
        return result
    }()
    
    // MARK: - Initialization
    
    init(maxWidth: CGFloat, using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.maxWidth = maxWidth
        self.state = State(
            server: Network.SOGS.defaultServer,
            skipAuthentication: true,
            data: []
        )
        
        super.init(frame: CGRect.zero)
        
        initialize()
    }
    
    override init(frame: CGRect) {
        preconditionFailure("Use init(maxWidth:) instead.")
    }
    
    required init?(coder: NSCoder) {
        preconditionFailure("Use init(maxWidth:) instead.")
    }
    
    deinit {
        defaultRoomObservationTask?.cancel()
        defaultRoomDisplayPictureObservationTask?.cancel()
    }
    
    private func initialize() {
        addSubview(collectionView)
        collectionView.pin(to: self)
        
        addSubview(spinner)
        spinner.pin(.top, to: .top, of: self)
        spinner.center(.horizontal, in: self)
        spinner.startAnimating()
        
        addSubview(errorView)
        errorView.pin(.top, to: .top, of: self, withInset: 10)
        errorView.pin( [HorizontalEdge.leading, HorizontalEdge.trailing], to: self)
        
        errorView.addSubview(errorImageView)
        errorImageView.pin(.top, to: .top, of: errorView)
        errorImageView.center(.horizontal, in: errorView)
        errorImageView.set(.width, to: 60)
        errorImageView.set(.height, to: 60)
        
        errorView.addSubview(errorTitleLabel)
        errorTitleLabel.pin(.top, to: .bottom, of: errorImageView, withInset: 10)
        errorTitleLabel.center(.horizontal, in: errorView)
        
        errorView.addSubview(errorSubtitleLabel)
        errorSubtitleLabel.pin(.top, to: .bottom, of: errorTitleLabel, withInset: 20)
        errorSubtitleLabel.center(.horizontal, in: errorView)
        
        heightConstraint = set(.height, to: OpenGroupSuggestionGrid.cellHeight)
        widthAnchor.constraint(greaterThanOrEqualToConstant: OpenGroupSuggestionGrid.cellHeight).isActive = true
        
        defaultRoomObservationTask = Task.detached(priority: .userInitiated) { [weak self, manager = dependencies[singleton: .communityManager], dependencies] in
            for await roomInfo in manager.defaultRooms {
                guard let self else { return }
                guard !roomInfo.rooms.isEmpty else { continue }
                
                /// Update the data
                let updatedState: State = await State(
                    server: self.state.server,
                    skipAuthentication: self.state.skipAuthentication,
                    data: roomInfo.rooms
                )
                
                await MainActor.run { [weak self] in
                    self?.state = updatedState
                    self?.update()
                    
                    /// Observe changes to the data (no need to update the state, just refresh the UI if images were downloaded)
                    self?.defaultRoomDisplayPictureObservationTask?.cancel()
                    self?.defaultRoomDisplayPictureObservationTask = ObservationBuilder
                        .initialValue(updatedState)
                        .debounce(for: .milliseconds(250))
                        .using(dependencies: dependencies)
                        .query({ previousState, _, _, _ -> State in previousState })
                        .assign { [weak self] _ in self?.update() }
                }
            }
        }
    }
    
    // MARK: - Updating
    
    private func update() {
        spinner.stopAnimating()
        spinner.isHidden = true
        
        let roomCount: CGFloat = CGFloat(min(state.data.count, 8)) // Cap to a maximum of 8 (4 rows of 2)
        let numRows: CGFloat = ceil(roomCount / CGFloat(OpenGroupSuggestionGrid.numHorizontalCells))
        let height: CGFloat = ((OpenGroupSuggestionGrid.cellHeight * numRows) + ((numRows - 1) * layout.minimumLineSpacing))
        heightConstraint.constant = height
        collectionView.reloadData()
        errorView.isHidden = (roomCount > 0)
    }
    
    public func refreshLayout(with maxWidth: CGFloat) {
        self.maxWidth = maxWidth
        collectionView.collectionViewLayout.invalidateLayout()
    }
    
    // MARK: - Layout
    
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let totalItems: Int = collectionView.numberOfItems(inSection: indexPath.section)
        let itemsInFinalRow: Int = (totalItems % OpenGroupSuggestionGrid.numHorizontalCells)
        
        guard indexPath.item >= (totalItems - itemsInFinalRow) && itemsInFinalRow != 0 else {
            let cellWidth: CGFloat = ((maxWidth / CGFloat(OpenGroupSuggestionGrid.numHorizontalCells)) - ((CGFloat(OpenGroupSuggestionGrid.numHorizontalCells) - 1) * layout.minimumInteritemSpacing))
            
            return CGSize(width: cellWidth, height: OpenGroupSuggestionGrid.cellHeight)
        }
        
        // If there isn't an even number of items then we want to calculate proper sizing
        return CGSize(
            width: Cell.calculatedWith(for: state.data[indexPath.item].name),
            height: OpenGroupSuggestionGrid.cellHeight
        )
    }
    
    // MARK: - Data Source
    
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return min(state.data.count, 8) // Cap to a maximum of 8 (4 rows of 2)
    }
    
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell: Cell = collectionView.dequeue(type: Cell.self, for: indexPath)
        cell.update(
            with: state.data[indexPath.item],
            server: state.server,
            skipAuthentication: state.skipAuthentication,
            using: dependencies
        )
        
        return cell
    }
    
    // MARK: - Interaction
    
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let room = state.data[indexPath.section * itemsPerSection + indexPath.item]
        delegate?.join(room)
        collectionView.deselectItem(at: indexPath, animated: true)
    }
}

// MARK: - Cell

extension OpenGroupSuggestionGrid {
    fileprivate final class Cell: UICollectionViewCell {
        private static let labelFont: UIFont = .systemFont(ofSize: Values.smallFontSize)
        private static let imageSize: CGFloat = 30
        private static let itemPadding: CGFloat = Values.smallSpacing
        private static let contentLeftPadding: CGFloat = 7
        private static let contentRightPadding: CGFloat = Values.veryLargeSpacing
        
        fileprivate static func calculatedWith(for title: String) -> CGFloat {
            // FIXME: Do the calculations properly in the 'LastRowCenteredLayout' to handle imageless cells
            return (
                contentLeftPadding +
                imageSize +
                itemPadding +
                NSAttributedString(string: title, attributes: [ .font: labelFont ]).size().width +
                contentRightPadding +
                1   // Not sure why this is needed but it seems things are sometimes truncated without it
            )
        }
        
        private lazy var snContentView: UIView = {
            let result: UIView = UIView()
            result.themeBorderColor = .borderSeparator
            result.layer.cornerRadius = Cell.contentViewCornerRadius
            result.layer.borderWidth = 1
            result.set(.height, to: Cell.contentViewHeight)
            
            return result
        }()
        
        private lazy var imageView: SessionImageView = {
            let result: SessionImageView = SessionImageView()
            result.set(.width, to: Cell.imageSize)
            result.set(.height, to: Cell.imageSize)
            result.layer.cornerRadius = (Cell.imageSize / 2)
            result.clipsToBounds = true
            
            return result
        }()
        
        private lazy var label: UILabel = {
            let result: UILabel = UILabel()
            result.font = Cell.labelFont
            result.themeTextColor = .textPrimary
            result.lineBreakMode = .byTruncatingTail
            
            return result
        }()
        
        private static let contentViewInset: CGFloat = 0
        private static var contentViewHeight: CGFloat { OpenGroupSuggestionGrid.cellHeight - 2 * contentViewInset }
        private static var contentViewCornerRadius: CGFloat { contentViewHeight / 2 }
        
        override init(frame: CGRect) {
            super.init(frame: frame)
            
            setUpViewHierarchy()
        }
        
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            
            setUpViewHierarchy()
        }
        
        private func setUpViewHierarchy() {
            backgroundView = UIView()
            backgroundView?.themeBackgroundColor = .backgroundPrimary
            backgroundView?.layer.cornerRadius = Cell.contentViewCornerRadius
            
            selectedBackgroundView = UIView()
            selectedBackgroundView?.themeBackgroundColor = .backgroundSecondary
            selectedBackgroundView?.layer.cornerRadius = Cell.contentViewCornerRadius
            
            addSubview(snContentView)
            
            let stackView = UIStackView(arrangedSubviews: [ imageView, label ])
            stackView.axis = .horizontal
            stackView.spacing = Cell.itemPadding
            snContentView.addSubview(stackView)
            
            stackView.center(.vertical, in: snContentView)
            stackView.pin(.leading, to: .leading, of: snContentView, withInset: Cell.contentLeftPadding)
            
            snContentView.trailingAnchor
                .constraint(
                    greaterThanOrEqualTo: stackView.trailingAnchor,
                    constant: Cell.contentRightPadding
                )
                .isActive = true
            snContentView.pin(to: self)
        }
        
        fileprivate func update(
            with room: Network.SOGS.Room,
            server: String,
            skipAuthentication: Bool,
            using dependencies: Dependencies
        ) {
            label.text = room.name
            
            guard let imageId: String = room.imageId else {
                imageView.isHidden = true
                return
            }
            guard
                let path: String = try? dependencies[singleton: .displayPictureManager].path(
                    for: Network.SOGS.downloadUrlString(for: imageId, server: server, roomToken: room.token)
                ),
                dependencies[singleton: .fileManager].fileExists(atPath: path)
            else {
                dependencies[singleton: .displayPictureManager].scheduleDownload(
                    for: .community(
                        imageId: imageId,
                        roomToken: room.token,
                        server: server,
                        skipAuthentication: skipAuthentication
                    )
                )
                imageView.isHidden = true
                return
            }
            
            imageView.isHidden = false
            imageView.setDataManager(dependencies[singleton: .imageDataManager])
            imageView.loadImage(from: path)
        }
    }
}

// MARK: - Delegate

protocol OpenGroupSuggestionGridDelegate {
    func join(_ room: Network.SOGS.Room)
}

// MARK: - LastRowCenteredLayout

class LastRowCenteredLayout: UICollectionViewFlowLayout {
    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        // If we have an odd number of items then we want to center the last one horizontally
        let elementAttributes: [UICollectionViewLayoutAttributes]? = super.layoutAttributesForElements(in: rect)
        
        // It looks like on "max" devices the rect we are given can be much larger than the size of the
        // collection view, as a result we need to try and use the collectionView width here instead
        let targetViewWidth: CGFloat = {
            guard let collectionView: UICollectionView = self.collectionView, collectionView.frame.width > 0 else {
                return rect.width
            }
            
            return collectionView.frame.width
        }()
        
        guard
            let remainingItems: Int = elementAttributes.map({ $0.count % OpenGroupSuggestionGrid.numHorizontalCells }),
            remainingItems != 0,
            let lastItems: [UICollectionViewLayoutAttributes] = elementAttributes?.suffix(remainingItems),
            !lastItems.isEmpty
        else { return elementAttributes }
        
        let totalItemWidth: CGFloat = lastItems
            .map { $0.frame.size.width }
            .reduce(0, +)
        let lastRowWidth: CGFloat = (totalItemWidth + (CGFloat(lastItems.count - 1) * minimumInteritemSpacing))
        
        // Offset the start width by half of the remaining space
        var itemXPos: CGFloat = ((targetViewWidth - lastRowWidth) / 2)
        
        lastItems.forEach { item in
            item.frame = CGRect(
                x: itemXPos,
                y: item.frame.origin.y,
                width: item.frame.size.width,
                height: item.frame.size.height
            )
            
            itemXPos += (item.frame.size.width + minimumInteritemSpacing)
        }
        
        return elementAttributes
    }
}
