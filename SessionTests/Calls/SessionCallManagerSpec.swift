// Copyright © 2026 Session Technology Foundation. All rights reserved.

import UIKit
import GRDB
import WebRTC
import Quick
import Nimble
import SessionUtilitiesKit
import TestUtilities

@testable import Session
@testable import SessionNetworkingKit
@testable import SessionMessagingKit

class SessionCallManagerSpec: AsyncSpec {
    override class func spec() {
        // MARK: Configuration

        let backgroundTaskId: UIBackgroundTaskIdentifier = UIBackgroundTaskIdentifier(rawValue: 1)

        @TestState var dependencies: TestDependencies! = TestDependencies()
        @TestState var mockStorage: Storage! = try! Storage.createForTesting(using: dependencies)
        @TestState var mockAppContext: MockAppContext! = .create(using: dependencies)
        @TestState var mockUserDefaults: MockUserDefaults! = .create(using: dependencies)
        @TestState var mockJobRunner: MockJobRunner! = .create(using: dependencies)
        @TestState var mockNetwork: MockNetwork! = .create(using: dependencies)
        @TestState var mockPoller: MockPoller<Void>! = .create(using: dependencies)
        @TestState var endCallMessageGate: (stream: AsyncStream<Void>, continuation: AsyncStream<Void>.Continuation)! = AsyncStream<Void>.makeStream()
        @TestState var callMessageUpdateGate: (stream: AsyncStream<Void>, continuation: AsyncStream<Void>.Continuation)! = AsyncStream<Void>.makeStream()
        @TestState var events: EventLog! = EventLog()
        @TestState var testCall: TestCall!
        @TestState var manager: SessionCallManager!

        beforeEach {
            dependencies.set(singleton: .storage, to: mockStorage)
            try await mockStorage.perform(migrations: SNMessagingKit.migrations)
            dependencies.set(defaults: .appGroup, to: mockUserDefaults)
            try await mockUserDefaults.defaultInitialSetup()

            dependencies.set(singleton: .appContext, to: mockAppContext)
            try await mockAppContext.when { $0.isMainApp }.thenReturn(true)
            try await mockAppContext.when { $0.reportedApplicationState }.thenReturn(.background)
            try await mockAppContext.when { $0.beginBackgroundTask(expirationHandler: {}) }.thenReturn { _ in
                events.append("beginBackgroundTask")
                return backgroundTaskId
            }
            try await mockAppContext.when { $0.endBackgroundTask(backgroundTaskId) }.thenReturn(())

            dependencies.set(singleton: .jobRunner, to: mockJobRunner)
            try await mockJobRunner.when { await $0.stopAndClearJobs(filters: .any) }.thenReturn(())

            dependencies.set(singleton: .network, to: mockNetwork)
            try await mockNetwork.when { await $0.suspendNetworkAccess() }.thenReturn(())

            dependencies.set(singleton: .currentUserPoller, to: mockPoller)
            try await mockPoller.when { await $0.stop() }.thenReturn(())

            manager = await MainActor.run { SessionCallManager(using: dependencies) }

            /// Models `WebRTCSession.endCall`, whose first step reads the database, and `SessionCall.updateCallMessage`, which
            /// writes to it, each held back until the test releases it
            testCall = TestCall(
                endCallMessageSend: Task { [gate = endCallMessageGate.stream, storage = mockStorage!] in
                    for await _ in gate { break }

                    do { return .success(try await storage.read { _ in }) }
                    catch { return .failure(error) }
                },
                callMessageUpdate: { [gate = callMessageUpdateGate.stream, storage = mockStorage!, events = events!] in
                    events.append("updateCallMessage")

                    return Task {
                        for await _ in gate { break }

                        do { return .success(try await storage.write { _ in }) }
                        catch { return .failure(error) }
                    }
                }
            )
        }

        afterEach {
            endCallMessageGate.continuation.finish()
            callMessageUpdateGate.continuation.finish()
        }

        func endCallLocally(releasingCallMessageUpdate: Bool = true) async {
            await MainActor.run {
                manager.currentCall = testCall
                manager.reportCurrentCallEnded(reason: .declinedElsewhere)
            }

            if releasingCallMessageUpdate {
                callMessageUpdateGate.continuation.yield(())
            }
        }

        // MARK: - a SessionCallManager
        describe("a SessionCallManager") {
            // MARK: -- when a call the user ended in the background is cleaned up
            context("when a call the user ended in the background is cleaned up") {
                // MARK: ---- lets the end call message read the database before suspending it
                it("lets the end call message read the database before suspending it") {
                    await endCallLocally()
                    await mockJobRunner
                        .verify { await $0.stopAndClearJobs(filters: .any) }
                        .wasCalled(exactly: 1, timeout: .seconds(5))

                    /// Give a suspend that doesn't wait for the send the chance to happen before the send reaches its read
                    try await Task.sleep(for: .milliseconds(200))
                    endCallMessageGate.continuation.yield(())

                    await expect { try await testCall.sendResult.get() }.toNot(throwError())
                    await expect(mockStorage.syncState.state).toEventually(equal(.suspended), timeout: .seconds(5))
                }

                // MARK: ---- does not suspend the network until the end call message has been sent
                it("does not suspend the network until the end call message has been sent") {
                    await endCallLocally()
                    await mockJobRunner
                        .verify { await $0.stopAndClearJobs(filters: .any) }
                        .wasCalled(exactly: 1, timeout: .seconds(5))
                    try await Task.sleep(for: .milliseconds(200))

                    await mockNetwork.verify { await $0.suspendNetworkAccess() }.wasNotCalled()
                    expect(mockStorage.syncState.state).toNot(equal(.suspended))

                    endCallMessageGate.continuation.yield(())

                    await mockNetwork.verify { await $0.suspendNetworkAccess() }.wasCalled(exactly: 1, timeout: .seconds(5))
                    await expect(mockStorage.syncState.state).toEventually(equal(.suspended), timeout: .seconds(5))
                }

                // MARK: ---- suspends anyway if the end call message takes too long to send
                it("suspends anyway if the end call message takes too long to send") {
                    await endCallLocally()
                    await mockJobRunner
                        .verify { await $0.stopAndClearJobs(filters: .any) }
                        .wasCalled(exactly: 1, timeout: .seconds(5))

                    /// The timeout only fires if it has started waiting before time is moved past it
                    try await Task.sleep(for: .milliseconds(200))
                    for _ in 0..<10 { await dependencies.stepForwardInTime() }

                    await mockNetwork.verify { await $0.suspendNetworkAccess() }.wasCalled(exactly: 1, timeout: .seconds(5))
                    await expect(mockStorage.syncState.state).toEventually(equal(.suspended), timeout: .seconds(5))
                }

                // MARK: ---- begins a background task before updating the call message
                it("begins a background task before updating the call message") {
                    await endCallLocally()

                    expect(events.all).to(equal(["beginBackgroundTask", "updateCallMessage"]))
                }

                // MARK: ---- lets the call message update write before suspending the database
                it("lets the call message update write before suspending the database") {
                    await endCallLocally(releasingCallMessageUpdate: false)
                    endCallMessageGate.continuation.yield(())
                    await expect { try await testCall.sendResult.get() }.toNot(throwError())
                    try await Task.sleep(for: .milliseconds(200))

                    await mockNetwork.verify { await $0.suspendNetworkAccess() }.wasNotCalled()
                    expect(mockStorage.syncState.state).toNot(equal(.suspended))

                    callMessageUpdateGate.continuation.yield(())

                    await expect { try await testCall.updateResult.get() }.toNot(throwError())
                    await expect(mockStorage.syncState.state).toEventually(equal(.suspended), timeout: .seconds(5))
                }

                // MARK: ---- holds the background task until the database is suspended
                it("holds the background task until the database is suspended") {
                    await endCallLocally(releasingCallMessageUpdate: false)
                    try await Task.sleep(for: .milliseconds(200))

                    await mockAppContext.verify { $0.endBackgroundTask(backgroundTaskId) }.wasNotCalled()

                    callMessageUpdateGate.continuation.yield(())
                    endCallMessageGate.continuation.yield(())

                    await expect(mockStorage.syncState.state).toEventually(equal(.suspended), timeout: .seconds(5))
                    await mockAppContext
                        .verify { $0.endBackgroundTask(backgroundTaskId) }
                        .wasCalled(exactly: 1, timeout: .seconds(5))
                }

                // MARK: ---- suspends once when the call message update finishes first
                it("suspends once when the call message update finishes first") {
                    await endCallLocally(releasingCallMessageUpdate: false)
                    callMessageUpdateGate.continuation.yield(())
                    await expect { try await testCall.updateResult.get() }.toNot(throwError())
                    try await Task.sleep(for: .milliseconds(200))

                    await mockNetwork.verify { await $0.suspendNetworkAccess() }.wasNotCalled()

                    endCallMessageGate.continuation.yield(())

                    await expect { try await testCall.sendResult.get() }.toNot(throwError())
                    await expect(mockStorage.syncState.state).toEventually(equal(.suspended), timeout: .seconds(5))
                    try await Task.sleep(for: .milliseconds(200))
                    await mockNetwork.verify { await $0.suspendNetworkAccess() }.wasCalled(exactly: 1)
                }

                // MARK: ---- suspends once when the end call message finishes first
                it("suspends once when the end call message finishes first") {
                    await endCallLocally(releasingCallMessageUpdate: false)
                    endCallMessageGate.continuation.yield(())
                    await expect { try await testCall.sendResult.get() }.toNot(throwError())
                    try await Task.sleep(for: .milliseconds(200))

                    await mockNetwork.verify { await $0.suspendNetworkAccess() }.wasNotCalled()

                    callMessageUpdateGate.continuation.yield(())

                    await expect { try await testCall.updateResult.get() }.toNot(throwError())
                    await expect(mockStorage.syncState.state).toEventually(equal(.suspended), timeout: .seconds(5))
                    try await Task.sleep(for: .milliseconds(200))
                    await mockNetwork.verify { await $0.suspendNetworkAccess() }.wasCalled(exactly: 1)
                }

                // MARK: ---- does not suspend if the app returned to the foreground before the teardown finished
                it("does not suspend if the app returned to the foreground before the teardown finished") {
                    await endCallLocally()
                    await mockJobRunner
                        .verify { await $0.stopAndClearJobs(filters: .any) }
                        .wasCalled(exactly: 1, timeout: .seconds(5))
                    try await mockAppContext.when { $0.reportedApplicationState }.thenReturn(.active)

                    endCallMessageGate.continuation.yield(())

                    await expect { try await testCall.sendResult.get() }.toNot(throwError())
                    await mockAppContext
                        .verify { $0.endBackgroundTask(backgroundTaskId) }
                        .wasCalled(exactly: 1, timeout: .seconds(5))
                    await mockNetwork.verify { await $0.suspendNetworkAccess() }.wasNotCalled()
                    expect(mockStorage.syncState.state).toNot(equal(.suspended))
                }
            }

            // MARK: -- when a call ends in the foreground
            context("when a call ends in the foreground") {
                beforeEach {
                    try await mockAppContext.when { $0.reportedApplicationState }.thenReturn(.active)
                }

                // MARK: ---- does not suspend anything
                it("does not suspend anything") {
                    await endCallLocally()
                    endCallMessageGate.continuation.yield(())
                    await expect { try await testCall.sendResult.get() }.toNot(throwError())
                    await expect { try await testCall.updateResult.get() }.toNot(throwError())
                    try await Task.sleep(for: .milliseconds(200))

                    await mockAppContext.verify { $0.beginBackgroundTask(expirationHandler: {}) }.wasNotCalled()
                    await mockJobRunner.verify { await $0.stopAndClearJobs(filters: .any) }.wasNotCalled()
                    await mockNetwork.verify { await $0.suspendNetworkAccess() }.wasNotCalled()
                    expect(mockStorage.syncState.state).toNot(equal(.suspended))
                }
            }

            // MARK: -- when a call is reported
            context("when a call is reported") {
                // MARK: ---- stores the call's uuid for the notification extension until it ends
                it("stores the call's uuid for the notification extension until it ends") {
                    /// The simulator doesn't use CallKit so the call is stored without waiting for it
                    await MainActor.run {
                        manager.currentCall = testCall
                        manager.reportIncomingCall(testCall, callerName: "", completion: { _ in })
                    }

                    await mockUserDefaults
                        .verify { $0.set(testCall.uuid as Any?, forKey: UserDefaults.StringKey.ongoingCallUuid.rawValue) }
                        .wasCalled(exactly: 1)
                    await mockUserDefaults
                        .verify { $0.set(String?.none as Any?, forKey: UserDefaults.StringKey.ongoingCallUuid.rawValue) }
                        .wasNotCalled()

                    await endCallLocally()

                    await mockUserDefaults
                        .verify { $0.set(String?.none as Any?, forKey: UserDefaults.StringKey.ongoingCallUuid.rawValue) }
                        .wasCalled(exactly: 1)
                }
            }

            // MARK: -- when the user ends a call
            context("when the user ends a call") {
                afterEach {
                    WebRTCSession.current?.dropConnection()
                    WebRTCSession.current = nil
                }

                // MARK: ---- has the end call message send in hand straight away
                it("has the end call message send in hand straight away") {
                    dependencies.set(singleton: .callManager, to: manager)
                    await dependencies[singleton: .appReadiness].setAppReady()
                    let call: SessionCall = await MainActor.run {
                        SessionCall(
                            for: testCall.sessionId,
                            contactName: "",
                            uuid: testCall.uuid,
                            mode: .offer,
                            using: dependencies
                        )
                    }

                    /// `reportCurrentCallEnded` reads the send straight after this to wait for it before suspending
                    let endCallMessageSend: Task<Void, Never>? = await MainActor.run {
                        call.endSessionCall()
                        return call.endCallMessageSend
                    }

                    expect(endCallMessageSend).toNot(beNil())
                    await endCallMessageSend?.value
                }
            }
        }
    }
}

