// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import LocalAuthentication
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

class PrivacySettingsViewModel: SessionTableViewModel, NavigationItemSource, NavigatableStateHolder, ObservableTableSource {
    public let dependencies: Dependencies
    public let navigatableState: NavigatableState = NavigatableState()
    public let state: TableDataState<Section, TableItem> = TableDataState()
    public let observableState: ObservableTableSourceState<Section, TableItem> = ObservableTableSourceState()
    private let shouldShowCloseButton: Bool
    private let shouldAutomaticallyShowCallModal: Bool
    
    /// This value is the current state of the view
    @MainActor @Published private(set) var internalState: State
    private var observationTask: Task<Void, Never>?
    
    // MARK: - Initialization
    
    @MainActor init(
        shouldShowCloseButton: Bool = false,
        shouldAutomaticallyShowCallModal: Bool = false,
        using dependencies: Dependencies
    ) {
        self.dependencies = dependencies
        self.shouldShowCloseButton = shouldShowCloseButton
        self.shouldAutomaticallyShowCallModal = shouldAutomaticallyShowCallModal
        self.internalState = State.initialState()
        
        observationTask = ObservationBuilder
            .initialValue(self.internalState)
            .debounce(for: .never)
            .using(dependencies: dependencies)
            .query(PrivacySettingsViewModel.queryState)
            .assign { [weak self] updatedState in
                guard let self = self else { return }
                
                // FIXME: To slightly reduce the size of the changes this new observation mechanism is currently wired into the old SessionTableViewController observation mechanism, we should refactor it so everything uses the new mechanism
                let oldState: State = self.internalState
                self.internalState = updatedState
                self.pendingTableDataSubject.send(updatedState.sections(viewModel: self, previousState: oldState))
            }
    }
    
    // MARK: - Config
    
    enum NavItem: Equatable {
        case close
    }
    
    public enum Section: SessionTableSection {
        case screenSecurity
        case messageRequests
        case readReceipts
        case typingIndicators
        case linkPreviews
        case calls
        
        var title: String? {
            switch self {
                case .screenSecurity: return "screenSecurity".localized()
                case .messageRequests: return "sessionMessageRequests".localized()
                case .readReceipts: return "readReceipts".localized()
                case .typingIndicators: return "typingIndicators".localized()
                case .linkPreviews: return "linkPreviews".localized()
                case .calls: return "callsSettings".localized()
            }
        }
        
        var style: SessionTableSectionStyle { return .titleRoundedContent }
    }
    
    public enum TableItem: Differentiable {
        case calls
        case microphone
        case camera
        case localNetwork
        case screenLock
        case communityMessageRequests
        case screenshotNotifications
        case readReceipts
        case typingIndicators
        case linkPreviews
    }
    
    // MARK: - Navigation
    
    lazy var leftNavItems: AnyPublisher<[SessionNavItem<NavItem>], Never> = (!shouldShowCloseButton ? [] :
        [
            SessionNavItem(
                id: .close,
                image: UIImage(named: "X")?
                    .withRenderingMode(.alwaysTemplate),
                style: .plain,
                accessibilityIdentifier: "Close button"
            ) { [weak self] in self?.dismissScreen() }
        ]
    )
    
    public struct PrivacySettingsViewModelEvent: Hashable {
        let isAwaitingCallPermissionChainResult: Bool
    }
    
    // MARK: - State
    
    public struct State: ObservableKeyProvider {
        let isScreenLockEnabled: Bool
        let checkForCommunityMessageRequests: Bool
        let areReadReceiptsEnabled: Bool
        let typingIndicatorsEnabled: Bool
        let areLinkPreviewsEnabled: Bool
        let areCallsEnabled: Bool
        let cameraPermission: Permissions.Status
        let microphonePermission: Permissions.Status
        let localNetworkPermission: Permissions.Status
        let isAwaitingCallPermissionChainResult: Bool
        
        @MainActor public func sections(viewModel: PrivacySettingsViewModel, previousState: State) -> [SectionModel] {
            PrivacySettingsViewModel.sections(
                state: self,
                previousState: previousState,
                viewModel: viewModel
            )
        }
        
