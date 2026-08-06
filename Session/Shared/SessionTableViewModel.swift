// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Combine
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

protocol SessionTableViewModel: AnyObject, SectionedTableData {
    var dependencies: Dependencies { get }
    
    var searchable: Bool { get }
    /// **The `@MainActor` members below read main-actor view state, so the requirement carries the isolation.**
    ///
    /// A witness inherits global-actor isolation from the requirement it satisfies, which is what makes this preventative
    /// rather than corrective: a conformer that declares a plain `lazy var footerButtonInfo = $internalState.map { … }` is
    /// isolated anyway, so the lazy initialiser cannot build its subscription off the main actor while the observation task
    /// is sending on the same publisher. That race segfaulted inside `PublishedSubject.send`.
    ///
    /// `title`, `subtitle` and `footerView` are included on the same evidence: each already had at least one conformer
    /// declaring it `@MainActor` while this requirement did not, which is the same mismatch one step from becoming the same
    /// bug. The remaining members have no such implementation and are left alone
    @MainActor var title: String { get }
    @MainActor var subtitle: String? { get }
    var initialLoadMessage: String? { get }
    var cellType: SessionTableViewCellType { get }
    var bannerInfo: AnyPublisher<InfoBanner.Info?, Never> { get }
    var emptyStateTextPublisher: AnyPublisher<String?, Never> { get }
    var state: TableDataState<Section, TableItem> { get }
    @MainActor var footerView: AnyPublisher<UIView?, Never> { get }
    @MainActor var footerButtonInfo: AnyPublisher<SessionButton.Info?, Never> { get }
    
    // MARK: - Functions
    
    func canEditRow(at indexPath: IndexPath) -> Bool
    func leadingSwipeActionsConfiguration(forRowAt indexPath: IndexPath, in tableView: UITableView, of viewController: UIViewController) -> UISwipeActionsConfiguration?
    func trailingSwipeActionsConfiguration(forRowAt indexPath: IndexPath, in tableView: UITableView, of viewController: UIViewController) -> UISwipeActionsConfiguration?
    @MainActor func onAppear(targetViewController: BaseVC)
}

extension SessionTableViewModel {
    var searchable: Bool { false }
    @MainActor var subtitle: String? { nil }
    var initialLoadMessage: String? { nil }
    var cellType: SessionTableViewCellType { .general }
    var bannerInfo: AnyPublisher<InfoBanner.Info?, Never> { Just(nil).eraseToAnyPublisher() }
    var emptyStateTextPublisher: AnyPublisher<String?, Never> { Just(nil).eraseToAnyPublisher() }
    var tableData: [SectionModel] { state.tableData }
    @MainActor var footerView: AnyPublisher<UIView?, Never> { Just(nil).eraseToAnyPublisher() }
    @MainActor var footerButtonInfo: AnyPublisher<SessionButton.Info?, Never> { Just(nil).eraseToAnyPublisher() }
    
    // MARK: - Functions
    
    func updateTableData(_ updatedData: [SectionModel]) { state.updateTableData(updatedData) }
    
    func canEditRow(at indexPath: IndexPath) -> Bool { false }
    func leadingSwipeActionsConfiguration(forRowAt indexPath: IndexPath, in tableView: UITableView, of viewController: UIViewController) -> UISwipeActionsConfiguration? { nil }
    func trailingSwipeActionsConfiguration(forRowAt indexPath: IndexPath, in tableView: UITableView, of viewController: UIViewController) -> UISwipeActionsConfiguration? { nil }
    func onAppear(targetViewController: BaseVC) { }
}

// MARK: - SessionTableViewCellType

enum SessionTableViewCellType: CaseIterable {
    case general
    case fullConversation
    
    var viewType: UITableViewCell.Type {
        switch self {
            case .general: return SessionCell.self
            case .fullConversation: return FullConversationCell.self
        }
    }
}
