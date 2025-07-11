// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit

public class ToastController: ToastViewDelegate {
    public static let font: UIFont = .systemFont(ofSize: Values.mediumFontSize)
    public static let boldFont: UIFont = .boldSystemFont(ofSize: Values.mediumFontSize)
    static var currentToastController: ToastController?

    private let id: UUID
    private let toastView: ToastView
    private var isDismissing: Bool

    // MARK: Initializers
    
    public convenience init(text: String, background: ThemeValue) {
        self.init(text: ThemedAttributedString(string: text), background: background)
    }

    required public init(text: ThemedAttributedString, background: ThemeValue) {
        id = UUID()
        toastView = ToastView(background: background)
        toastView.attributedText = text
        isDismissing = false
        toastView.delegate = self
    }

    // MARK: Public

    public func presentToastView(
        fromBottomOfView view: UIView,
        inset: CGFloat,
        duration: DispatchTimeInterval = .milliseconds(1500)
    ) {
        toastView.alpha = 0
        view.addSubview(toastView)
        
        toastView.setContentCompressionResistancePriority(.required, for: .vertical)
        toastView.setContentCompressionResistancePriority(.required, for: .horizontal)
        toastView.center(.horizontal, in: view)
        toastView.pin(.bottom, to: .bottom, of: view, withInset: -inset)
        toastView.widthAnchor
            .constraint(
                lessThanOrEqualTo: view.widthAnchor,
                constant: -(Values.mediumSpacing * 2)
            )
            .isActive = true

        if let currentToastController = ToastController.currentToastController {
            currentToastController.dismissToastView()
            ToastController.currentToastController = nil
        }
        ToastController.currentToastController = self

        UIView.animate(withDuration: 0.1) {
            self.toastView.alpha = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            // intentional strong reference to self.
            // As with an AlertController, the caller likely expects toast to
            // be presented and dismissed without maintaining a strong reference to ToastController
            self.dismissToastView()
        }
    }

    // MARK: ToastViewDelegate

    func didTapToastView(_ toastView: ToastView) {
        self.dismissToastView()
    }

    func didSwipeToastView(_ toastView: ToastView) {
        self.dismissToastView()
    }

    // MARK: Internal

    func dismissToastView() {
        guard !isDismissing else { return }
        
        isDismissing = true

        if ToastController.currentToastController?.id == self.id {
            ToastController.currentToastController = nil
        }

        UIView.animate(
            withDuration: 0.1,
            animations: {
                self.toastView.alpha = 0
            },
            completion: { [weak self] _ in
                self?.toastView.removeFromSuperview()
            }
        )
    }
}

protocol ToastViewDelegate: AnyObject {
    func didTapToastView(_ toastView: ToastView)
    func didSwipeToastView(_ toastView: ToastView)
}

class ToastView: UIView {

    var attributedText: ThemedAttributedString? {
        get { return label.themeAttributedText }
        set { label.themeAttributedText = newValue }
    }
    weak var delegate: ToastViewDelegate?

    private let label: UILabel = {
        let result: UILabel = UILabel()
        result.font = ToastController.font
        result.themeTextColor = .textPrimary
        result.textAlignment = .center
        result.numberOfLines = 0
        
        return result
    }()

    // MARK: Initializers

    init(background: ThemeValue) {
        super.init(frame: .zero)

        self.themeBackgroundColor = background
        
        self.addSubview(label)
        label.pin(.top, to: .top, of: self, withInset: Values.smallSpacing)
        label.pin(.leading, to: .leading, of: self, withInset: Values.largeSpacing)
        label.pin(.trailing, to: .trailing, of: self, withInset: -Values.largeSpacing)
        label.pin(.bottom, to: .bottom, of: self, withInset: -Values.smallSpacing)

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(didTap(gesture:)))
        self.addGestureRecognizer(tapGesture)

        let swipeGesture = UISwipeGestureRecognizer(target: self, action: #selector(didSwipe(gesture:)))
        self.addGestureRecognizer(swipeGesture)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        
        self.layer.cornerRadius = (self.frame.height / 2)
    }

    // MARK: Gestures

    @objc func didTap(gesture: UITapGestureRecognizer) {
        self.delegate?.didTapToastView(self)
    }

    @objc func didSwipe(gesture: UISwipeGestureRecognizer) {
        self.delegate?.didSwipeToastView(self)
    }
}
