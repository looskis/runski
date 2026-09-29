import Foundation
import CoreGraphics
import IOKit.pwr_mgt

/// Host idle detection and sleep prevention.
public enum HostPower {
    /// Seconds since the last keyboard/mouse/trackpad event in the login session.
    public static func idleSeconds() -> TimeInterval {
        let anyInput = CGEventType(rawValue: ~0)!
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    /// Holds an `IOPMAssertion` so the Mac does not idle-sleep while a job runs.
    public final class SleepAssertion: @unchecked Sendable {
        private var id: IOPMAssertionID = 0
        private var active = false

        public init(reason: String) {
            let ok = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
            active = ok == kIOReturnSuccess
        }

        public func release() {
            guard active else { return }
            IOPMAssertionRelease(id)
            active = false
        }

        deinit { release() }
    }
}