        public let observedKeys: Set<ObservableKey> = [
            .setting(.isScreenLockEnabled),
            .setting(.checkForCommunityMessageRequests),
            .setting(.areReadReceiptsEnabled),
            .setting(.typingIndicatorsEnabled),
            .setting(.areLinkPreviewsEnabled),
            .setting(.areCallsEnabled),
            .setting(.lastSeenHasLocalNetworkPermission),
            .permission(.microphone),
            .permission(.camera),
            .permission(.localNetwork),
            .updateScreen(PrivacySettingsViewModel.self)
        ]
        
        static func initialState() -> State {
            return State(
                isScreenLockEnabled: false,
                checkForCommunityMessageRequests: false,
                areReadReceiptsEnabled: false,
                typingIndicatorsEnabled: false,
                areLinkPreviewsEnabled: false,
                areCallsEnabled: false,
                cameraPermission: .unknown,
                microphonePermission: .unknown,
                localNetworkPermission: .unknown,
                isAwaitingCallPermissionChainResult: false
            )
        }
    }
    
    let title: String = "sessionPrivacy".localized()
    
    @Sendable private static func queryState(
        previousState: State,
        events: [ObservedEvent],
        isInitialQuery: Bool,
        using dependencies: Dependencies
    ) async -> State {
        var isScreenLockEnabled: Bool = previousState.isScreenLockEnabled
        var checkForCommunityMessageRequests: Bool = previousState.checkForCommunityMessageRequests
        var areReadReceiptsEnabled: Bool = previousState.areReadReceiptsEnabled
        var typingIndicatorsEnabled: Bool = previousState.typingIndicatorsEnabled
        var areLinkPreviewsEnabled: Bool = previousState.areLinkPreviewsEnabled
        var areCallsEnabled: Bool = previousState.areCallsEnabled
        var cameraPermission: Permissions.Status = previousState.cameraPermission
        var microphonePermission: Permissions.Status = previousState.microphonePermission
        var localNetworkPermission: Permissions.Status = previousState.localNetworkPermission
        var isAwaitingCallPermissionChainResult: Bool = previousState.isAwaitingCallPermissionChainResult
        
        /// If we have no previous state then we need to fetch the initial state
        if isInitialQuery {
            dependencies.mutate(cache: .libSession) { libSession in
                isScreenLockEnabled = libSession.get(.isScreenLockEnabled)
                checkForCommunityMessageRequests = libSession.get(.checkForCommunityMessageRequests)
                areReadReceiptsEnabled = libSession.get(.areReadReceiptsEnabled)
                typingIndicatorsEnabled = libSession.get(.typingIndicatorsEnabled)
                areLinkPreviewsEnabled = libSession.get(.areLinkPreviewsEnabled)
                areCallsEnabled = libSession.get(.areCallsEnabled)
            }
        }
        
        /// Process any event changes
        events.forEach { event in
            guard let updatedValue: Bool = event.value as? Bool else { return }
            
            switch event.key {
                case .setting(.isScreenLockEnabled): isScreenLockEnabled = updatedValue
                case .setting(.checkForCommunityMessageRequests):
                    checkForCommunityMessageRequests = updatedValue
                case .setting(.areReadReceiptsEnabled): areReadReceiptsEnabled = updatedValue
                case .setting(.typingIndicatorsEnabled): typingIndicatorsEnabled = updatedValue
                case .setting(.areLinkPreviewsEnabled): areLinkPreviewsEnabled = updatedValue
                case .setting(.areCallsEnabled): areCallsEnabled = updatedValue
                    
                default: break
            }
        }
        
        if
            let event: ObservedEvent = events.first(where: { $0.key == .updateScreen(PrivacySettingsViewModel.self) }),
            let eventValue: PrivacySettingsViewModelEvent = event.value as? PrivacySettingsViewModelEvent
        {
            isAwaitingCallPermissionChainResult = eventValue.isAwaitingCallPermissionChainResult
        }
        
        /// Get the proper permissions rather than relying on events
        cameraPermission = Permissions.camera
        microphonePermission = Permissions.microphone
        localNetworkPermission = Permissions.localNetwork(using: dependencies)
        
        return State(
            isScreenLockEnabled: isScreenLockEnabled,
            checkForCommunityMessageRequests: checkForCommunityMessageRequests,
            areReadReceiptsEnabled: areReadReceiptsEnabled,
            typingIndicatorsEnabled: typingIndicatorsEnabled,
            areLinkPreviewsEnabled: areLinkPreviewsEnabled,
            areCallsEnabled: areCallsEnabled,
            cameraPermission: cameraPermission,
            microphonePermission: microphonePermission,
            localNetworkPermission: localNetworkPermission,
            isAwaitingCallPermissionChainResult: isAwaitingCallPermissionChainResult
        )
    }
    
