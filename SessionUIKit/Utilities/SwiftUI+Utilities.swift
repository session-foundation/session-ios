// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import UIKit
import SessionUtilitiesKit

struct ViewControllerHolder {
    weak var value: UIViewController?
}

struct ViewControllerKey: EnvironmentKey {
    static var defaultValue: ViewControllerHolder {
        return ViewControllerHolder(
            value: HasAppContext() ? CurrentAppContext().mainWindow?.rootViewController : nil
        )
    }
}

extension EnvironmentValues {
    public var viewController: UIViewController? {
        get { return self[ViewControllerKey.self].value }
        set { self[ViewControllerKey.self].value = newValue }
    }
}

public struct UIView_SwiftUI: UIViewRepresentable {
    public typealias UIViewType = UIView
    
    private let view: UIView
    
    public init(view: UIView) {
        self.view = view
    }
    
    public func makeUIView(context: Context) -> UIView {
        return self.view
    }
    
    public func updateUIView(_ uiView: UIView, context: Context) {
        uiView.layoutIfNeeded()
    }
}
