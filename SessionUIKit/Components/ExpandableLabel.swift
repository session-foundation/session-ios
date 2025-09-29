// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import UIKit

public class ExpandableLabel: UIView {
    private var oldSize: CGSize = .zero
    private var layoutLoopCounter: Int = 0
    private var isExpanded: Bool = false
    private var toggleDebounceTimer: Timer?
    public var onToggleExpansion: (@MainActor () -> Void)?

    public var font: UIFont {
        get { label.font }
        set {
            label.font = newValue
            buttonLabel.font = .boldSystemFont(ofSize: newValue.pointSize)
        }
    }
    
    public var text: String? {
        get { label.text }
        set {
            guard label.text != newValue else { return }
            
            label.text = newValue
            updateContentSizeIfNeeded()
        }
    }
    
    public var themeAttributedText: ThemedAttributedString? {
        get { label.themeAttributedText }
        set {
            guard label.themeAttributedText != newValue else { return }
            
            label.themeAttributedText = newValue
            updateContentSizeIfNeeded()
        }
    }
    
    public var themeTextColor: ThemeValue? {
        get { label.themeTextColor }
        set { label.themeTextColor = newValue }
    }
    
    public var textAlignment: NSTextAlignment {
        get { label.textAlignment }
        set { label.textAlignment = newValue }
    }
    
    public var lineBreakMode: NSLineBreakMode {
        get { label.lineBreakMode }
        set { label.lineBreakMode = newValue }
    }
    
    public var numberOfLines: Int {
        get { label.numberOfLines }
        set { label.numberOfLines = newValue }
    }
    
    public var maxNumberOfLines: Int = 0 {
        didSet {
            guard maxNumberOfLines != oldValue else { return }
            
            updateContentSizeIfNeeded()
        }
    }
    
    // MARK: - Initialization
    
    public init() {
        super.init(frame: .zero)
        setupViews()
        setupGestureRecognizer()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - UI Components
    
    private let label: UILabel = UILabel()
    private let buttonLabel: UILabel = UILabel()
    
    // MARK: - Layout
    
    private func setupViews() {
        let stackView = UIStackView(arrangedSubviews: [label, buttonLabel])
        stackView.axis = .vertical
        stackView.spacing = Values.smallSpacing
        addSubview(stackView)
        stackView.pin(to: self)

        buttonLabel.textAlignment = .center
        buttonLabel.font = .boldSystemFont(ofSize: label.font.pointSize)
        buttonLabel.themeTextColor = .textPrimary
        buttonLabel.text = "viewMore".localized()
    }

    private func setupGestureRecognizer() {
        let tapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleTapGesture))
        addGestureRecognizer(tapGestureRecognizer)
    }
    
    public override func layoutSubviews() {
        super.layoutSubviews()
        
        guard frame.size != oldSize else {
            layoutLoopCounter = 0
            return
        }
        
        updateContentSizeIfNeeded()
    }
    
    private func updateContentSizeIfNeeded() {
        // Ensure we don't get stuck in an infinite layout loop somehow
        guard layoutLoopCounter < 5 else { return }
        
        let lineCount = calculateLineCount(
            text: text ?? themeAttributedText?.string ?? "",
            font: font,
            width: bounds.width
        )
        
        if lineCount > maxNumberOfLines {
            label.numberOfLines = isExpanded ? 0 : (maxNumberOfLines - 1)
            buttonLabel.isHidden = false
        } else {
            label.numberOfLines = 0
            buttonLabel.isHidden = true
        }
        
        oldSize = frame.size
        layoutLoopCounter += 1
        setNeedsLayout()
        layoutIfNeeded()
    }
    
    private func calculateLineCount(text: String, font: UIFont, width: CGFloat) -> Int {
        let textStorage = NSTextStorage(string: text, attributes: [.font: font])
        let textContainer = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        textContainer.lineBreakMode = .byWordWrapping
        textContainer.maximumNumberOfLines = 0

        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)

        layoutManager.glyphRange(for: textContainer)

        var numberOfLines = 0
        var index = 0
        var lineRange = NSRange()

        while index < layoutManager.numberOfGlyphs {
            layoutManager.lineFragmentRect(forGlyphAt: index, effectiveRange: &lineRange)
            index = NSMaxRange(lineRange)
            numberOfLines += 1
        }

        return numberOfLines
    }
    
    // MARK: - Interaction
    
    @MainActor private func toggleExpansion() {
        isExpanded.toggle()
        buttonLabel.text = (isExpanded ? "viewLess".localized() : "viewMore".localized())
        label.numberOfLines = isExpanded ? 0 : (maxNumberOfLines - 1)
        label.invalidateIntrinsicContentSize()
        layoutIfNeeded()
        onToggleExpansion?()
    }
    
    @objc private func handleTapGesture() {
        guard !buttonLabel.isHidden else { return }
        
        toggleDebounceTimer?.invalidate()
        toggleDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.toggleExpansion() }
        }
    }
}
