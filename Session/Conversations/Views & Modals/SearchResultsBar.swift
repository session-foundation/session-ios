// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

public final class SearchResultsBar: UIView {
    @ThreadSafe private var hasResults: Bool = false
    @ThreadSafeObject private var results: [Interaction.TimestampInfo] = []
    private let onResultIndexChange: (Int, [Interaction.PagedDataType.TimestampInfo]) -> Void
    
    var currentIndex: Int?
    
    public override var intrinsicContentSize: CGSize { CGSize.zero }
    
    // MARK: - Initialization
    
    init(onResultIndexChange: @escaping (Int, [Interaction.PagedDataType.TimestampInfo]) -> Void) {
        self.onResultIndexChange = onResultIndexChange
        
        super.init(frame: .zero)
        
        setUpViewHierarchy()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - UI
    
    private lazy var label: UILabel = {
        let result = UILabel()
        result.font = .boldSystemFont(ofSize: Values.smallFontSize)
        result.themeTextColor = .textPrimary
        
        return result
    }()
    
    private lazy var upButton: UIButton = {
        let icon = #imageLiteral(resourceName: "ic_chevron_up").withRenderingMode(.alwaysTemplate)
        let result: UIButton = UIButton()
        result.setImage(icon, for: UIControl.State.normal)
        result.themeTintColor = .primary
        result.addTarget(self, action: #selector(handleUpButtonTapped), for: UIControl.Event.touchUpInside)
        
        return result
    }()
    
    private lazy var downButton: UIButton = {
        let icon = #imageLiteral(resourceName: "ic_chevron_down").withRenderingMode(.alwaysTemplate)
        let result: UIButton = UIButton()
        result.setImage(icon, for: UIControl.State.normal)
        result.themeTintColor = .primary
        result.addTarget(self, action: #selector(handleDownButtonTapped), for: UIControl.Event.touchUpInside)
        
        return result
    }()
    
    private lazy var loadingIndicator: UIActivityIndicatorView = {
        let result = UIActivityIndicatorView(style: .medium)
        result.themeColor = .textPrimary
        result.alpha = 0.5
        result.hidesWhenStopped = true
        
        return result
    }()
    
    // MARK: - Lifecycle
    
    
    private func setUpViewHierarchy() {
        autoresizingMask = .flexibleHeight
        
        // Separator
        let separator = UIView()
        separator.themeBackgroundColor = .borderSeparator
        separator.set(.height, to: Values.separatorThickness)
        addSubview(separator)
        separator.pin([ UIView.HorizontalEdge.leading, UIView.VerticalEdge.top, UIView.HorizontalEdge.trailing ], to: self)
        
        // Spacers
        let spacer1 = UIView.hStretchingSpacer()
        let spacer2 = UIView.hStretchingSpacer()
        
        // Button containers
        let upButtonContainer = UIView(wrapping: upButton, withInsets: UIEdgeInsets(top: 2, left: 0, bottom: 0, right: 0))
        let downButtonContainer = UIView(wrapping: downButton, withInsets: UIEdgeInsets(top: 0, left: 0, bottom: 2, right: 0))
        
        // Main stack view
        let mainStackView = UIStackView(arrangedSubviews: [ upButtonContainer, downButtonContainer, spacer1, label, spacer2 ])
        mainStackView.axis = .horizontal
        mainStackView.spacing = Values.mediumSpacing
        mainStackView.isLayoutMarginsRelativeArrangement = true
        mainStackView.layoutMargins = UIEdgeInsets(top: Values.smallSpacing, leading: Values.largeSpacing, bottom: Values.smallSpacing, trailing: Values.largeSpacing)
        addSubview(mainStackView)
        
        mainStackView.pin(.top, to: .bottom, of: separator)
        mainStackView.pin([ UIView.HorizontalEdge.leading, UIView.HorizontalEdge.trailing ], to: self)
        mainStackView.pin(.bottom, to: .bottom, of: self, withInset: -2)
        
        addSubview(loadingIndicator)
        loadingIndicator.pin(.left, to: .right, of: label, withInset: 10)
        loadingIndicator.centerYAnchor.constraint(equalTo: label.centerYAnchor).isActive = true
        
        // Remaining constraints
        label.center(.horizontal, in: self)
    }
    
    // MARK: - Actions
    
    @objc public func handleUpButtonTapped() {
        guard hasResults else { return }
        guard let currentIndex: Int = currentIndex else { return }
        guard currentIndex + 1 < results.count else { return }

        let newIndex = currentIndex + 1
        self.currentIndex = newIndex
        updateBarItems()
        onResultIndexChange(newIndex, results)
    }

    @objc public func handleDownButtonTapped() {
        guard hasResults else { return }
        guard let currentIndex: Int = currentIndex, currentIndex > 0 else { return }

        let newIndex = currentIndex - 1
        self.currentIndex = newIndex
        updateBarItems()
        onResultIndexChange(newIndex, results)
    }
    
    // MARK: - Content
    
    func updateResults(results: [Interaction.TimestampInfo]?, visibleItemIds: [Int64]?) {
        // We want to ignore search results that don't match the current searchId (this
        // will happen when searching large threads with short terms as the shorter terms
        // will take much longer to resolve than the longer terms)
        currentIndex = {
            guard let results: [Interaction.TimestampInfo] = results, !results.isEmpty else { return nil }
            
            // Check if there is a visible item which matches the results and if so use that index (use
            // the `lastIndex` as we want to select the message closest to the top of the screen)
            if let visibleItemIds: [Int64] = visibleItemIds, let targetIndex: Int = results.lastIndex(where: { visibleItemIds.contains($0.id) }) {
                return targetIndex
            }
            
            if let currentIndex: Int = currentIndex {
                return max(0, min(currentIndex, results.count - 1))
            }
            
            return 0
        }()

        self._results.performUpdate { _ in (results ?? []) }
        self.hasResults = (results != nil)

        updateBarItems()
        
        if let currentIndex = currentIndex, let results = results {
            onResultIndexChange(currentIndex, results)
        }
    }
    
    func clearResults() {
        hasResults = false
        label.text = ""
        downButton.isEnabled = false
        upButton.isEnabled = false
        stopLoading()
    }

    func updateBarItems() {
        guard hasResults else {
            label.text = ""
            downButton.isEnabled = false
            upButton.isEnabled = false
            stopLoading()
            return
        }
        
        label.text = {
            guard results.count > 0 else {
                return "searchMatchesNone".localized()
            }
            
            return "searchMatches"
                .putNumber(results.count)
                .put(key: "found_count", value: (currentIndex ?? 0) + 1)
                .localized()
        }()

        if let currentIndex: Int = currentIndex {
            downButton.isEnabled = currentIndex > 0
            upButton.isEnabled = (currentIndex + 1 < results.count)
        }
        else {
            downButton.isEnabled = false
            upButton.isEnabled = false
        }
    }
    
    public func startLoading() {
        loadingIndicator.startAnimating()
    }
    
    public func stopLoading() {
        loadingIndicator.stopAnimating()
    }
}
