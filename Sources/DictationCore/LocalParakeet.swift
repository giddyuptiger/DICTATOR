import Foundation
import FluidAudio

/// Parakeet on the Apple Neural Engine, via FluidAudio. Mac only.
///
/// Not used on the iPhone keyboard: a 0.6B model, or even the 120M one, does not
/// fit the extension's 48 MB ceiling. It would fit in the iOS *container app*, so
/// if you later add a "dictate into Dictator's own notes screen" feature, this class
/// works there.
public actor LocalParakeet: SpeechProvider {

    public enum Tier: Sendable {
        case accurate   // Parakeet TDT v3, 0.6B
        case compact    // Parakeet EOU, 120M
    }

    private let tier: Tier
    private var asr: AsrManager?

    public init(tier: Tier = .accurate) {
        self.tier = tier
    }

    nonisolated public var approximateMemoryFootprintMB: Int {
        switch tier {
        case .accurate: return 900
        case .compact:  return 250
        }
    }

    public func prepare() async throws {
        guard asr == nil else { return }
        // Check this call against FluidAudio's current README before trusting it;
        // the package is young and its loading API has been moving.
        let models = try await AsrModels.downloadAndLoad()
        let manager = AsrManager(config: .default)
        try await manager.initialize(models: models)
        asr = manager
    }

    public var isReady: Bool { asr != nil }

    public func transcribe(samples: [Float]) async throws -> String {
        guard let asr else { throw LocalError.notPrepared }
        let trimmed = AudioUtil.trimSilence(samples)
        guard !trimmed.isEmpty else { return "" }
        let result = try await asr.transcribe(trimmed)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func unload() {
        asr = nil
    }

    public enum LocalError: Error, LocalizedError {
        case notPrepared
        public var errorDescription: String? { "Speech model has not finished loading." }
    }
}
