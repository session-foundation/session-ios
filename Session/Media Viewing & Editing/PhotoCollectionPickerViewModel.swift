// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

class PhotoCollectionPickerViewModel: SessionTableViewModel, ObservableTableSource {
    public let dependencies: Dependencies
    public let state: TableDataState<Section, TableItem> = TableDataState()
    public let observableState: ObservableTableSourceState<Section, TableItem> = ObservableTableSourceState()
    
    private let library: PhotoLibrary
    private let thumbnailSize: ImageDataManager.ThumbnailSize = .small
    private let thumbnailPixelDimension: CGFloat
    private let onCollectionSelected: (PhotoCollection) -> Void
    private var photoCollections: CurrentValueSubject<[PhotoCollection], Error>

    // MARK: - Initialization

    init(
        library: PhotoLibrary,
        using dependencies: Dependencies,
        onCollectionSelected: @escaping (PhotoCollection) -> Void
    ) {
        self.dependencies = dependencies
        self.library = library
        self.thumbnailPixelDimension = thumbnailSize.pixelDimension()
        self.onCollectionSelected = onCollectionSelected
        self.photoCollections = CurrentValueSubject(library.allPhotoCollections(using: dependencies))
    }
    
    // MARK: - Config
    
    public enum Section: SessionTableSection {
        case content
    }
    
    public struct TableItem: Hashable, Differentiable {
        public typealias DifferenceIdentifier = String
        
        private let collection: PhotoCollection
        public var differenceIdentifier: String { collection.id }
        
        init(collection: PhotoCollection) {
            self.collection = collection
        }
        
        public func isContentEqual(to source: TableItem) -> Bool {
            return (collection.id == source.collection.id)
        }
        
        public func hash(into hasher: inout Hasher) {
            collection.id.hash(into: &hasher)
        }
    }

    // MARK: - Content

    let title: String = "notificationsSound".localized()

    lazy var observation: TargetObservation = ObservationBuilderOld
        .subject(photoCollections)
        .map { [thumbnailSize, thumbnailPixelDimension, dependencies] collections -> [SectionModel] in
            [
                SectionModel(
                    model: .content,
                    elements: collections.map { collection in
                        let contents: PhotoCollectionContents = collection.contents(using: dependencies)
                        let lastAssetItem: PhotoPickerAssetItem? = contents.lastAssetItem(size: thumbnailSize, pixelDimension: thumbnailPixelDimension)
                        
                        return SessionCell.Info(
                            id: TableItem(collection: collection),
                            canReuseCell: true,
                            leadingAccessory: .iconAsync(
                                size: .extraLarge,
                                source: lastAssetItem?.source,
                                shouldFill: true
                            ),
                            title: collection.localizedTitle(),
                            subtitle: "\(contents.assetCount)",
                            onTap: { [weak self] in
                                self?.onCollectionSelected(collection)
                            }
                        )
                    }
                )
            ]
        }
    
    // MARK: PhotoLibraryDelegate

    func photoLibraryDidChange(_ photoLibrary: PhotoLibrary) {
        self.photoCollections.send(library.allPhotoCollections(using: dependencies))
    }
}
