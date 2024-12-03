// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import CryptoKit
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

class HelpViewModel: SessionTableViewModel, NavigatableStateHolder, ObservableTableSource {
    typealias TableItem = Section
    
    public let dependencies: Dependencies
    public let navigatableState: NavigatableState = NavigatableState()
    public let state: TableDataState<Section, TableItem> = TableDataState()
    public let observableState: ObservableTableSourceState<Section, TableItem> = ObservableTableSourceState()
    private static var documentPickerResult: DocumentPickerResult?
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies = Dependencies()) {
        self.dependencies = dependencies
    }
    
    // MARK: - Section
    
    public enum Section: SessionTableSection {
        case report
        case translate
        case feedback
        case faq
        case support
        
        var style: SessionTableSectionStyle { .padding }
    }
    
    // MARK: - Content
    
    let title: String = "sessionHelp".localized()
    
    lazy var observation: TargetObservation = [
        SectionModel(
            model: .report,
            elements: [
                SessionCell.Info(
                    id: .report,
                    title: "helpReportABug".localized(),
                    subtitle: "helpReportABugExportLogsDescription"
                        .put(key: "app_name", value: Constants.app_name)
                        .localized(),
                    rightAccessory: .highlightingBackgroundLabel(
                        title: "helpReportABugExportLogs".localized()
                    ),
                    onTapView: { HelpViewModel.shareLogs(targetView: $0) }
                )
            ]
        ),
        SectionModel(
            model: .translate,
            elements: [
                SessionCell.Info(
                    id: .translate,
                    title: "helpHelpUsTranslateSession"
                        .put(key: "app_name", value: Constants.app_name)
                        .localized(),
                    rightAccessory: .icon(
                        UIImage(systemName: "arrow.up.forward.app")?
                            .withRenderingMode(.alwaysTemplate),
                        size: .small
                    ),
                    onTap: {
                        guard let url: URL = URL(string: "https://getsession.org/translate") else {
                            return
                        }
                        
                        UIApplication.shared.open(url)
                    }
                )
            ]
        ),
        SectionModel(
            model: .feedback,
            elements: [
                SessionCell.Info(
                    id: .feedback,
                    title: "helpWedLoveYourFeedback".localized(),
                    rightAccessory: .icon(
                        UIImage(systemName: "arrow.up.forward.app")?
                            .withRenderingMode(.alwaysTemplate),
                        size: .small
                    ),
                    onTap: {
                        guard let url: URL = URL(string: "https://getsession.org/survey") else {
                            return
                        }
                        
                        UIApplication.shared.open(url)
                    }
                )
            ]
        ),
        SectionModel(
            model: .faq,
            elements: [
                SessionCell.Info(
                    id: .faq,
                    title: "helpFAQ".localized(),
                    rightAccessory: .icon(
                        UIImage(systemName: "arrow.up.forward.app")?
                            .withRenderingMode(.alwaysTemplate),
                        size: .small
                    ),
                    onTap: {
                        guard let url: URL = URL(string: "https://getsession.org/faq") else {
                            return
                        }
                        
                        UIApplication.shared.open(url)
                    }
                )
            ]
        ),
        SectionModel(
            model: .support,
            elements: [
                SessionCell.Info(
                    id: .support,
                    title: "helpSupport".localized(),
                    rightAccessory: .icon(
                        UIImage(systemName: "arrow.up.forward.app")?
                            .withRenderingMode(.alwaysTemplate),
                        size: .small
                    ),
                    onTap: {
                        guard let url: URL = URL(string: "https://sessionapp.zendesk.com/hc/en-us") else {
                            return
                        }
                        
                        UIApplication.shared.open(url)
                    }
                )
            ]
        )
    ]
    
    // MARK: - Functions
    
    public static func shareLogs(
        viewControllerToDismiss: UIViewController? = nil,
        targetView: UIView? = nil,
        animated: Bool = true,
        onShareComplete: (() -> ())? = nil
    ) {
        guard
            let latestLogFilePath: String = Log.logFilePath(),
            Singleton.hasAppContext,
            let viewController: UIViewController = Singleton.appContext.frontmostViewController
        else { return }
        
        let modal: ConfirmationModal = ConfirmationModal(
            info: ConfirmationModal.Info(
                title: "helpReportABugExportLogs".localized(),
                body: .text("helpReportABugExportLogsDescription"
                    .put(key: "app_name", value: Constants.app_name)
                    .localized()),
                confirmTitle: "save".localized(),
                cancelTitle: "share".localized(),
                cancelStyle: .alert_text,
                hasCloseButton: true,
                dismissOnConfirm: false,
                onConfirm: { modal in
                    #if targetEnvironment(simulator)
                    UIPasteboard.general.string = latestLogFilePath
                    #endif
                    
                    modal.dismiss(animated: true) {
                        HelpViewModel.shareLogsInternal(
                            viaShareSheet: false,
                            viewControllerToDismiss: viewControllerToDismiss,
                            targetView: targetView,
                            animated: animated,
                            onShareComplete: onShareComplete
                        )
                    }
                },
                onCancel: { modal in
                    #if targetEnvironment(simulator)
                    UIPasteboard.general.string = latestLogFilePath
                    #endif
                    
                    modal.dismiss(animated: true) {
                        HelpViewModel.shareLogsInternal(
                            viaShareSheet: true,
                            viewControllerToDismiss: viewControllerToDismiss,
                            targetView: targetView,
                            animated: animated,
                            onShareComplete: onShareComplete
                        )
                    }
                }
            )
        )
        viewController.present(modal, animated: animated, completion: nil)
    }
    
    private static func shareLogsInternal(
        viaShareSheet: Bool,
        viewControllerToDismiss: UIViewController? = nil,
        targetView: UIView? = nil,
        animated: Bool = true,
        onShareComplete: (() -> ())? = nil
    ) {
        Log.info("[Version] \(SessionApp.versionInfo)")
        Log.flush()
        
        guard
            let latestLogFilePath: String = Log.logFilePath(),
            Singleton.hasAppContext,
            let viewController: UIViewController = Singleton.appContext.frontmostViewController
        else { return }
        
        let showExportOption: () -> () = {
            switch viaShareSheet {
                case true:
                    let shareVC = UIActivityViewController(
                        activityItems: [ URL(fileURLWithPath: latestLogFilePath) ],
                        applicationActivities: nil
                    )
                    shareVC.completionWithItemsHandler = { _, _, _, _ in onShareComplete?() }
                    
                    if UIDevice.current.isIPad {
                        shareVC.excludedActivityTypes = []
                        shareVC.popoverPresentationController?.permittedArrowDirections = (targetView != nil ? [.up] : [])
                        shareVC.popoverPresentationController?.sourceView = (targetView ?? viewController.view)
                        shareVC.popoverPresentationController?.sourceRect = (targetView ?? viewController.view).bounds
                    }
                    viewController.present(shareVC, animated: animated, completion: nil)
                    
                case false:
                    // Create and present the document picker
                    let documentPickerResult: DocumentPickerResult = DocumentPickerResult { _ in
                        HelpViewModel.documentPickerResult = nil
                        onShareComplete?()
                    }
                    HelpViewModel.documentPickerResult = documentPickerResult
                    
                    let documentPicker: UIDocumentPickerViewController = UIDocumentPickerViewController(
                        forExporting: [URL(fileURLWithPath: latestLogFilePath)]
                    )
                    documentPicker.delegate = documentPickerResult
                    documentPicker.modalPresentationStyle = .formSheet
                    viewController.present(documentPicker, animated: animated, completion: nil)
            }
        }
        
        guard let viewControllerToDismiss: UIViewController = viewControllerToDismiss else {
            showExportOption()
            return
        }

        viewControllerToDismiss.dismiss(animated: animated) {
            showExportOption()
        }
    }
}

private class DocumentPickerResult: NSObject, UIDocumentPickerDelegate {
    private let onResult: (URL?) -> Void
    
    init(onResult: @escaping (URL?) -> Void) {
        self.onResult = onResult
    }
    
    // MARK: - UIDocumentPickerDelegate
    
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url: URL = urls.first else {
            self.onResult(nil)
            return
        }
        
        self.onResult(url)
    }
    
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        self.onResult(nil)
    }
}
