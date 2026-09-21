import Foundation

/// Anonymous, opt-out product analytics — the ONLY analytics inside the app.
///
/// Every design choice here is deliberate for a privacy-first product:
///   • No third-party SDK. Events POST to our own Worker (`/v1/event`), which
///     forwards to PostHog server-side. Nothing inside the app hands device data
///     to a third party, and there is no extra SDK to audit or declare.
///   • Anonymous. The only identifier is `Backend.deviceID` — a random
///     per-install UUID. No email, no name, no IDFA, and NEVER any transcript or
///     typed content. Payload is an allow-listed event name plus a few primitives.
///   • Off unless enabled. `isEnabled` defaults to false, so this file can ship
///     without collecting anything. Turn it on for a release ONLY after the
///     privacy policy and the App Store privacy label disclose it.
///   • Fire-and-forget. Never blocks, never throws, never affects a dictation.
///
/// To turn it on in a future version: (1) disclose it in the privacy policy and
/// the App Store privacy nutrition label, (2) add a Settings toggle bound to
/// `Analytics.isEnabled`, (3) choose the default posture, and (4) call
/// `Analytics.track(...)` / `.trackOnce(...)` at the event sites in the launch
/// checklist. The Worker's ALLOWED_EVENTS list is the source of truth for names.
public enum Analytics {

    /// Must stay in sync with ALLOWED_EVENTS in backend/src/index.js — the Worker
    /// silently drops anything not on that list.
    public enum Event: String {
        case appOpened = "app_opened"
        case onboardingCompleted = "onboarding_completed"
        case keyboardFullAccessGranted = "keyboard_full_access_granted"
        case firstDictation = "first_dictation"
        case dictationCompleted = "dictation_completed"
        case modeChanged = "mode_changed"
        case engineChanged = "engine_changed"
        case macAppLaunched = "mac_app_launched"
        case macFirstDictation = "mac_first_dictation"
    }

    /// Whether anything is sent at all. Defaults OFF so merging this file collects
    /// nothing; a build only starts sending once this is deliberately enabled AND
    /// the disclosure is in place. Persisted in the shared store so the app and
    /// keyboard agree.
    public static var isEnabled: Bool {
        get { SharedStore.analyticsEnabled }
        set { SharedStore.analyticsEnabled = newValue }
    }

    #if os(macOS)
    private static let platform = "mac"
    #else
    private static let platform = "ios"
    #endif

    /// Send one anonymous event. `properties` is limited to a few primitives by
    /// the Worker's allow-list (platform, app_version, mode, engine, value);
    /// anything else is dropped server-side. Never pass user content here.
    public static func track(_ event: Event, properties: [String: Any] = [:]) {
        guard isEnabled else { return }
        guard let url = URL(string: "\(Backend.baseURL)/v1/event") else { return }

        var props: [String: Any] = ["platform": platform]
        if let v = appVersion { props["app_version"] = v }
        for (k, v) in properties { props[k] = v }

        let payload: [String: Any] = [
            "event": event.rawValue,
            "distinct_id": Backend.deviceID,
            "properties": props,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 5
        req.httpBody = body
        // Fire-and-forget on the shared session; failures are ignored on purpose.
        Task.detached { _ = try? await GroqHTTP.shared.data(for: req) }
    }

    /// Fire an event at most once per install (e.g. `first_dictation`). Uses a
    /// marker in the shared store so it never double-counts across launches.
    public static func trackOnce(_ event: Event, properties: [String: Any] = [:]) {
        let key = "analyticsOnce.\(event.rawValue)"
        guard !SharedStore.boolFlag(key) else { return }
        SharedStore.setBoolFlag(key, true)
        track(event, properties: properties)
    }

    private static var appVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }
}
