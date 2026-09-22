import Foundation

/// The one place that decides whether a Pro feature is available.
///
/// Until the paywall ships, everything is allowed: TestFlight testers need to
/// use the features to judge them, and there is no entitlement to check yet.
/// When RevenueCat lands, `allows` consults the entitlement — and nothing else
/// in the codebase changes, because every Pro feature already asks here.
///
/// Pro line items (see the business plan): AI cleanup and cloud transcription,
/// swipe typing, the keyboard's Polish key, extra tone modes, Mac ↔ iPhone sync.
public enum Pro {

    public enum Feature: Sendable {
        case aiCleanup
        case cloudTranscription
        case swipeTyping
        case polish
        case extraToneModes
    }

    /// Whether `feature` may be used right now.
    public static func allows(_ feature: Feature) -> Bool {
        true
    }
}
