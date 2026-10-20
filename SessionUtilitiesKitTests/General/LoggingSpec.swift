// Copyright © 2026 Session Technology Foundation. All rights reserved.

import Foundation
import TestUtilities

import Quick
import Nimble

@testable import SessionUtilitiesKit

private extension Log.Category {
    static let spec: Log.Category = .create("LoggingSpecCategory", defaultLevel: .info)
}

class LoggingSpec: AsyncSpec {
    override class func spec() {
        // MARK: Configuration

        @TestState var logDirectory: String! = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LoggingSpec-\(UUID().uuidString)")
            .path
        @TestState var dependencies: TestDependencies! = TestDependencies()
        @TestState var mockAppContext: MockAppContext! = .create(using: dependencies)

        func makeLogger() -> Logger {
            return Logger(primaryPrefix: "LoggingSpec", customDirectory: logDirectory, using: dependencies)
        }

        func flushAndReset() async {
            await withCheckedContinuation { continuation in
                Log.flushAndReset { continuation.resume() }
            }
        }

        /// `Logger` writes "yyyy/MM/dd HH:mm:ss:SSSa ZZZZZ", the AM/PM marker is redundant with a 24 hour clock and makes parsing
        /// afternoon times ambiguous so it's dropped
        func readLog() -> [(date: Date, message: String)] {
            let formatter: DateFormatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy/MM/dd HH:mm:ss:SSS ZZZZZ"

            let files: [String] = ((try? FileManager.default.contentsOfDirectory(atPath: logDirectory)) ?? [])

            return files
                .compactMap { try? String(contentsOfFile: "\(logDirectory!)/\($0)", encoding: .utf8) }
                .flatMap { $0.components(separatedBy: "\n") }
                .compactMap { line in
                    guard let separator: Range<String.Index> = line.range(of: "  ") else { return nil }
                    let timestamp: String = String(line[..<separator.lowerBound])
                        .replacingOccurrences(of: "[ap]m", with: "", options: [.regularExpression, .caseInsensitive])
                    
                    guard let date: Date = formatter.date(from: timestamp) else { return nil }

                    return (date, String(line[separator.upperBound...]))
                }
        }

        beforeEach {
            dependencies.set(singleton: .appContext, to: mockAppContext)
            try await mockAppContext.when { $0.isMainApp }.thenReturn(false)
            Log.reset()
        }

        afterEach {
            Log.reset()
            try? FileManager.default.removeItem(atPath: logDirectory)
        }

        // MARK: - Log
        describe("Log") {
            // MARK: -- writes logs raised before it was set up with the time they were raised
            it("writes logs raised before it was set up with the time they were raised") {
                let raisedAt: Date = Date()
                Log.info(.spec, "Raised before setup")
                try await Task.sleep(for: .milliseconds(500))

                Log.setup(with: makeLogger())
                await flushAndReset()

                let entry = readLog().first(where: { $0.message.contains("Raised before setup") })
                expect(entry).toNot(beNil())
                expect(abs(entry?.date.timeIntervalSince(raisedAt) ?? .greatestFiniteMagnitude)).to(beLessThan(0.2))
            }

            // MARK: -- writes every log raised while it is starting up
            it("writes every log raised while it is starting up") {
                Log.setup(with: makeLogger())
                DispatchQueue.concurrentPerform(iterations: 200) { index in
                    Log.info(.spec, "Startup log \(index)")
                }
                await flushAndReset()

                expect(readLog().filter { $0.message.contains("Startup log ") }.count).to(equal(200))
            }

            // MARK: -- writes logs from one thread in the order they were raised
            it("writes logs from one thread in the order they were raised") {
                Log.setup(with: makeLogger())
                (0..<100).forEach { Log.info(.spec, "Ordered log \($0).") }
                await flushAndReset()

                let indexes: [Int] = readLog()
                    .compactMap { entry -> Int? in
                        guard let range: Range<String.Index> = entry.message.range(of: "Ordered log ") else { return nil }

                        return Int(entry.message[range.upperBound...].dropLast())
                    }
                expect(indexes).to(equal(Array(0..<100)))
            }

            // MARK: -- only completes a flush and reset once the logs are on disk
            it("only completes a flush and reset once the logs are on disk") {
                Log.setup(with: makeLogger())
                Log.info(.spec, "Last log before completing")

                let wasOnDisk: Bool = await withCheckedContinuation { continuation in
                    Log.flushAndReset {
                        continuation.resume(
                            returning: readLog().contains(where: { $0.message.contains("Last log before completing") })
                        )
                    }
                }

                expect(wasOnDisk).to(beTrue())
            }

            // MARK: -- writes nothing but the logged lines for an extension
            it("writes nothing but the logged lines for an extension") {
                Log.setup(with: makeLogger())
                try await Task.sleep(for: .milliseconds(100))   /// Let it resume before logging
                Log.info(.spec, "Only line")
                await flushAndReset()
                
                expect(readLog().map { $0.message }).to(equal(["💛 [LoggingSpec, LoggingSpecCategory] Only line"]))
            }
            
            // MARK: -- keeps the logs of every logger which used the same directory
            it("keeps the logs of every logger which used the same directory") {
                for index in 0..<6 {
                    Log.setup(with: makeLogger())
                    Log.info(.spec, "Run \(index)")
                    await flushAndReset()
                }
                
                expect(readLog().filter { $0.message.contains("Run ") }.count).to(equal(6))
            }
            
            // MARK: -- hands logs raised with no logger to the next one
            it("hands logs raised with no logger to the next one") {
                Log.setup(with: makeLogger())
                await flushAndReset()
                Log.info(.spec, "Raised with no logger")

                /// The next logger picks it up instead
                Log.setup(with: makeLogger())
                await flushAndReset()

                expect(readLog().filter { $0.message.contains("Raised with no logger") }.count).to(equal(1))
            }
        }
    }
}
