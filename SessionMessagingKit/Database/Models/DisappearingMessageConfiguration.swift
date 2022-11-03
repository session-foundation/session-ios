// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

public struct DisappearingMessagesConfiguration: Codable, Identifiable, Equatable, Hashable, FetchableRecord, PersistableRecord, TableRecord, ColumnExpressible {
    public static var databaseTableName: String { "disappearingMessagesConfiguration" }
    internal static let threadForeignKey = ForeignKey([Columns.threadId], to: [SessionThread.Columns.id])
    private static let thread = belongsTo(SessionThread.self, using: threadForeignKey)
    
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case threadId
        case isEnabled
        case durationSeconds
        case type
        case lastChangeTimestampMs
    }
    
    public enum DisappearingMessageType: Int, Codable, Hashable, DatabaseValueConvertible {
        case disappearAfterRead
        case disappearAfterSend
        
        init(protoType: SNProtoContent.SNProtoContentExpirationType) {
            switch protoType {
                case .deleteAfterSend:
                    self = .disappearAfterSend
                case .deleteAfterRead:
                    self = .disappearAfterRead
            }
        }
        
        func toProto() -> SNProtoContent.SNProtoContentExpirationType {
            switch self {
                case .disappearAfterRead:
                    return .deleteAfterRead
                case .disappearAfterSend:
                    return .deleteAfterSend
            }
        }
    }
    
    public var id: String { threadId }  // Identifiable

    public let threadId: String
    public let isEnabled: Bool
    public let durationSeconds: TimeInterval
    public var type: DisappearingMessageType?
    public let lastChangeTimestampMs: Int64
    
    // MARK: - Relationships
    
    public var thread: QueryInterfaceRequest<SessionThread> {
        request(for: DisappearingMessagesConfiguration.thread)
    }
}

// MARK: - Mutation

public extension DisappearingMessagesConfiguration {
    static let defaultDuration: TimeInterval = (24 * 60 * 60)
    
    static func defaultWith(_ threadId: String) -> DisappearingMessagesConfiguration {
        return DisappearingMessagesConfiguration(
            threadId: threadId,
            isEnabled: false,
            durationSeconds: defaultDuration,
            type: nil,
            lastChangeTimestampMs: 0
        )
    }
    
    func with(
        isEnabled: Bool? = nil,
        durationSeconds: TimeInterval? = nil,
        type: DisappearingMessageType? = nil,
        lastChangeTimestampMs: Int64? = nil
    ) -> DisappearingMessagesConfiguration {
        return DisappearingMessagesConfiguration(
            threadId: threadId,
            isEnabled: (isEnabled ?? self.isEnabled),
            durationSeconds: (durationSeconds ?? self.durationSeconds),
            type: (isEnabled == false) ? nil : (type ?? self.type),
            lastChangeTimestampMs: (lastChangeTimestampMs ?? self.lastChangeTimestampMs)
        )
    }
}

// MARK: - Convenience

public extension DisappearingMessagesConfiguration {
    struct MessageInfo: Codable {
        public let senderName: String?
        public let isEnabled: Bool
        public let durationSeconds: TimeInterval
        public let type: DisappearingMessageType?
        public let isPreviousOff: Bool?
        
        var previewText: String {
            guard let senderName: String = senderName else {
                // TODO: "YOU"
                // Changed by this device or via synced transcript
                guard isEnabled, durationSeconds > 0 else { return "YOU_DISABLED_DISAPPEARING_MESSAGES_CONFIGURATION".localized() }
                
                return String(
                    format: "YOU_UPDATED_DISAPPEARING_MESSAGES_CONFIGURATION".localized(),
                    floor(durationSeconds).formatted(format: .long)
                )
            }
            
            guard isEnabled, durationSeconds > 0 else {
                return String(format: "DISAPPERING_MESSAGES_INFO_DISABLE".localized(), senderName)
            }
            
            guard isPreviousOff == true else {
                return String(
                    format: "DISAPPERING_MESSAGES_INFO_UPDATE".localized(),
                    senderName,
                    floor(durationSeconds).formatted(format: .long),
                    (type == .disappearAfterRead ? "MESSAGE_STATE_READ".localized() : "MESSAGE_STATE_SENT".localized())
                )
            }
            
            return String(
                format: "DISAPPERING_MESSAGES_INFO_ENABLE".localized(),
                senderName,
                floor(durationSeconds).formatted(format: .long),
                (type == .disappearAfterRead ? "MESSAGE_STATE_READ".localized() : "MESSAGE_STATE_SENT".localized())
            )
        }
    }
    
