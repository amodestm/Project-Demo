import Foundation
import os

public enum DiscussionEvent: String, Sendable, CaseIterable {
    case discussionStarted        = "DISCUSSION_STARTED"
    case discussionRoundStarted   = "DISCUSSION_ROUND_STARTED"
    case discussionUtteranceSent  = "DISCUSSION_UTTERANCE_SENT"
    case discussionIdentityFailed = "DISCUSSION_IDENTITY_FAILED"
    case discussionConverged      = "DISCUSSION_CONVERGED"
    case discussionFailed         = "DISCUSSION_FAILED"
    case discussionCancelled      = "DISCUSSION_CANCELLED"
}

public struct DiscussionLogger: Sendable {
    private let subsystem: String
    private let category: String
    private let logger: Logger

    public init(subsystem: String = "com.aidiscussion.app", category: String = "Discussion") {
        self.subsystem = subsystem
        self.category = category
        self.logger = Logger(subsystem: subsystem, category: category)
    }

    public func info(_ event: DiscussionEvent, _ message: String) {
        logger.info("[\(event.rawValue)] \(message, privacy: .public)")
        print("[\(DateCoding.string(from: Date()))][INFO][\(event.rawValue)] \(message)")
    }

    public func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        print("[\(DateCoding.string(from: Date()))][INFO] \(message)")
    }

    public func error(_ event: DiscussionEvent, _ message: String) {
        logger.error("[\(event.rawValue)] \(message, privacy: .public)")
        print("[\(DateCoding.string(from: Date()))][ERROR][\(event.rawValue)] \(message)")
    }

    public func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        print("[\(DateCoding.string(from: Date()))][ERROR] \(message)")
    }

    public func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }
}
