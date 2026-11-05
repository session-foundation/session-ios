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
    private var photoCollections: CurrentValueSubject<[LoadedCollection], Error>
    private var loadTask: Task<Void, Never>?

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
        self.photoCollections = CurrentValueSubject([])
        
        loadPhotoCollections()
    }
    
    /// Fetching every album and each album's contents can take seconds with a large library, and this view model is created on the
    /// main thread as the image picker appears
    ///
    /// **Note:** The contents are fetched here rather than in `observation` because the picker keeps this view model and
    /// resubscribes each time the album list is shown, and `photoCollections` replays its value on the subscribing (main) thread
    private func loadPhotoCollections() {
        loadTask?.cancel()
        loadTask = Task.detached(priority: .userInitiated) { [weak self, library, dependencies, thumbnailSize, thumbnailPixelDimension] in
            let collections: [LoadedCollection] = library.allPhotoCollections(using: dependencies).map { collection in
                let contents: PhotoCollectionContents = collection.contents(using: dependencies)
                
                return LoadedCollection(
                    collection: collection,
                    title: collection.localizedTitle(),
                    assetCount: contents.assetCount,
                    lastAssetItem: contents.lastAssetItem(size: thumbnailSize, pixelDimension: thumbnailPixelDimension)
                )
            }
            
            /// A newer load was started while this one ran, so this result may be out of date
            guard !Task.isCancelled else { return }
            
            self?.photoCollections.send(collections)
        }
    }
    
    // MARK: - Config
    
    private struct LoadedCollection: Equatable {
        let collection: PhotoCollection
        let title: String
        let assetCount: Int
        let lastAssetItem: PhotoPickerAssetItem?
        
        static func == (lhs: LoadedCollection, rhs: LoadedCollection) -> Bool {
            return (
                lhs.collection == rhs.collection &&
                lhs.title == rhs.title &&
                lhs.assetCount == rhs.assetCount &&
                lhs.lastAssetItem?.asset == rhs.lastAssetItem?.asset
            )
        }
    }
    
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
        .map { collections -> [SectionModel] in
            [
                SectionModel(
                    model: .content,
                    elements: collections.map { loaded in
                        SessionCell.Info(
                            id: TableItem(collection: loaded.collection),
                            canReuseCell: true,
                            leadingAccessory: .iconAsync(
                                size: .extraLarge,
                                source: loaded.lastAssetItem?.source,
                                shouldFill: true
                            ),
                            title: loaded.title,
                            subtitle: "\(loaded.assetCount)",
                            onTap: { [weak self] in
                                self?.onCollectionSelected(loaded.collection)
                            }
                        )
                    }
                )
            ]
        }
    
    // MARK: PhotoLibraryDelegate

    func photoLibraryDidChange(_ photoLibrary: PhotoLibrary) {
        loadPhotoCollections()
    }
}
