// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import UniformTypeIdentifiers
import GRDB
import SessionNetworkingKit
import SessionUtilitiesKit

/// This migration renames all attachments to use a hash of the download url for the filename instead of a random UUID (means we can
/// generate the filename just from the URL and don't need to store the filename)
enum _028_RenameAttachments: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "RenameAttachments"
    static let minExpectedRunDuration: TimeInterval = 3
    static let createdTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        /// Define the paths and ensure they exist
        let sharedDataProfileAvatarDirPath: String = URL(fileURLWithPath: SessionFileManager.nonInjectedAppSharedDataDirectoryPath)
            .appendingPathComponent("ProfileAvatars")
            .path
        let sharedDataDisplayPicturesDirPath: String = URL(fileURLWithPath: SessionFileManager.nonInjectedAppSharedDataDirectoryPath)
            .appendingPathComponent("DisplayPictures")
            .path
        let sharedDataAttachmentsDirPath: String = URL(fileURLWithPath: SessionFileManager.nonInjectedAppSharedDataDirectoryPath)
            .appendingPathComponent("Attachments")
            .path
        try? dependencies[singleton: .fileManager].ensureDirectoryExists(at: sharedDataProfileAvatarDirPath)
        try? dependencies[singleton: .fileManager].ensureDirectoryExists(at: sharedDataDisplayPicturesDirPath)
        try? dependencies[singleton: .fileManager].ensureDirectoryExists(at: sharedDataAttachmentsDirPath)
        
        /// Fetch the data we need from the database
        let profileInfo: [Row] = try Row.fetchAll(
            db,
            sql: """
            SELECT profilePictureUrl, profilePictureFileName
            FROM profile
            WHERE profilePictureFileName IS NOT NULL
        """)
        let communityInfo: [Row] = try Row.fetchAll(
            db,
            sql: """
            SELECT server, roomToken, imageId, displayPictureFilename
            FROM openGroup
            WHERE displayPictureFilename IS NOT NULL
        """)
        let groupInfo: [Row] = try Row.fetchAll(
            db,
            sql: """
            SELECT displayPictureUrl, displayPictureFilename
            FROM closedGroup
            WHERE displayPictureFilename IS NOT NULL
        """)
        
        /// This change is unrelated to the attachments but since we are dropping deprecated columns we may as well do this one
        try db.execute(sql: "ALTER TABLE thread DROP COLUMN isPinned")
        
        /// Drop the unused columns and rename others for consistency (do this before moving the files in case there is an error as the
        /// database query can be rolled back but moving files can't)
        /// `profilePictureFileName` - deprecated by this migration
        /// `profilePictureUrl` to `displayPictureUrl` for consistency
        /// `profileEncryptionKey` to `displayPictureEncryptionKey` for consistency
        /// `lastProfilePictureUpdate` to `displayPictureLastUpdated` for consistency
        try db.execute(sql: "ALTER TABLE profile DROP COLUMN profilePictureFileName")
        try db.execute(sql: "ALTER TABLE profile RENAME COLUMN profilePictureUrl TO displayPictureUrl")
        try db.execute(sql: "ALTER TABLE profile RENAME COLUMN profileEncryptionKey TO displayPictureEncryptionKey")
        try db.execute(sql: "ALTER TABLE profile RENAME COLUMN lastProfilePictureUpdate TO displayPictureLastUpdated")
        
        /// Group changes:
        /// `displayPictureFilename` - deprecated by this migration
        /// `lastDisplayPictureUpdate` - the `GroupInfo` config has a `seqNo` so don't need this for V2 groups
        try db.execute(sql: "ALTER TABLE closedGroup DROP COLUMN displayPictureFilename")
        try db.execute(sql: "ALTER TABLE closedGroup DROP COLUMN lastDisplayPictureUpdate")
        
        /// Since the filename is a hash of the URL if the API changes then the hash generated would change so we need to store
        /// the `originalDisplayPictureUrl` that was used to generate the hash so we can always generate the same filename
        try db.alter(table: "openGroup") { table in
            table.add(column: "displayPictureOriginalUrl", .text)
        }
        let processedCommunityInfo: [(urlString: String, filename: String)] = try communityInfo.compactMap { info in
            guard
                let server: String = info["server"] as? String,
                let roomToken: String = info["roomToken"] as? String,
                let imageId: String = info["imageId"] as? String,
                let filename: String = info["displayPictureFilename"] as? String,
                dependencies[singleton: .fileManager].fileExists(
                    atPath: sharedDataProfileAvatarDirPath.appending("/\(filename)")
                ),
                /// At the time of writing this migration this was the structure of the downloadUrl for a community display picture
                let urlString: String = "\(server)/room/\(roomToken)/file/\(imageId)".nullIfEmpty
            else { return nil }
            
            try db.execute(
                sql: "UPDATE openGroup SET displayPictureOriginalUrl = ? WHERE displayPictureFilename = ?",
                arguments: [urlString, filename]
            )
            
            return (urlString, filename)
        }
        
        /// Now that we've set the `originalDisplayPictureUrl` values we can drop the unused columns:
        /// `displayPictureFilename` - deprecated by this migration
        /// `imageData` - old deprecated column
        /// `lastDisplayPictureUpdate` - `OpenGroup` has an `imageId` so don't need this
        try db.execute(sql: "ALTER TABLE openGroup DROP COLUMN displayPictureFilename")
        try db.execute(sql: "ALTER TABLE openGroup DROP COLUMN imageData") /// Old deprecated column
        try db.execute(sql: "ALTER TABLE openGroup DROP COLUMN lastDisplayPictureUpdate")
        
        /// Quotes now render using the original message attachment rather than a separate attachment file so we can remove any
        /// legacy quote attachments
        try db.execute(sql: """
            DELETE FROM attachment
            WHERE (
                sourceFilename LIKE 'quoted-thumbnail-%' OR
                downloadUrl = 'NON_MEDIA_QUOTE_FILE_ID'
            )
        """)
        
        /// There also seemed to be an issue where the `encryptionKey` and `digest` could incorrectly be 0-byte values instead
        /// of `NULL` so we should clean that up as well
        try db.execute(sql: """
            UPDATE attachment
            SET encryptionKey = NULL, digest = NULL
            WHERE LENGTH(encryptionKey) = 0 OR LENGTH(digest) = 0
        """)
        
        /// Fetch attachment data which we care about and then drop the unneeded columns
        let attachmentInfo: [Row] = try Row.fetchAll(
            db,
            sql: """
            SELECT id, downloadUrl, localRelativeFilePath
            FROM attachment
            WHERE localRelativeFilePath IS NOT NULL
        """)
        try db.execute(sql: "ALTER TABLE attachment DROP COLUMN localRelativeFilePath")
        try db.execute(sql: "DROP INDEX IF EXISTS quote_on_attachmentId")
        try db.execute(sql: "ALTER TABLE quote DROP COLUMN attachmentId")
        
        /// There was a point where we weren't correctly storing the `downloadUrl` and, since the files path is now derived from it,
        /// we will need to set it to some value so we can still generate a unique file path for it - we _might_ be able to "recover" the
        /// original url in some cases if we were to join and fetch thread-related data but there isn't much benefit to doing so, so we just
        /// generate a unique invalid url instead
        ///
        /// Since we need to iterate through the `attachmentInfo` to do this we may as well fenerate the final set
        /// of `filename` <-> `urlHash` values at the same time
        let attachmentsToRename: [(filename: String, urlHash: String)] = []
            .appending(
                contentsOf: try attachmentInfo.enumerated().compactMap { index, info in
                    let urlString: String = {
                        if let urlString: String = (info["downloadUrl"] as? String)?.nullIfEmpty {
                            return urlString
                        }
                        
                        return Network.FileServer.downloadUrlString(for: "invalid-legacy-file-\(index)")
                    }()
                    
                    guard
                        let filename: String = info["localRelativeFilePath"] as? String,
                        dependencies[singleton: .fileManager].fileExists(
                            atPath: sharedDataAttachmentsDirPath.appending("/\(filename)")
                        ),
                        let urlHash: String = dependencies[singleton: .crypto]
                            .generate(.hash(message: Array(urlString.utf8)))?
                            .toHexString()
                    else {
                        /// The file somehow doens't exist on the system so we should mark the attachment as invalid
                        if let id: String = info["id"] as? String {
                            Log.info(.migration, "Marking attachment \(id) (\(urlString)) as invalid as it's local file is missing")
                            try db.execute(
                                sql: """
                                    UPDATE attachment
                                    SET isValid = false
                                    WHERE id = ?
                                """,
                                arguments: [id]
                            )
                        }
                        
                        return nil
                    }
                    
                    return (filename, urlHash)
                }
            )
        
        /// Generate a final set of `filename` <-> `urlHash` values
        let displayPicturesToRename: [(filename: String, urlHash: String)] = []
            .appending(
                contentsOf: profileInfo.compactMap { info in
                    guard
                        let urlString: String = info["profilePictureUrl"] as? String,
                        let filename: String = info["profilePictureFileName"] as? String,
                        dependencies[singleton: .fileManager].fileExists(
                            atPath: sharedDataProfileAvatarDirPath.appending("/\(filename)")
                        ),
                        let urlHash: String = dependencies[singleton: .crypto]
                            .generate(.hash(message: Array(urlString.utf8)))?
                            .toHexString()
                    else { return nil }
                    
                    return (filename, urlHash)
                }
            )
            .appending(
                contentsOf: processedCommunityInfo.compactMap { urlString, filename in
                    /// Already checked for the file existence so no need to do so here
                    guard
                        let urlHash: String = dependencies[singleton: .crypto]
                            .generate(.hash(message: Array(urlString.utf8)))?
                            .toHexString()
                    else { return nil }
                    
                    return (filename, urlHash)
                }
            )
            .appending(
                contentsOf: groupInfo.compactMap { info in
                    guard
                        let urlString: String = info["displayPictureUrl"] as? String,
                        let filename: String = info["displayPictureFilename"] as? String,
                        dependencies[singleton: .fileManager].fileExists(
                            atPath: sharedDataProfileAvatarDirPath.appending("/\(filename)")
                        ),
                        let urlHash: String = dependencies[singleton: .crypto]
                            .generate(.hash(message: Array(urlString.utf8)))?
                            .toHexString()
                    else { return nil }
                    
                    return (filename, urlHash)
                }
            )
        
        /// Go through and actually rename the display picture files
        ///
        /// **Note:** The old file names **all** had a `jpg` extension (even if they weren't `jpg` files) so for the new files we
        /// just don't give them extensions
        var processedHashes: Set<String> = []
        displayPicturesToRename.forEach { filename, urlHash in
            do {
                try dependencies[singleton: .fileManager].moveItem(
                    atPath: sharedDataProfileAvatarDirPath.appending("/\(filename)"),
                    toPath: sharedDataDisplayPicturesDirPath.appending("/\(urlHash)")
                )
                processedHashes.insert(urlHash)
            }
            catch {
                /// It looks like there was an issue previously where multiple profiles could use the same URL but end up with
                /// different files (because the generated name was random), now these will end up with the same name so if
                /// that occurs we just want to remove the duplicate file
                if processedHashes.contains(urlHash) {
                    try? dependencies[singleton: .fileManager].removeItem(
                        atPath: sharedDataProfileAvatarDirPath.appending("/\(filename)")
                    )
                }
                else {
                    Log.warn("Failed to rename display picture due to error: \(error)")
                }
            }
        }
        
        /// Remove the old `ProfileAvatars` path
        try? dependencies[singleton: .fileManager].removeItem(atPath: sharedDataProfileAvatarDirPath)
        
        /// Go through and actually rename the attachment files
        ///
        /// **Note:** The old file names included extensions but we already store a `contentType` in the database which is used
        /// when handling the file rather than the extension so don't bother adding the extension
        var processedAttachmentHashes: Set<String> = []
        attachmentsToRename.forEach { filename, urlHash in
            do {
                try dependencies[singleton: .fileManager].moveItem(
                    atPath: sharedDataAttachmentsDirPath.appending("/\(filename)"),
                    toPath: sharedDataAttachmentsDirPath.appending("/\(urlHash)")
                )
                processedAttachmentHashes.insert(urlHash)
                
                /// Attachments could previously be stored in child directories so if we just moved the only file in an attachments
                /// directory then we should remove the directory
                if filename.contains("/") {
                    let directoryPath: String = sharedDataAttachmentsDirPath
                        .appending("/\(String(filename.split(separator: "/")[0]))")
                    
                    if dependencies[singleton: .fileManager].isDirectoryEmpty(atPath: directoryPath) {
                        try? dependencies[singleton: .fileManager].removeItem(atPath: directoryPath)
                    }
                }
            }
            catch {
                /// There are some rare cases where an attachment could resolve to the same hash as another attachment so we
                /// also need to handle that case here - attachments can also be stored in child directories so we need to detect that
                /// case as well
                if processedAttachmentHashes.contains(urlHash) {
                    let targetLastPathComponent: String = (filename.contains("/") ?
                        String(filename.split(separator: "/")[0]) :
                        filename
                    )
                    
                    try? dependencies[singleton: .fileManager].removeItem(
                        atPath: sharedDataAttachmentsDirPath.appending("/\(targetLastPathComponent)")
                    )
                }
                else {
                    Log.warn("Failed to rename attachment due to error: \(error)")
                }
            }
        }
        
        MigrationExecution.updateProgress(1)
    }
}