    private static func sections(
        state: State,
        previousState: State,
        viewModel: PrivacySettingsViewModel
    ) -> [SectionModel] {
            var sections: [SectionModel] = []
            
            var callsSection = SectionModel(model: .calls, elements: [])
            callsSection.elements.append(
                SessionCell.Info(
                    id: .calls,
                    title: "callsVoiceAndVideo".localized(),
                    subtitle: "callsVoiceAndVideoToggleDescription".localized(),
                    trailingAccessory: .toggle(
                        state.areCallsEnabled,
                        oldValue: previousState.areCallsEnabled,
                        accessibility: Accessibility(
                            identifier: "Voice and Video Calls - Switch"
                        )
                    ),
                    accessibility: Accessibility(
                        label: "Allow voice and video calls"
                    ),
                    confirmationInfo: ConfirmationModal.Info(
                        title: "callsVoiceAndVideoBeta".localized(),
                        body: .text("callsVoiceAndVideoModalDescription"
                            .put(key: "session_foundation", value: Constants.session_foundation)
                            .localized()),
                        showCondition: .disabled,
                        confirmTitle: "theContinue".localized(),
                        confirmStyle: .danger,
                        cancelStyle: .alert_text,
                        dismissOnConfirm: false,
                        onConfirm: { [dependencies = viewModel.dependencies] modal in
                            /// Notify that we are awaiting the outcome of the calls permission chain
                            dependencies.notifyAsync(
                                priority: .immediate,
                                key: .updateScreen(PrivacySettingsViewModel.self),
                                value: PrivacySettingsViewModelEvent(
                                    isAwaitingCallPermissionChainResult: true
                                )
                            )
                            
                            /// Wait until after the modal has been dismissed to kick off the permission chain to ensure we
                            /// don't try to present a subsequent modal from the one being dismissed (this would result in
                            /// no modal being shown)
                            modal.dismiss(animated: true) {
                                Permissions.requestPermissionsForCalls(using: dependencies) { _, _, _ in
                                    /// Notify that we are no longer awaiting the result of the permission chain
                                    dependencies.notifyAsync(
                                        priority: .immediate,
                                        key: .updateScreen(PrivacySettingsViewModel.self),
                                        value: PrivacySettingsViewModelEvent(
                                            isAwaitingCallPermissionChainResult: false
                                        )
                                    )
                                }
                            }
                        }
                    ),
                    onTap: { [dependencies = viewModel.dependencies] in
                        dependencies.setAsync(.areCallsEnabled, !state.areCallsEnabled)
                    }
                )
            )
                
            if state.areCallsEnabled {
                let unknownPermissionStatuses: Set<Permissions.Status> = [.undetermined, .unknown]
                
                callsSection.elements.append(
                    SessionCell.Info(
                        id: .microphone,
                        title: "permissionsMicrophone".localized(),
                        subtitle: "permissionsMicrophoneDescriptionIos".localized(),
                        trailingAccessory: {
                            guard
                                !state.isAwaitingCallPermissionChainResult ||
                                !unknownPermissionStatuses.contains(state.microphonePermission)
                            else {
                                return .activityIndicator(
                                    themeColor: .textPrimary,
                                    accessibility: Accessibility(
                                        identifier: "Microphone Permission"
                                    )
                                )
                            }
                            
                            return .toggle(
                                (state.microphonePermission == .granted),
                                oldValue: (previousState.microphonePermission == .granted),
                                accessibility: Accessibility(
                                    identifier: "Microphone Permission - Switch"
                                )
                            )
                        }(),
                        accessibility: Accessibility(
                            label: "Grant microphone permission"
                        ),
                        onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                            switch state.microphonePermission {
                                case .granted, .restricted:
                                    viewModel?.transitionToScreen(
                                        ConfirmationModal(
                                            info: ConfirmationModal.Info(
                                                title: "permissionChange".localized(),
                                                body: .text(
                                                    "permissionsMicrophoneChangeDescriptionIos".localized()
                                                ),
                                                confirmTitle: "sessionSettings".localized(),
                                                onConfirm: { _ in
                                                    UIApplication.shared.openSystemSettings()
                                                }
                                            )
                                        ),
                                        transitionType: .present
                                    )
                                    return
                                    
                                case .denied:
                                    viewModel?.transitionToScreen(
                                        ConfirmationModal(
                                            info: ConfirmationModal.Info(
                                                title: "permissionsRequired".localized(),
                                                body: .text(
                                                    "permissionsMicrophoneAccessRequiredCallsIos".localized()
                                                ),
                                                confirmTitle: "sessionSettings".localized(),
                                                onConfirm: { _ in
                                                    UIApplication.shared.openSystemSettings()
                                                }
                                            )
                                        ),
                                        transitionType: .present
                                    )
                                    return
                                    
                                case .undetermined, .unknown:
                                    Permissions.requestMicrophonePermissionIfNeeded(using: dependencies)
                                    return
                            }
                        }
                    )
                )
                callsSection.elements.append(
                    SessionCell.Info(
                        id: .camera,
                        title: "contentDescriptionCamera".localized(),
                        subtitle: "permissionsCameraDescriptionIos".localized(),
                        trailingAccessory: {
                            guard
                                !state.isAwaitingCallPermissionChainResult ||
                                !unknownPermissionStatuses.contains(state.cameraPermission)
                            else {
                                return .activityIndicator(
                                    themeColor: .textPrimary,
                                    accessibility: Accessibility(
                                        identifier: "Camera Permission"
                                    )
                                )
                            }
                            
                            return .toggle(
                                (state.cameraPermission == .granted),
                                oldValue: (previousState.cameraPermission == .granted),
                                accessibility: Accessibility(
                                    identifier: "Camera Permission - Switch"
                                )
                            )
                        }(),
                        accessibility: Accessibility(
                            label: "Grant camera permission"
                        ),
                        onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                            switch state.cameraPermission {
                                case .granted, .restricted:
                                    viewModel?.transitionToScreen(
                                        ConfirmationModal(
                                            info: ConfirmationModal.Info(
                                                title: "permissionChange".localized(),
                                                body: .text(
                                                    "permissionsCameraChangeDescriptionIos".localized()
                                                ),
                                                confirmTitle: "sessionSettings".localized(),
                                                onConfirm: { _ in
                                                    UIApplication.shared.openSystemSettings()
                                                }
                                            )
                                        ),
                                        transitionType: .present
                                    )
                                    return
                                    
                                case .denied:
                                    viewModel?.transitionToScreen(
                                        ConfirmationModal(
                                            info: ConfirmationModal.Info(
                                                title: "permissionsRequired".localized(),
                                                body: .text(
                                                    "permissionsCameraAccessRequiredCallsIos".localized()
                                                ),
                                                confirmTitle: "sessionSettings".localized(),
                                                onConfirm: { _ in
                                                    UIApplication.shared.openSystemSettings()
                                                }
                                            )
                                        ),
                                        transitionType: .present
                                    )
                                    return
                                    
                                case .undetermined, .unknown:
                                    Permissions.requestCameraPermissionIfNeeded(using: dependencies)
                                    return
                            }
                        }
                    )
                )
                callsSection.elements.append(
                    SessionCell.Info(
                        id: .localNetwork,
                        title: "permissionsLocalNetworkIos".localized(),
                        subtitle: "permissionsLocalNetworkDescriptionIos".localized(),
                        trailingAccessory: {
                            guard
                                !state.isAwaitingCallPermissionChainResult ||
                                !unknownPermissionStatuses.contains(state.localNetworkPermission)
                            else {
                                return .activityIndicator(
                                    themeColor: .textPrimary,
                                    accessibility: Accessibility(
                                        identifier: "Local Network Permission"
                                    )
                                )
                            }
                            
                            return .toggle(
                                (state.localNetworkPermission == .granted),
                                oldValue: (previousState.localNetworkPermission == .granted),
                                accessibility: Accessibility(
                                    identifier: "Local Network Permission - Switch"
                                )
                            )
                        }(),
                        accessibility: Accessibility(
                            label: "Grant local network permission"
                        ),
                        onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                            switch state.localNetworkPermission {
                                case .granted, .restricted:
                                    viewModel?.transitionToScreen(
                                        ConfirmationModal(
                                            info: ConfirmationModal.Info(
                                                title: "permissionChange".localized(),
                                                body: .text(
                                                    "permissionsLocalNetworkChangeDescriptionIos".localized()
                                                ),
                                                confirmTitle: "sessionSettings".localized(),
                                                onConfirm: { _ in
                                                    UIApplication.shared.openSystemSettings()
                                                }
                                            )
                                        ),
                                        transitionType: .present
                                    )
                                    return
                                    
                                case .denied:
                                    viewModel?.transitionToScreen(
                                        ConfirmationModal(
                                            info: ConfirmationModal.Info(
                                                title: "permissionsRequired".localized(),
                                                body: .text(
                                                    "permissionsLocalNetworkAccessRequiredCallsIos".localized()
                                                ),
                                                confirmTitle: "sessionSettings".localized(),
                                                onConfirm: { _ in
                                                    UIApplication.shared.openSystemSettings()
                                                }
                                            )
                                        ),
                                        transitionType: .present
                                    )
                                    return
                                    
                                case .undetermined, .unknown:
                                    Permissions.requestLocalNetworkPermissionIfNeeded(using: dependencies)
                                    return
                            }
                        }
                    )
                )
            }
            
            sections.append(callsSection)
            sections.append(
                SectionModel(
                    model: .screenSecurity,
                    elements: [
                        SessionCell.Info(
                            id: .screenLock,
                            title: "lockApp".localized(),
                            subtitle: "lockAppDescriptionIos"
                                .put(key: "app_name", value: Constants.app_name)
                                .localized(),
                            trailingAccessory: .toggle(
                                state.isScreenLockEnabled,
                                oldValue: previousState.isScreenLockEnabled,
                                accessibility: Accessibility(
                                    identifier: "Lock App - Switch"
                                )
                            ),
                            onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                                // Make sure the device has a passcode set before allowing screen lock to
                                // be enabled (Note: This will always return true on a simulator)
                                guard LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
                                    viewModel?.transitionToScreen(
                                        ConfirmationModal(
                                            info: ConfirmationModal.Info(
                                                title: "lockAppEnablePasscode".localized(),
                                                cancelTitle: "okay".localized(),
                                                cancelStyle: .alert_text
                                            )
                                        ),
                                        transitionType: .present
                                    )
                                    return
                                }
                                
                                dependencies.setAsync(.isScreenLockEnabled, !state.isScreenLockEnabled)
                            }
                        )
                    ]
                )
            )
            sections.append(
                SectionModel(
                    model: .messageRequests,
                    elements: [
                        SessionCell.Info(
                            id: .communityMessageRequests,
                            title: "messageRequestsCommunities".localized(),
                            subtitle: "messageRequestsCommunitiesDescription".localized(),
                            trailingAccessory: .toggle(
                                state.checkForCommunityMessageRequests,
                                oldValue: previousState.checkForCommunityMessageRequests,
                                accessibility: Accessibility(
                                    identifier: "Community Message Requests - Switch"
                                )
                            ),
                            onTap: { [dependencies = viewModel.dependencies] in
                                dependencies.setAsync(
                                    .checkForCommunityMessageRequests,
                                    !state.checkForCommunityMessageRequests
                                )
                            }
                        )
                    ]
                )
            )
            sections.append(
                SectionModel(
                    model: .readReceipts,
                    elements: [
                        SessionCell.Info(
                            id: .readReceipts,
                            title: "readReceipts".localized(),
                            subtitle: "readReceiptsDescription".localized(),
                            trailingAccessory: .toggle(
                                state.areReadReceiptsEnabled,
                                oldValue: previousState.areReadReceiptsEnabled,
                                accessibility: Accessibility(
                                    identifier: "Read Receipts - Switch"
                                )
                            ),
                            onTap: { [dependencies = viewModel.dependencies] in
                                dependencies.setAsync(.areReadReceiptsEnabled, !state.areReadReceiptsEnabled)
                            }
                        )
                    ]
                )
            )
            sections.append(
                SectionModel(
                    model: .typingIndicators,
                    elements: [
                        SessionCell.Info(
                            id: .typingIndicators,
                            title: SessionCell.TextInfo(
                                "typingIndicators".localized(),
                                font: .title
                            ),
                            subtitle: SessionCell.TextInfo(
                                "typingIndicatorsDescription".localized(),
                                font: .subtitle,
                                extraViewGenerator: { TypingIndicatorPreviewView() }
                            ),
                            trailingAccessory: .toggle(
                                state.typingIndicatorsEnabled,
                                oldValue: previousState.typingIndicatorsEnabled,
                                accessibility: Accessibility(
                                    identifier: "Typing Indicators - Switch"
                                )
                            ),
                            onTap: { [dependencies = viewModel.dependencies] in
                                dependencies.setAsync(.typingIndicatorsEnabled, !state.typingIndicatorsEnabled)
                            }
                        )
                    ]
                )
            )
            sections.append(
                SectionModel(
                    model: .linkPreviews,
                    elements: [
                        SessionCell.Info(
                            id: .linkPreviews,
                            title: "linkPreviewsSend".localized(),
                            subtitle: "linkPreviewsDescription".localized(),
                            trailingAccessory: .toggle(
                                state.areLinkPreviewsEnabled,
                                oldValue: previousState.areLinkPreviewsEnabled,
                                accessibility: Accessibility(
                                    identifier: "Send Link Previews - Switch"
                                )
                            ),
                            onTap: { [dependencies = viewModel.dependencies] in
                                dependencies.setAsync(.areLinkPreviewsEnabled, !state.areLinkPreviewsEnabled)
                            }
                        )
                    ]
                )
            )
            
            return sections
        }
    
    @MainActor func onAppear(targetViewController: BaseVC) {
        if self.shouldAutomaticallyShowCallModal {
            let confirmationModal: ConfirmationModal = ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: "callsVoiceAndVideoBeta".localized(),
                    body: .text(
                        "callsVoiceAndVideoModalDescription"
                            .put(key: "session_foundation", value: Constants.session_foundation)
                            .localized()
                    ),
                    showCondition: .disabled,
                    confirmTitle: "theContinue".localized(),
                    confirmStyle: .danger,
                    cancelStyle: .alert_text,
                    onConfirm: { [dependencies] _ in
                        Permissions.requestPermissionsForCalls(using: dependencies)
                        dependencies.setAsync(.areCallsEnabled, true)
                    }
                )
            )
            targetViewController.present(confirmationModal, animated: true, completion: nil)
        }
    }
}

