// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionUtilitiesKit

public extension ProfilePictureView {
    func update(
        publicKey: String,
        threadVariant: SessionThread.Variant,
        displayPictureUrl: String?,
        profile: Profile?,
        profileIcon: ProfileIcon = .none,
        additionalProfile: Profile? = nil,
        additionalProfileIcon: ProfileIcon = .none,
        using dependencies: Dependencies
    ) {
        let (info, additionalInfo): (Info?, Info?) = ProfilePictureView.getProfilePictureInfo(
            size: self.size,
            publicKey: publicKey,
            threadVariant: threadVariant,
            displayPictureUrl: displayPictureUrl,
            profile: profile,
            profileIcon: profileIcon,
            additionalProfile: additionalProfile,
            additionalProfileIcon: additionalProfileIcon,
            using: dependencies
        )
        
        guard let info: Info = info else { return }
        
        update(info, additionalInfo: additionalInfo)
    }
    
    static func getProfilePictureInfo(
        size: Size,
        publicKey: String,
        threadVariant: SessionThread.Variant,
        displayPictureUrl: String?,
        profile: Profile?,
        profileIcon: ProfileIcon = .none,
        additionalProfile: Profile? = nil,
        additionalProfileIcon: ProfileIcon = .none,
        using dependencies: Dependencies
    ) -> (info: Info?, additionalInfo: Info?) {
        let explicitPath: String? = try? dependencies[singleton: .displayPictureManager].path(
            for: displayPictureUrl
        )
        let explicitPathFileExists: Bool = (explicitPath.map { dependencies[singleton: .fileManager].fileExists(atPath: $0) } ?? false)
        
        switch (explicitPath, explicitPathFileExists, publicKey.isEmpty, threadVariant) {
            // TODO: Deal with this case later when implement group related Pro features
            case (.some(let path), true, _, .legacyGroup), (.some(let path), true, _, .group): fallthrough
            case (.some(let path), true, _, .community):
                /// If we are given an explicit `displayPictureUrl` then only use that
                return (Info(
                    source: .url(URL(fileURLWithPath: path)),
                    animationBehaviour: .generic(true),
                    icon: profileIcon
                ), nil)
            
            case (.some(let path), true, _, _):
                /// If we are given an explicit `displayPictureUrl` then only use that
                return (
                    Info(
                        source: .url(URL(fileURLWithPath: path)),
                        animationBehaviour: ProfilePictureView.animationBehaviour(from: profile, using: dependencies),
                        icon: profileIcon
                    ),
                    nil
                )
            
            case (_, _, _, .community):
                return (
                    Info(
                        source: {
                            switch size {
                                case .navigation, .message: return .image("SessionWhite16", #imageLiteral(resourceName: "SessionWhite16"))
                                case .list: return .image("SessionWhite24", #imageLiteral(resourceName: "SessionWhite24"))
                                case .hero, .modal, .expanded: return .image("SessionWhite40", #imageLiteral(resourceName: "SessionWhite40"))
                            }
                        }(),
                        animationBehaviour: .generic(true),
                        inset: UIEdgeInsets(
                            top: 12,
                            left: 12,
                            bottom: 12,
                            right: 12
                        ),
                        icon: profileIcon,
                        forcedBackgroundColor: .theme(.classicDark, color: .borderSeparator)
                    ),
                    nil
                )
            
            case (_, _, true, _): return (nil, nil)
                
            case (_, _, _, .legacyGroup), (_, _, _, .group):
                let source: ImageDataManager.DataSource = {
                    guard
                        let path: String = try? dependencies[singleton: .displayPictureManager]
                            .path(for: profile?.displayPictureUrl),
                        dependencies[singleton: .fileManager].fileExists(atPath: path)
                    else {
                        return .placeholderIcon(
                            seed: (profile?.id ?? publicKey),
                            text: (profile?.displayName(for: threadVariant))
                                .defaulting(to: publicKey),
                            size: (additionalProfile != nil ?
                                size.multiImageSize :
                                size.viewSize
                            )
                        )
                    }
                    
                    return ImageDataManager.DataSource.url(URL(fileURLWithPath: path))
                }()
                
                return (
                    Info(
                        source: source,
                        animationBehaviour: ProfilePictureView.animationBehaviour(from: profile, using: dependencies),
                        icon: profileIcon
                    ),
                    additionalProfile
                        .map { other in
                            let source: ImageDataManager.DataSource = {
                                guard
                                    let path: String = try? dependencies[singleton: .displayPictureManager]
                                        .path(for: other.displayPictureUrl),
                                    dependencies[singleton: .fileManager].fileExists(atPath: path)
                                else {
                                    return .placeholderIcon(
                                        seed: other.id,
                                        text: other.displayName(for: threadVariant),
                                        size: size.multiImageSize
                                    )
                                }
                                
                                return ImageDataManager.DataSource.url(URL(fileURLWithPath: path))
                            }()
                            
                            return Info(
                                source: source,
                                animationBehaviour: ProfilePictureView.animationBehaviour(from: other, using: dependencies),
                                icon: additionalProfileIcon
                            )
                        }
                        .defaulting(
                            to: Info(
                                source: .image("ic_user_round_fill", UIImage(named: "ic_user_round_fill")),
                                animationBehaviour: .generic(false),
                                renderingMode: .alwaysTemplate,
                                themeTintColor: .white,
                                inset: UIEdgeInsets(
                                    top: 4,
                                    left: 4,
                                    bottom: -6,
                                    right: 4
                                ),
                                icon: additionalProfileIcon
                            )
                        )
                )
                
            case (_, _, _, .contact):
                let source: ImageDataManager.DataSource = {
                    guard
                        let path: String = try? dependencies[singleton: .displayPictureManager]
                            .path(for: profile?.displayPictureUrl),
                        dependencies[singleton: .fileManager].fileExists(atPath: path)
                    else {
                        return .placeholderIcon(
                            seed: publicKey,
                            text: (profile?.displayName(for: threadVariant))
                                .defaulting(to: publicKey),
                            size: size.viewSize
                        )
                    }
                    
                    return ImageDataManager.DataSource.url(URL(fileURLWithPath: path))
                }()
                
                return (
                    Info(
                        source: source,
                        animationBehaviour: ProfilePictureView.animationBehaviour(from: profile, using: dependencies),
                        icon: profileIcon),
                    nil
                )
        }
    }
}

public extension ProfilePictureView {
    static func animationBehaviour(from profile: Profile?, using dependencies: Dependencies) -> Info.AnimationBehaviour {
        guard dependencies[feature: .sessionProEnabled] else { return .generic(true) }

        switch profile {
            case .none: return .generic(false)
            
            case .some(let profile) where profile.id == dependencies[cache: .general].sessionId.hexString:
                return .currentUser(dependencies[singleton: .sessionProManager])
                
            case .some(let profile):
                return .contact(dependencies.mutate(cache: .libSession, { $0.validateProProof(for: profile) }))
        }
    }
}

public extension ProfilePictureSwiftUI {
    init?(
        size: ProfilePictureView.Size,
        publicKey: String,
        threadVariant: SessionThread.Variant,
        displayPictureUrl: String?,
        profile: Profile?,
        profileIcon: ProfilePictureView.ProfileIcon = .none,
        additionalProfile: Profile? = nil,
        additionalProfileIcon: ProfilePictureView.ProfileIcon = .none,
        using dependencies: Dependencies
    ) {
        let (info, additionalInfo) = ProfilePictureView.getProfilePictureInfo(
            size: size,
            publicKey: publicKey,
            threadVariant: threadVariant,
            displayPictureUrl: displayPictureUrl,
            profile: profile,
            profileIcon: profileIcon,
            additionalProfile: additionalProfile,
            additionalProfileIcon: additionalProfileIcon,
            using: dependencies
        )
        
        switch info {
            case .none: return nil
            case .some(let info):
                self.init(
                    size: size,
                    info: info,
                    additionalInfo: additionalInfo,
                    dataManager: dependencies[singleton: .imageDataManager]
                )
        }
    }
}
