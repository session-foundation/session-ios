// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionUtilitiesKit

public extension ProfilePictureView {
    func update(
        publicKey: String,
        threadVariant: SessionThread.Variant,
        displayPictureFilename: String?,
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
            displayPictureFilename: displayPictureFilename,
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
        displayPictureFilename: String?,
        profile: Profile?,
        profileIcon: ProfileIcon = .none,
        additionalProfile: Profile? = nil,
        additionalProfileIcon: ProfileIcon = .none,
        using dependencies: Dependencies
    ) -> (Info?, Info?) {
        // If we are given an explicit 'displayPictureFilename' then only use that (this could be for
        // either Community conversations or updated groups)
        if
            let displayPictureFilename: String = displayPictureFilename,
            let path: String = try? dependencies[singleton: .displayPictureManager]
                .filepath(for: displayPictureFilename)
        {
            return (Info(
                identifier: displayPictureFilename,
                source: .url(URL(fileURLWithPath: path)),
                icon: profileIcon
            ), nil)
        }
        
        // Otherwise there are conversation-type-specific behaviours
        switch threadVariant {
            case .community:
                return (
                    Info(
                        identifier: "\(publicKey)-placeholder",
                        source: {
                            switch size {
                                case .navigation, .message: return .image("SessionWhite16", #imageLiteral(resourceName: "SessionWhite16"))
                                case .list: return .image("SessionWhite24", #imageLiteral(resourceName: "SessionWhite24"))
                                case .hero: return .image("SessionWhite40", #imageLiteral(resourceName: "SessionWhite40"))
                            }
                        }(),
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
                
            case .legacyGroup, .group:
                guard !publicKey.isEmpty else { return (nil, nil) }
                
                return (
                    Info(
                        identifier: (profile?.profilePictureFileName)
                            .defaulting(to: "\(profile?.id ?? publicKey)-placeholder"),
                        source: (
                            profile?.profilePictureFileName
                                .map { try? dependencies[singleton: .displayPictureManager].filepath(for: $0) }
                                .map { ImageDataManager.DataSource.url(URL(fileURLWithPath: $0)) } ??
                            .image(
                                "\(profile?.id ?? publicKey)-placeholder",
                                PlaceholderIcon.generate(
                                    seed: (profile?.id ?? publicKey),
                                    text: (profile?.displayName(for: threadVariant))
                                        .defaulting(to: publicKey),
                                    size: (additionalProfile != nil ?
                                           size.multiImageSize :
                                            size.viewSize
                                          )
                                )
                            )
                        ),
                        icon: profileIcon
                    ),
                    additionalProfile
                        .map { other in
                            Info(
                                identifier: (other.profilePictureFileName)
                                    .defaulting(to: "\(other.id)-placeholder"),
                                source: (
                                    other.profilePictureFileName
                                        .map { fileName in
                                            try? dependencies[singleton: .displayPictureManager]
                                                .filepath(for: fileName)
                                        }
                                        .map { ImageDataManager.DataSource.url(URL(fileURLWithPath: $0)) } ??
                                    .image(
                                        "\(other.id)-placeholder",
                                        PlaceholderIcon.generate(
                                            seed: other.id,
                                            text: other.displayName(for: threadVariant),
                                            size: size.multiImageSize
                                        )
                                    )
                                ),
                                icon: additionalProfileIcon
                            )
                        }
                        .defaulting(
                            to: Info(
                                identifier: "GroupFallbackIcon",    // stringlint:ignore
                                source: .image("person.fill", UIImage(named: "ic_user_round_fill")),
                                renderingMode: .alwaysTemplate,
                                themeTintColor: .white,
                                inset: UIEdgeInsets(
                                    top: 5,
                                    left: 5,
                                    bottom: -3,
                                    right: 5
                                ),
                                icon: additionalProfileIcon
                            )
                        )
                )
                
            case .contact:
                guard !publicKey.isEmpty else { return (nil, nil) }
                
                return (
                    Info(
                        identifier: (profile?.profilePictureFileName)
                            .defaulting(to: "\(publicKey)-placeholder"),
                        source: (
                            profile?.profilePictureFileName
                                .map { try? dependencies[singleton: .displayPictureManager].filepath(for: $0) }
                                .map { ImageDataManager.DataSource.url(URL(fileURLWithPath: $0)) } ??
                            .image(
                                "\(profile?.id ?? publicKey)-placeholder",
                                PlaceholderIcon.generate(
                                    seed: publicKey,
                                    text: (profile?.displayName(for: threadVariant))
                                        .defaulting(to: publicKey),
                                    size: size.viewSize
                                )
                            )
                        ),
                        icon: profileIcon
                    ),
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
        displayPictureFilename: String?,
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
            displayPictureFilename: displayPictureFilename,
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