// MARK: - Info

private final class TypingIndicatorPreviewView: UIView {
    static var size: CGSize = CGSize(width: 24, height: 14)
    
    // MARK: - Components
    
    private lazy var bubbleView: UIView = {
        let result: UIView = UIView()
        result.layer.cornerRadius = VisibleMessageCell.smallCornerRadius
        result.layer.mask = bubbleViewMaskLayer
        result.themeBackgroundColor = .messageBubble_incomingBackground
        
        return result
    }()

    private let bubbleViewMaskLayer: CAShapeLayer = {
        let result: CAShapeLayer = CAShapeLayer()
        let maskPath: UIBezierPath = UIBezierPath(
            roundedRect: CGRect(origin: .zero, size: TypingIndicatorPreviewView.size),
            byRoundingCorners: .allCorners,
            cornerRadii: CGSize(
                width: VisibleMessageCell.largeCornerRadius,
                height: VisibleMessageCell.largeCornerRadius
            )
        )
        
        result.path = maskPath.cgPath
        
        return result
    }()
    public lazy var typingIndicatorView: TypingIndicatorView = TypingIndicatorView()
    
    // MARK: - Initialization
    
    init() {
        super.init(frame: .zero)
        
        setupLayout()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Layout
    
    private func setupLayout() {
        addSubview(bubbleView)
        bubbleView.addSubview(typingIndicatorView)
        
        set(.width, to: TypingIndicatorPreviewView.size.width)
        set(.height, to: TypingIndicatorPreviewView.size.height)
        
        bubbleView.pin(to: self)
        typingIndicatorView.center(in: bubbleView)
        
        // Use a transform scale to reduce the size of the typing indicator to the
        // desired size (this way the animation remains intact)
        typingIndicatorView.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
        typingIndicatorView.startAnimation()
    }
}