// MARK: - EventLog

private final class EventLog: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var events: [String] = []

    var all: [String] { lock.withLock { events } }

    func append(_ event: String) {
        lock.withLock { events.append(event) }
    }
}

// MARK: - TestCall

private final class TestCall: CurrentCallProtocol {
    let uuid: String = "11111111-1111-1111-1111-111111111111"
    let callId: UUID = UUID()
    let sessionId: String = "05\(String(repeating: "1", count: 64))"
    var hasStartedConnecting: Bool = true
    var hasEnded: Bool = true
    let mode: CallMode = .offer
    let endCallMessageSend: Task<Void, Never>?

    private let send: Task<Result<Void, Error>, Never>
    private let callMessageUpdate: () -> Task<Result<Void, Error>, Never>
    private var update: Task<Result<Void, Error>, Never>?
    var sendResult: Result<Void, Error> { get async { await send.value } }
    var updateResult: Result<Void, Error> {
        get async { await update?.value ?? .failure(StorageError.objectNotFound) }
    }

    init(
        endCallMessageSend send: Task<Result<Void, Error>, Never>,
        callMessageUpdate: @escaping () -> Task<Result<Void, Error>, Never>
    ) {
        self.send = send
        self.callMessageUpdate = callMessageUpdate
        self.endCallMessageSend = Task { _ = await send.value }
    }

    func updateCallMessage(mode: EndCallMode, using dependencies: Dependencies) -> Task<Void, Never> {
        let update: Task<Result<Void, Error>, Never> = callMessageUpdate()
        self.update = update

        return Task { _ = await update.value }
    }

    func didReceiveRemoteSDP(sdp: RTCSessionDescription) {}
    func startSessionCall(_ db: ObservingDatabase) {}
}
