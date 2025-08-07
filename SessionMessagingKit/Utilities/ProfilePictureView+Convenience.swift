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
    ) -> (Info?, Info?) {
        let explicitPath: String? = try? dependencies[singleton: .displayPictureManager].path(
            for: displayPictureUrl
        )
        
        switch (explicitPath, publicKey.isEmpty, threadVariant) {
            case (.some(let path), _, _):
                let shouldAnimated: Bool = {
                    guard let profile: Profile = profile else {
                        return threadVariant == .community
                    }
                    return profile.shoudAnimateProfilePicture(using: dependencies)
                }()
                /// If we are given an explicit `displayPictureUrl` then only use that
                return (Info(
                    source: .url(URL(fileURLWithPath: path)),
                    shouldAnimated: shouldAnimated,
                    isCurrentUser: (publicKey == dependencies[cache: .general].sessionId.hexString),
                    icon: profileIcon,
                ), nil)
            
            case (_, _, .community):
                return (
                    Info(
                        source: {
                            switch size {
                                case .navigation, .message: return .image("SessionWhite16", #imageLiteral(resourceName: "SessionWhite16"))
                                case .list: return .image("SessionWhite24", #imageLiteral(resourceName: "SessionWhite24"))
                                case .hero, .modal: return .image("SessionWhite40", #imageLiteral(resourceName: "SessionWhite40"))
                            }
                        }(),
                        shouldAnimated: true,
                        isCurrentUser: false,
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
            
            case (_, true, _): return (nil, nil)
                
            case (_, _, .legacyGroup), (_, _, .group):
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
                        shouldAnimated: (profile?.shoudAnimateProfilePicture(using: dependencies) ?? false),
                        isCurrentUser: (profile?.id == dependencies[cache: .general].sessionId.hexString),
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
                                shouldAnimated: other.shoudAnimateProfilePicture(using: dependencies),
                                isCurrentUser: (other.id == dependencies[cache: .general].sessionId.hexString),
                                icon: additionalProfileIcon
                            )
                        }
                        .defaulting(
                            to: Info(
                                source: .image("ic_user_round_fill", UIImage(named: "ic_user_round_fill")),
                                shouldAnimated: false,
                                isCurrentUser: false,
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
                
            case (_, _, .contact):
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
                        shouldAnimated: (profile?.shoudAnimateProfilePicture(using: dependencies) ?? false),
                        isCurrentUser: (profile?.id == dependencies[cache: .general].sessionId.hexString),
                        icon: profileIcon),
                    nil
                )
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
                    dataManager: dependencies[singleton: .imageDataManager],
                    sessionProState: dependencies[singleton: .sessionProState]
                )
        }
    }
}
