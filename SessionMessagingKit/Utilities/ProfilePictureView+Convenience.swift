// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUIKit

public extension ProfilePictureView {
    // FIXME: Remove this in the UserConfig branch
    func update(
        publicKey: String = "",
        profile: Profile? = nil,
        icon: ProfileIcon = .none,
        additionalProfile: Profile? = nil,
        additionalIcon: ProfileIcon = .none,
        threadVariant: SessionThread.Variant,
        openGroupProfilePictureData: Data? = nil,
        useFallbackPicture: Bool = false,
        showMultiAvatarForClosedGroup: Bool = false
    ) {
        guard !useFallbackPicture else {
            let placeholderImage: UIImage = {
                switch self.size {
                    case .navigation, .message: return #imageLiteral(resourceName: "SessionWhite16")
                    case .list: return #imageLiteral(resourceName: "SessionWhite24")
                    case .hero: return #imageLiteral(resourceName: "SessionWhite40")
                }
            }()
            
            return update(
                Info(
                    imageData: placeholderImage.pngData(),
                    inset: UIEdgeInsets(
                        top: 12,
                        left: 12,
                        bottom: 12,
                        right: 12
                    ),
                    forcedBackgroundColor: .theme(.classicDark, color: .borderSeparator)
                )
            )
        }
        guard openGroupProfilePictureData == nil else {
            return update(Info(imageData: openGroupProfilePictureData))
        }
        
        switch (threadVariant, showMultiAvatarForClosedGroup) {
            case (.closedGroup, true):
                update(
                    Info(
                        imageData: (
                            profile.map { ProfileManager.profileAvatar(profile: $0) } ??
                            PlaceholderIcon.generate(
                                seed: publicKey,
                                text: (profile?.displayName(for: threadVariant))
                                    .defaulting(to: publicKey),
                                size: (additionalProfile != nil ?
                                    self.size.multiImageSize :
                                    self.size.viewSize
                                )
                            ).pngData()
                        )
                    ),
                    additionalInfo: additionalProfile
                        .map { otherProfile in
                            Info(
                                imageData: (
                                    ProfileManager.profileAvatar(profile: otherProfile) ??
                                    PlaceholderIcon.generate(
                                        seed: otherProfile.id,
                                        text: otherProfile.displayName(for: threadVariant),
                                        size: self.size.multiImageSize
                                    ).pngData()
                                )
                            )
                        }
                        .defaulting(
                            to: Info(
                                imageData: UIImage(systemName: "person.fill")?.pngData(),
                                renderingMode: .alwaysTemplate,
                                themeTintColor: .white,
                                inset: UIEdgeInsets(
                                    top: 3,
                                    left: 0,
                                    bottom: -5,
                                    right: 0
                                )
                            )
                        )
                )

            default:
                update(
                    Info(
                        imageData: (
                            profile.map { ProfileManager.profileAvatar(profile: $0) } ??
                            PlaceholderIcon.generate(
                                seed: publicKey,
                                text: (profile?.displayName(for: threadVariant))
                                    .defaulting(to: publicKey),
                                size: (additionalProfile != nil ?
                                    self.size.multiImageSize :
                                    self.size.viewSize
                                )
                            ).pngData()
                        )
                    )
                )
        }
    }
    
    func update(
        publicKey: String,
        threadVariant: SessionThread.Variant,
        customImageData: Data?,
        profile: Profile?,
        additionalProfile: Profile?
    ) {
        // If we are given 'customImageData' then only use that
        guard customImageData == nil else { return update(Info(imageData: customImageData)) }
        
        // Otherwise there are conversation-type-specific behaviours
        switch threadVariant {
            case .openGroup:
                let placeholderImage: UIImage = {
                    switch self.size {
                        case .navigation, .message: return #imageLiteral(resourceName: "SessionWhite16")
                        case .list: return #imageLiteral(resourceName: "SessionWhite24")
                        case .hero: return #imageLiteral(resourceName: "SessionWhite40")
                    }
                }()
                
                update(
                    Info(
                        imageData: placeholderImage.pngData(),
                        inset: UIEdgeInsets(
                            top: 12,
                            left: 12,
                            bottom: 12,
                            right: 12
                        ),
                        forcedBackgroundColor: .theme(.classicDark, color: .borderSeparator)
                    )
                )
                
            case .closedGroup: //.legacyGroup, .group:
                guard !publicKey.isEmpty else { return }
                // TODO: Test that this doesn't call 'PlaceholderIcon.generate' when the original value exists
                update(
                    Info(
                        imageData: (
                            profile.map { ProfileManager.profileAvatar(profile: $0) } ??
                            PlaceholderIcon.generate(
                                seed: publicKey,
                                text: (profile?.displayName(for: threadVariant))
                                    .defaulting(to: publicKey),
                                size: (additionalProfile != nil ?
                                    self.size.multiImageSize :
                                    self.size.viewSize
                                )
                            ).pngData()
                        )
                    ),
                    additionalInfo: additionalProfile
                        .map { otherProfile in
                            Info(
                                imageData: (
                                    ProfileManager.profileAvatar(profile: otherProfile) ??
                                    PlaceholderIcon.generate(
                                        seed: otherProfile.id,
                                        text: otherProfile.displayName(for: threadVariant),
                                        size: self.size.multiImageSize
                                    ).pngData()
                                )
                            )
                        }
                        .defaulting(
                            to: Info(
                                imageData: UIImage(systemName: "person.fill")?.pngData(),
                                renderingMode: .alwaysTemplate,
                                themeTintColor: .white,
                                inset: UIEdgeInsets(
                                    top: 3,
                                    left: 0,
                                    bottom: -5,
                                    right: 0
                                )
                            )
                        )
                )
                
            case .contact:
                guard !publicKey.isEmpty else { return }
                
                update(
                    Info(
                        imageData: (
                            profile.map { ProfileManager.profileAvatar(profile: $0) } ??
                            PlaceholderIcon.generate(
                                seed: publicKey,
                                text: (profile?.displayName(for: threadVariant))
                                    .defaulting(to: publicKey),
                                size: (additionalProfile != nil ?
                                    self.size.multiImageSize :
                                    self.size.viewSize
                                )
                            ).pngData()
                        )
                    )
                )
        }
    }
}