    var durationString: String {
        floor(durationSeconds).formatted(format: .long)
    }
    
    func messageInfoString(with senderName: String?, isPreviousOff: Bool) -> String? {
        let messageInfo: MessageInfo = DisappearingMessagesConfiguration.MessageInfo(
            senderName: senderName,
            isEnabled: isEnabled,
            durationSeconds: durationSeconds,
            type: type,
            isPreviousOff: isPreviousOff
        )
        
        guard let messageInfoData: Data = try? JSONEncoder().encode(messageInfo) else { return nil }
        
        return String(data: messageInfoData, encoding: .utf8)
    }
}

// MARK: - UI Constraints

extension DisappearingMessagesConfiguration {
    public static var validDurationsSeconds: [TimeInterval] {
        return [
            5,
            10,
            30,
            (1 * 60),
            (5 * 60),
            (30 * 60),
            (1 * 60 * 60),
            (6 * 60 * 60),
            (12 * 60 * 60),
            (24 * 60 * 60),
            (7 * 24 * 60 * 60)
        ]
    }
    
    public static var maxDurationSeconds: TimeInterval = {
        return (validDurationsSeconds.max() ?? 0)
    }()
    
    public static func validDurationsSeconds(_ type: DisappearingMessageType) -> [TimeInterval] {
        switch type {
            case .disappearAfterRead:
                return [
                    (5 * 60),
                    (1 * 60 * 60),
                    (12 * 60 * 60),
                    (24 * 60 * 60),
                    (7 * 24 * 60 * 60),
                    (2 * 7 * 24 * 60 * 60)
                ]
            case .disappearAfterSend:
                return [
                    (12 * 60 * 60),
                    (24 * 60 * 60),
                    (7 * 24 * 60 * 60),
                    (2 * 7 * 24 * 60 * 60)
                ]
            }
    }
}

// MARK: - Objective-C Support

// TODO: Remove this when possible

@objc(SMKDisappearingMessagesConfiguration)
public class SMKDisappearingMessagesConfiguration: NSObject {
    @objc public static var maxDurationSeconds: UInt = UInt(DisappearingMessagesConfiguration.maxDurationSeconds)
    
    @objc public static var validDurationsSeconds: [UInt] = DisappearingMessagesConfiguration
        .validDurationsSeconds
        .map { UInt($0) }
    
    @objc(isEnabledFor:)
    public static func isEnabled(for threadId: String) -> Bool {
        return Storage.shared
            .read { db in
                try DisappearingMessagesConfiguration
                    .select(.isEnabled)
                    .filter(id: threadId)
                    .asRequest(of: Bool.self)
                    .fetchOne(db)
            }
            .defaulting(to: false)
    }
    
    @objc(durationIndexFor:)
    public static func durationIndex(for threadId: String) -> Int {
        let durationSeconds: TimeInterval = Storage.shared
            .read { db in
                try DisappearingMessagesConfiguration
                    .select(.durationSeconds)
                    .filter(id: threadId)
                    .asRequest(of: TimeInterval.self)
                    .fetchOne(db)
            }
            .defaulting(to: DisappearingMessagesConfiguration.defaultDuration)
        
        return DisappearingMessagesConfiguration.validDurationsSeconds
            .firstIndex(of: durationSeconds)
            .defaulting(to: 0)
    }
    
    @objc(durationStringFor:)
    public static func durationString(for index: Int) -> String {
        let durationSeconds: TimeInterval = (
            index >= 0 && index < DisappearingMessagesConfiguration.validDurationsSeconds.count ?
                DisappearingMessagesConfiguration.validDurationsSeconds[index] :
                DisappearingMessagesConfiguration.validDurationsSeconds[0]
        )
        
        return floor(durationSeconds).formatted(format: .long)
    }
}
