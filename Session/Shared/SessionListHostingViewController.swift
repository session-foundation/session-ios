// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Combine
import SessionUIKit

class SessionListHostingViewController<ViewModel>: SessionHostingViewController<SessionListScreen<ViewModel>> where ViewModel: SessionListScreenContent.ViewModelType {
    private let viewModel: ViewModel
    private var disposables: Set<AnyCancellable> = Set()
    
    // MARK: - Initialization
    
    init(
        viewModel: ViewModel,
        customizedNavigationBackground: ThemeValue? = nil,
        shouldHideNavigationBar: Bool = false
    ) {
        self.viewModel = viewModel
        super.init(
            rootView: SessionListScreen(viewModel: viewModel),
            customizedNavigationBackground: customizedNavigationBackground,
            shouldHideNavigationBar: shouldHideNavigationBar
        )
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setNavBarTitle(viewModel.title)
        setupBinding()
    }
    
    // MARK: - Binding

    private func setupBinding() {
        (viewModel as? (any NavigationItemSource))?.setupBindings(
            viewController: self,
            disposables: &disposables
        )
        (viewModel as? (any NavigatableStateHolder))?.navigatableState.setupBindings(
            viewController: self,
            disposables: &disposables
        )
    }
}
