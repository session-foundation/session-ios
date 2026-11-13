// Copyright © 2026 Session Technology Foundation. All rights reserved.

import Foundation
import TestUtilities

import Quick
import Nimble

@testable import SessionUtilitiesKit

/// **These specs use the real file system** (a directory under `NSTemporaryDirectory()`), because the behaviour under test is
/// the operating system's
class SessionFileManagerSpec: AsyncSpec {
    override class func spec() {
        // MARK: Configuration

        @TestState var dependencies: TestDependencies! = TestDependencies()
        @TestState var fileManager: SessionFileManager! = SessionFileManager(using: dependencies)
        @TestState var directoryPath: String! = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SessionFileManagerSpec-\(UUID().uuidString)")
            .path

        beforeEach {
            try FileManager.default.createDirectory(atPath: directoryPath, withIntermediateDirectories: true)
        }

        afterEach {
            try? FileManager.default.removeItem(atPath: directoryPath)
            try? FileManager.default.removeItem(atPath: fileManager.temporaryDirectory)
        }

        // MARK: - a SessionFileManager
        describe("a SessionFileManager") {
            // MARK: -- when removing a directory if it is empty
            context("when removing a directory if it is empty") {
                // MARK: ---- removes an empty directory
                it("removes an empty directory") {
                    expect(FileManager.default.fileExists(atPath: directoryPath)).to(beTrue())

                    expect(fileManager.removeDirectoryIfEmpty(atPath: directoryPath)).to(beTrue())
                    expect(FileManager.default.fileExists(atPath: directoryPath)).to(beFalse())
                }

                // MARK: ---- leaves a directory and its contents when it is not empty
                it("leaves a directory and its contents when it is not empty") {
                    let filePath: String = URL(fileURLWithPath: directoryPath).appendingPathComponent("record").path
                    expect(FileManager.default.createFile(atPath: filePath, contents: Data([1]))).to(beTrue())

                    expect(fileManager.removeDirectoryIfEmpty(atPath: directoryPath)).to(beFalse())
                    expect(FileManager.default.fileExists(atPath: directoryPath)).to(beTrue())
                    expect(FileManager.default.fileExists(atPath: filePath)).to(beTrue())
                }

                // MARK: ---- does nothing when the directory does not exist
                it("does nothing when the directory does not exist") {
                    let missingPath: String = URL(fileURLWithPath: directoryPath).appendingPathComponent("missing").path

                    expect(fileManager.removeDirectoryIfEmpty(atPath: missingPath)).to(beFalse())
                }

                // MARK: ---- does not remove a file
                it("does not remove a file") {
                    let filePath: String = URL(fileURLWithPath: directoryPath).appendingPathComponent("record").path
                    expect(FileManager.default.createFile(atPath: filePath, contents: Data([1]))).to(beTrue())

                    expect(fileManager.removeDirectoryIfEmpty(atPath: filePath)).to(beFalse())
                    expect(FileManager.default.fileExists(atPath: filePath)).to(beTrue())
                }
            }
        }
    }
}
