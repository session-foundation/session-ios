// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import AVFoundation

public extension AVURLAsset {
    static func asset(for path: String, mimeType: String?, sourceFilename: String?, using dependencies: Dependencies) -> (asset: AVURLAsset, cleanup: () -> Void)? {
        if #available(iOS 17.0, *) {
            /// Since `mimeType` can be null we need to try to resolve it to a value
            let finalMimeType: String
            
            switch (mimeType, sourceFilename) {
                case (.none, .none): return nil
                case (.some(let mimeType), _): finalMimeType = mimeType
                case (.none, .some(let sourceFilename)):
                    guard
                        let type: UTType = UTType(
                            sessionFileExtension: URL(fileURLWithPath: sourceFilename).pathExtension
                        ),
                        let mimeType: String = type.sessionMimeType
                    else { return nil }
                    
                    finalMimeType = mimeType
            }
            
            return (
                AVURLAsset(
                    url: URL(fileURLWithPath: path),
                    options: [AVURLAssetOverrideMIMETypeKey: finalMimeType]
                ),
                {}
            )
        }
        else {
            /// Since `mimeType` and/or `sourceFilename` can be null we need to try to resolve them both to values
            let finalExtension: String
            
            switch (mimeType, sourceFilename) {
                case (.none, .none): return nil
                case (.none, .some(let sourceFilename)):
                    guard
                        let type: UTType = UTType(
                            sessionFileExtension: URL(fileURLWithPath: sourceFilename).pathExtension
                        ),
                        let fileExtension: String = type.sessionFileExtension(sourceFilename: sourceFilename)
                    else { return nil }
                    
                    finalExtension = fileExtension
                    
                case (.some(let mimeType), let sourceFilename):
                    guard
                        let fileExtension: String = UTType(sessionMimeType: mimeType)?
                            .sessionFileExtension(sourceFilename: sourceFilename)
                    else { return nil }
                    
                    finalExtension = fileExtension
            }
            
            let tmpPath: String = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
                .appendingPathExtension(finalExtension)
                .path
            
            try? dependencies[singleton: .fileManager].copyItem(atPath: path, toPath: tmpPath)
            
            return (
                AVURLAsset(url: URL(fileURLWithPath: tmpPath), options: nil),
                { [dependencies] in try? dependencies[singleton: .fileManager].removeItem(atPath: tmpPath) }
            )
        }
    }
}
