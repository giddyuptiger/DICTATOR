import Foundation
import FluidAudio

/// Parakeet on the Apple Neural Engine, via FluidAudio. Runs on the Mac and in the
/// iOS *container app* (the free, private, offline transcription tier).
///
/// NOT used by the iPhone keyboard extension: a 0.6B model — or even the 110M one —
/// does not fit the extension's 48 MB ceiling. Transcription always runs in the
/// container app, which is where the recorder lives, so that ceiling never applies.
/// On iOS prefer the `.compact` tier (~250 MB); the `.accurate` tier (~900 MB) is
/// risky on phones (iOS jettisons memory-hungry apps) and is better reserved for
/// the Mac or a future high-RAM/premium path.
public actor LocalParakeet: SpeechProvider {

    public enum Tier: Sendable {
        case accurate   // Parakeet TDT v3, 0.6B
        case compact    // Parakeet TDT-CTC, 110M
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

    private var modelVersion: AsrModelVersion {
        switch tier {
        case .accurate: return .v3
        case .compact:  return .tdtCtc110m
        }
    }

    public func prepare() async throws {
        guard asr == nil else { return }
        // Verified against FluidAudio 0.15.7 (2026-09-14). downloadAndLoad fetches
        // the CoreML bundles into Application Support on first run and loads from
        // that cache afterwards; loadModels is the current name for what earlier
        // versions called initialize(models:).
        let models = try await AsrModels.downloadAndLoad(version: modelVersion)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        asr = manager
    }

    public var isReady: Bool { asr != nil }

    public func transcribe(samples: [Float]) async throws -> String {
        guard let asr else { throw LocalError.notPrepared }
        let trimmed = AudioUtil.trimSilence(samples)
        guard !trimmed.isEmpty else { return "" }
        // Every utterance is independent, so the decoder starts from a fresh
        // state each time rather than carrying context between dictations.
        var decoderState = try TdtDecoderState(decoderLayers: modelVersion.decoderLayers)
        let result = try await asr.transcribe(trimmed, decoderState: &decoderState)
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
