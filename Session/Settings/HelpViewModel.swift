// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import CryptoKit
import GRDB
import DeviceKit
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

// MARK: - Log.Category

private extension Log.Category {
    static let debugInfo: Log.Category = .create("DebugInfo", defaultLevel: .info)
}

// MARK: - HelpViewModel

class HelpViewModel: SessionTableViewModel, NavigatableStateHolder, ObservableTableSource {
    typealias TableItem = Section
    
    public let dependencies: Dependencies
    public let navigatableState: NavigatableState = NavigatableState()
    public let state: TableDataState<Section, TableItem> = TableDataState()
    public let observableState: ObservableTableSourceState<Section, TableItem> = ObservableTableSourceState()
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
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
                    trailingAccessory: .highlightingBackgroundLabel(
                        title: "helpReportABugExportLogs".localized()
                    ),
                    onTapView: { [dependencies] view in
                        HelpViewModel.shareLogs(targetView: view, using: dependencies)
                    }
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
                    trailingAccessory: .icon(
                        UIImage(systemName: "arrow.up.forward.app")?
                            .withRenderingMode(.alwaysTemplate),
                        size: .small,
                        pinEdges: [.right]
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
                    trailingAccessory: .icon(
                        UIImage(systemName: "arrow.up.forward.app")?
                            .withRenderingMode(.alwaysTemplate),
                        size: .small,
                        pinEdges: [.right]
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
                    trailingAccessory: .icon(
                        UIImage(systemName: "arrow.up.forward.app")?
                            .withRenderingMode(.alwaysTemplate),
                        size: .small,
                        pinEdges: [.right]
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
                    trailingAccessory: .icon(
                        UIImage(systemName: "arrow.up.forward.app")?
                            .withRenderingMode(.alwaysTemplate),
                        size: .small,
                        pinEdges: [.right]
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
    
    @MainActor public static func shareLogs(
        viewControllerToDismiss: UIViewController? = nil,
        targetView: UIView? = nil,
        animated: Bool = true,
        using dependencies: Dependencies,
        onShareComplete: (() -> ())? = nil
    ) {
        Task {
            guard
                let latestLogFilePath: String = await Log.logFilePath(using: dependencies),
                let viewController: UIViewController = dependencies[singleton: .appContext].frontMostViewController
            else { return }
            
#if targetEnvironment(simulator)
            // stringlint:ignore_start
            let modal: ConfirmationModal = ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: "Export Logs",
                    body: .text(
                        "How would you like to export the logs?\n\n(This modal only appears on the Simulator)"
                    ),
                    confirmTitle: "Copy Path",
                    cancelTitle: "Share",
                    cancelStyle: .alert_text,
                    onConfirm: { _ in UIPasteboard.general.string = latestLogFilePath },
                    onCancel: { modal in
                        modal.dismiss(animated: true) {
                            HelpViewModel.shareLogsInternal(
                                viewControllerToDismiss: viewControllerToDismiss,
                                targetView: targetView,
                                animated: animated,
                                using: dependencies,
                                onShareComplete: onShareComplete
                            )
                        }
                    }
                )
            )
            // stringlint:ignore_stop
            viewController.present(modal, animated: animated, completion: nil)
            #else
            HelpViewModel.shareLogsInternal(
                viewControllerToDismiss: viewControllerToDismiss,
                targetView: targetView,
                animated: animated,
                using: dependencies,
                onShareComplete: onShareComplete
            )
            #endif
        }
    }
    
    // stringlint:ignore_contents
    @MainActor private static func shareLogsInternal(
        viewControllerToDismiss: UIViewController? = nil,
        targetView: UIView? = nil,
        animated: Bool = true,
        using dependencies: Dependencies,
        onShareComplete: (() -> ())? = nil
    ) {
        Task {
            let memoryInfo: String = {
                var usage: String = "\(getMemoryUsage()) used"
                
                /// On the simulator `os_proc_available_memory` seems to always return `0` so just return the used amount
                #if !targetEnvironment(simulator)
                #endif
                let currentAvailableMemory: Int = os_proc_available_memory()
                usage.append(", \(Format.fileSize(UInt(currentAvailableMemory))) available")
                
                let totalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
                usage.append(" (Device: \(Format.fileSize(UInt(totalMemory))))")
                
                return usage
            }()
            let pushNotificationInfo: String = await {
                guard dependencies[defaults: .standard, key: .isUsingFullAPNs] else {
                    return "Slow Mode"
                }
                
                let hasToken: Bool = ((try? await dependencies[singleton: .storage]
                    .readAsync { db in db[.lastRecordedPushToken] != nil }) ?? false)
                
                return "Fast Mode (Token: \(hasToken ? "Registered" : "Unregistered"))"
            }()
            let permissionsSummary: Permissions.Summary = await Permissions.summary()
            let accountSize: String = dependencies.mutate(cache: .libSession) { cache in
                cache.stateDescriptionForLogs()
            }
            let regionCode: String = {
                if #available(iOS 16.0, *) {
                    return (Locale.current.region?.identifier ?? "Unknown")
                }
                else {
                    return (Locale.current.regionCode ?? "Unknown")
                }
            }()
            
            let debugInfo: String = """
              Device: \(Device.current)
              Versions: \(dependencies[cache: .appVersion].versionInfo)
              Memory Usage: \(memoryInfo)
              Notification State: \(pushNotificationInfo)
              Permissions:
                \(permissionsSummary.description.replacingOccurrences(of: "\n", with: "\n    "))
              Size:
                \(accountSize.replacingOccurrences(of: "\n", with: "\n    "))
              Time: \(regionCode)
            """
            Log.info(.debugInfo, "\(debugInfo)")
            Log.flush()
            
            guard
                let latestLogFilePath: String = await Log.logFilePath(using: dependencies),
                let viewController: UIViewController = dependencies[singleton: .appContext].frontMostViewController,
                let sanitizedLogFilePath = try? dependencies[singleton: .attachmentManager]
                    .createTemporaryFileForOpening(filePath: latestLogFilePath) // Creates a copy of the log file with whitespaces on the filename removed
            else { return }
            
            let showShareSheet: () -> () = {
                let shareVC = UIActivityViewController(
                    activityItems: [
                        URL(fileURLWithPath: sanitizedLogFilePath)
                    ],
                    applicationActivities: nil
                )
                shareVC.completionWithItemsHandler = { _, success, _, _ in
                    /// Sanity check to make sure we don't unintentionally remove a proper attachment file
                    if sanitizedLogFilePath.hasPrefix(dependencies[singleton: .fileManager].temporaryDirectory) {
                        /// Deletes file copy of the log file
                        try? dependencies[singleton: .fileManager].removeItem(atPath: sanitizedLogFilePath)
                    }
                    
                    UIActivityViewController.notifyIfNeeded(success, using: dependencies)
                    onShareComplete?()
                }
                
                if UIDevice.current.isIPad {
                    shareVC.excludedActivityTypes = []
                    shareVC.popoverPresentationController?.permittedArrowDirections = (targetView != nil ? [.up] : [])
                    shareVC.popoverPresentationController?.sourceView = (targetView ?? viewController.view)
                    shareVC.popoverPresentationController?.sourceRect = (targetView ?? viewController.view).bounds
                }
                viewController.present(shareVC, animated: animated, completion: nil)
            }
            
            guard let viewControllerToDismiss: UIViewController = viewControllerToDismiss else {
                showShareSheet()
                return
            }
            
            viewControllerToDismiss.dismiss(animated: animated) {
                showShareSheet()
            }
        }
    }
    
    // stringlint:ignore_contents
    private static func getMemoryUsage() -> String {
        var info = mach_task_basic_info()
        var count = (mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4)
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        
        guard kerr == KERN_SUCCESS else {
            return "Unknown"
        }
        
        return Format.fileSize(UInt(info.resident_size))
    }
}
