// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import CryptoKit
import Compression
import GRDB
import DifferenceKit
import SessionUIKit
import SessionSnodeKit
import SessionMessagingKit
import SessionUtilitiesKit
import SignalUtilitiesKit

class DeveloperSettingsViewModel: SessionTableViewModel, NavigatableStateHolder, ObservableTableSource {
    public let dependencies: Dependencies
    public let navigatableState: NavigatableState = NavigatableState()
    public let state: TableDataState<Section, TableItem> = TableDataState()
    public let observableState: ObservableTableSourceState<Section, TableItem> = ObservableTableSourceState()
    
    private var databaseKeyEncryptionPassword: String = ""
    private var documentPickerResult: DocumentPickerResult?
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
    }
    
    // MARK: - Section
    
    public enum Section: SessionTableSection {
        case developerMode
        case database
        
        var title: String? {
            switch self {
                case .developerMode: return nil
                case .database: return "Database"
            }
        }
        
        var style: SessionTableSectionStyle {
            switch self {
                case .developerMode: return .padding
                default: return .titleRoundedContent
            }
        }
    }
    
    public enum TableItem: Hashable, Differentiable, CaseIterable {
        case developerMode
        
        case exportDatabase
        case importDatabase
        
        // MARK: - Conformance
        
        public typealias DifferenceIdentifier = String
        
        public var differenceIdentifier: String {
            switch self {
                case .developerMode: return "developerMode"
                
                case .exportDatabase: return "exportDatabase"
                case .importDatabase: return "importDatabase"
            }
        }
        
        public func isContentEqual(to source: TableItem) -> Bool {
            self.differenceIdentifier == source.differenceIdentifier
        }
        
        public static var allCases: [TableItem] {
            var result: [TableItem] = []
            switch TableItem.developerMode {
                case .developerMode: result.append(.developerMode); fallthrough
                
                case .exportDatabase: result.append(.exportDatabase); fallthrough
                case .importDatabase: result.append(.importDatabase)
            }
            
            return result
        }
    }
    
    // MARK: - Content
    
    private struct State: Equatable {
        let developerMode: Bool
    }
    
    let title: String = "Developer Settings"
    
    lazy var observation: TargetObservation = ObservationBuilder
        .refreshableData(self) { [weak self, dependencies] () -> State in
            State(
                developerMode: dependencies.storage[.developerModeEnabled]
            )
        }
        .compactMapWithPrevious { [weak self] prev, current -> [SectionModel]? in self?.content(prev, current) }
    
    private func content(_ previous: State?, _ current: State) -> [SectionModel] {
        return [
            SectionModel(
                model: .developerMode,
                elements: [
                    SessionCell.Info(
                        id: .developerMode,
                        title: "Developer Mode",
                        subtitle: """
                        Grants access to this screen.
                        
                        Disabling this setting will:
                        • Reset all the below settings to default (removing data as described below)
                        • Revoke access to this screen unless Developer Mode is re-enabled
                        """,
                        rightAccessory: .toggle(
                            .boolValue(
                                current.developerMode,
                                oldValue: (previous?.developerMode == true)
                            )
                        ),
                        onTap: { [weak self] in
                            guard current.developerMode else { return }
                            
                            self?.disableDeveloperMode()
                        }
                    )
                ]
            ),
            SectionModel(
                model: .database,
                elements: [
                    SessionCell.Info(
                        id: .exportDatabase,
                        title: "Export App Data",
                        rightAccessory: .icon(
                            UIImage(systemName: "square.and.arrow.up.trianglebadge.exclamationmark")?
                                .withRenderingMode(.alwaysTemplate),
                            size: .small
                        ),
                        styling: SessionCell.StyleInfo(
                            tintColor: .danger
                        ),
                        onTapView: { [weak self] view in self?.exportDatabase(view) }
                    ),
                    SessionCell.Info(
                        id: .importDatabase,
                        title: "Import App Data",
                        rightAccessory: .icon(
                            UIImage(systemName: "square.and.arrow.down")?
                                .withRenderingMode(.alwaysTemplate),
                            size: .small
                        ),
                        styling: SessionCell.StyleInfo(
                            tintColor: .danger
                        ),
                        onTapView: { [weak self] view in self?.importDatabase(view) }
                    )
                ]
            )
        ]
    }
    
    // MARK: - Functions
    
    private func disableDeveloperMode() {
        /// Loop through all of the sections and reset the features back to default for each one as needed (this way if a new section is added
        /// then we will get a compile error if it doesn't get resetting instructions added)
        TableItem.allCases.forEach { item in
            switch item {
                case .developerMode: break      // Not a feature
                
                case .exportDatabase: break     // Not a feature
                case .importDatabase: break     // Not a feature
            }
        }
        
        /// Disable developer mode
        dependencies.storage.write { db in
            db[.developerModeEnabled] = false
        }
        
        self.dismissScreen(type: .pop)
    }
    
    // MARK: - Export and Import
    
    private func exportDatabase(_ targetView: UIView?) {
        let generatedPassword: String = UUID().uuidString
        self.databaseKeyEncryptionPassword = generatedPassword
        
        self.transitionToScreen(
            ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: "Export App Data",
                    body: .input(
                        explanation: NSAttributedString(
                            string: """
                            This will generate a file encrypted using the provided password includes all app data, attachments, settings and keys.

                            We've generated a secure password for you but feel free to provide your own. 
                            
                            Use at your own risk!
                            """
                        ),
                        placeholder: "Enter a password",
                        initialValue: generatedPassword,
                        clearButton: true,
                        onChange: { [weak self] value in self?.databaseKeyEncryptionPassword = value }
                    ),
                    confirmTitle: "save".localized(),
                    confirmStyle: .alert_text,
                    cancelTitle: "share".localized(),
                    cancelStyle: .alert_text,
                    hasCloseButton: true,
                    dismissOnConfirm: false,
                    onConfirm: { [weak self] modal in
                        modal.dismiss(animated: true) {
                            self?.performExport(viaShareSheet: false, targetView: targetView)
                        }
                    },
                    onCancel: { [weak self] modal in
                        modal.dismiss(animated: true) {
                            self?.performExport(viaShareSheet: true, targetView: targetView)
                        }
                    }
                )
            ),
            transitionType: .present
        )
    }
    
    private func importDatabase(_ targetView: UIView?) {
        func showError(_ error: Error) {
            self.transitionToScreen(
                ConfirmationModal(
                    info: ConfirmationModal.Info(
                        title: "theError".localized(),
                        body: {
                            switch error {
                                case CryptoKitError.incorrectKeySize:
                                    return .text("The password must be between 6 and 32 characters (padded to 32 bytes)")
                                
                                default: return .text("Failed to export database")
                            }
                        }()
                    )
                ),
                transitionType: .present
            )
        }
        
        self.databaseKeyEncryptionPassword = ""
        self.transitionToScreen(
            ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: "Import App Data",
                    body: .input(
                        explanation: NSAttributedString(
                            string: """
                            Importing a database will result in the loss of all data stored locally.

                            Use at your own risk!
                            """
                        ),
                        placeholder: "Enter a password",
                        initialValue: "",
                        clearButton: true,
                        onChange: { [weak self] value in self?.databaseKeyEncryptionPassword = value }
                    ),
                    confirmTitle: "Import",
                    confirmStyle: .danger,
                    cancelStyle: .alert_text,
                    dismissOnConfirm: false,
                    onConfirm: { [weak self] modal in
                        modal.dismiss(animated: true) {
                            guard
                                let password: String = self?.databaseKeyEncryptionPassword,
                                password.count >= 6
                            else { return showError(CryptoKitError.incorrectKeySize) }
                            
                            let documentPickerResult: DocumentPickerResult = DocumentPickerResult { url in
                                guard let url: URL = url else { return }

                                let viewController: UIViewController = ModalActivityIndicatorViewController(canCancel: false) { modalActivityIndicator in
                                    do {
                                        let tmpUnencryptPath: String = "\(Singleton.appContext.temporaryDirectory)/new_session.bak"
                                        let extraFilePaths: [String] = try DirectoryArchiver.unarchiveDirectory(
                                            archivePath: url.path,
                                            destinationPath: tmpUnencryptPath,
                                            password: password,
                                            progressChanged: { fileProgress, fileSize in
                                                let percentage: Int = {
                                                    guard fileSize > 0 else { return 0 }
                                                    
                                                    return Int((Double(fileProgress) / Double(fileSize)) * 100)
                                                }()
                                                
                                                DispatchQueue.main.async {
                                                    modalActivityIndicator.setMessage(
                                                        "Decryption progress: \(percentage)%"
                                                    )
                                                }
                                            }
                                        )
                                        
                                        // TODO: Need to actually replace the current content then kill the app
                                        // TODO: Might be nice to validate that we have database access to the new database with the key
                                        print("RAWR")
                                        modalActivityIndicator.dismiss {
                                            print("RAWR2")
                                        }
                                    }
                                    catch { showError(error) }
                                }
                                
                                self?.transitionToScreen(viewController, transitionType: .present)
                            }
                            self?.documentPickerResult = documentPickerResult
                            
                            // UIDocumentPickerModeImport copies to a temp file within our container.
                            // It uses more memory than "open" but lets us avoid working with security scoped URLs.
                            let documentPickerVC = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
                            documentPickerVC.delegate = documentPickerResult
                            documentPickerVC.modalPresentationStyle = .fullScreen
                            
                            self?.transitionToScreen(documentPickerVC, transitionType: .present)
                        }
                    }
                )
            ),
            transitionType: .present
        )
    }
    
    private func performExport(
        viaShareSheet: Bool,
        targetView: UIView?
    ) {
        func showError(_ error: Error) {
            self.transitionToScreen(
                ConfirmationModal(
                    info: ConfirmationModal.Info(
                        title: "theError".localized(),
                        body: {
                            switch error {
                                case CryptoKitError.incorrectKeySize:
                                    return .text("The password must be between 6 and 32 characters (padded to 32 bytes)")
                                
                                default: return .text("Failed to export database")
                            }
                        }()
                    )
                ),
                transitionType: .present
            )
        }
        guard databaseKeyEncryptionPassword.count >= 6 else { return showError(CryptoKitError.incorrectKeySize) }
        guard Singleton.hasAppContext else { return showError(CryptoKitError.incorrectParameterSize) }
        
        let viewController: UIViewController = ModalActivityIndicatorViewController(canCancel: false) { [weak self, databaseKeyEncryptionPassword, dependencies] modalActivityIndicator in
            let backupFile: String = "\(Singleton.appContext.temporaryDirectory)/session.bak"
            
            do {
                let secureDbKey: String = try dependencies.storage.secureExportKey(
                    password: databaseKeyEncryptionPassword
                )
                
                try DirectoryArchiver.archiveDirectory(
                    sourcePath: FileManager.default.appSharedDataDirectoryPath,
                    destinationPath: backupFile,
                    additionalPaths: [secureDbKey],
                    password: databaseKeyEncryptionPassword,
                    progressChanged: { fileIndex, totalFiles, currentFileProgress, currentFileSize in
                        let percentage: Int = {
                            guard currentFileSize > 0 else { return 100 }
                            
                            let percentage: Int = Int((Double(currentFileProgress) / Double(currentFileSize)) * 100)
                            
                            guard percentage > 0 else { return 100 }
                            
                            return percentage
                        }()
                        
                        DispatchQueue.main.async {
                            modalActivityIndicator.setMessage([
                                "Exporting file: \(fileIndex)/\(totalFiles)",
                                "File encryption progress: \(percentage)%"
                            ].compactMap { $0 }.joined(separator: "\n"))
                        }
                    }
                )
            }
            catch { return showError(error) }
            
            modalActivityIndicator.dismiss {
                switch viaShareSheet {
                    case true:
                        let shareVC: UIActivityViewController = UIActivityViewController(
                            activityItems: [ URL(fileURLWithPath: backupFile) ],
                            applicationActivities: nil
                        )
                        shareVC.completionWithItemsHandler = { _, _, _, _ in }
                        
                        if UIDevice.current.isIPad {
                            shareVC.excludedActivityTypes = []
                            shareVC.popoverPresentationController?.permittedArrowDirections = (targetView != nil ? [.up] : [])
                            shareVC.popoverPresentationController?.sourceView = targetView
                            shareVC.popoverPresentationController?.sourceRect = (targetView?.bounds ?? .zero)
                        }
                        
                        self?.transitionToScreen(shareVC, transitionType: .present)
                        
                    case false:
                        // Create and present the document picker
                        let documentPickerResult: DocumentPickerResult = DocumentPickerResult { _ in }
                        self?.documentPickerResult = documentPickerResult
                        
                        let documentPicker: UIDocumentPickerViewController = UIDocumentPickerViewController(
                            forExporting: [URL(fileURLWithPath: backupFile)]
                        )
                        documentPicker.delegate = documentPickerResult
                        documentPicker.modalPresentationStyle = .formSheet
                        self?.transitionToScreen(documentPicker, transitionType: .present)
                }
            }
        }
        
        self.transitionToScreen(viewController, transitionType: .present)
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
