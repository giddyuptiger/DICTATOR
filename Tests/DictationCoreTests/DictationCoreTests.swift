import XCTest
@testable import DictationCore

// These cover the parts of the pipeline that are pure logic: the WAV container,
// silence trimming, the personal dictionary, tone selection, and the cleanup
// fallbacks. Nothing here touches the microphone, the network, the App Group or
// iCloud, so it runs anywhere and runs fast.
//
// Package.swift has declared this test target since the beginning and the
// directory did not exist, so `swift build` and `swift test` both failed on a
// fresh clone before these were added.

// MARK: - WAV

final class WAVEncoderTests: XCTestCase {

    private func u16(_ d: Data, _ offset: Int) -> UInt16 {
        UInt16(d[offset]) | UInt16(d[offset + 1]) << 8
    }

    private func u32(_ d: Data, _ offset: Int) -> UInt32 {
        var v: UInt32 = 0
        for i in (0..<4).reversed() { v = v << 8 | UInt32(d[offset + i]) }
        return v
    }

    private func i16(_ d: Data, _ offset: Int) -> Int16 {
        Int16(bitPattern: u16(d, offset))
    }

    private func ascii(_ d: Data, _ range: Range<Int>) -> String {
        String(decoding: d[range], as: UTF8.self)
    }

    func testHeaderDescribesTheAudioItContains() {
        let samples: [Float] = [0, 0.5, -0.5, 1.0, -1.0]
        let wav = WAVEncoder.encode(samples: samples, sampleRate: 16_000)

        XCTAssertEqual(wav.count, 44 + samples.count * 2, "44-byte header plus 16-bit mono samples")

        XCTAssertEqual(ascii(wav, 0..<4), "RIFF")
        XCTAssertEqual(u32(wav, 4), UInt32(36 + samples.count * 2), "RIFF chunk size excludes the first 8 bytes")
        XCTAssertEqual(ascii(wav, 8..<12), "WAVE")

        XCTAssertEqual(ascii(wav, 12..<16), "fmt ")
        XCTAssertEqual(u32(wav, 16), 16, "PCM fmt chunk is 16 bytes")
        XCTAssertEqual(u16(wav, 20), 1, "format 1 is uncompressed PCM")
        XCTAssertEqual(u16(wav, 22), 1, "mono")
        XCTAssertEqual(u32(wav, 24), 16_000)
        XCTAssertEqual(u32(wav, 28), 32_000, "byte rate is rate * channels * bytes per sample")
        XCTAssertEqual(u16(wav, 32), 2, "block align")
        XCTAssertEqual(u16(wav, 34), 16, "bits per sample")

        XCTAssertEqual(ascii(wav, 36..<40), "data")
        XCTAssertEqual(u32(wav, 40), UInt32(samples.count * 2))
    }

    func testSampleRateIsNotHardCoded() {
        let wav = WAVEncoder.encode(samples: [0], sampleRate: 8_000)
        XCTAssertEqual(u32(wav, 24), 8_000)
        XCTAssertEqual(u32(wav, 28), 16_000)
    }

    func testSamplesScaleToSixteenBit() {
        let wav = WAVEncoder.encode(samples: [0, 0.5, -0.5, 1.0, -1.0])
        XCTAssertEqual(i16(wav, 44), 0)
        XCTAssertEqual(i16(wav, 46), 16_383)
        XCTAssertEqual(i16(wav, 48), -16_383)
        XCTAssertEqual(i16(wav, 50), 32_767)
        XCTAssertEqual(i16(wav, 52), -32_767)
    }

    /// A hot microphone can hand us samples outside -1...1. Without the clamp
    /// these wrap around and the listener hears a click on every peak.
    func testHotSamplesClampInsteadOfWrapping() {
        let wav = WAVEncoder.encode(samples: [4.0, -4.0])
        XCTAssertEqual(i16(wav, 44), 32_767)
        XCTAssertEqual(i16(wav, 46), -32_767)
    }

    func testEmptyInputStillProducesAValidHeader() {
        let wav = WAVEncoder.encode(samples: [])
        XCTAssertEqual(wav.count, 44)
        XCTAssertEqual(u32(wav, 40), 0)
    }
}

// MARK: - Trimming

final class AudioUtilTests: XCTestCase {

    private func silence(_ count: Int) -> [Float] { [Float](repeating: 0, count: count) }

    private func tone(_ count: Int, amplitude: Float = 0.5) -> [Float] {
        (0..<count).map { amplitude * ((($0 / 8) % 2 == 0) ? 1 : -1) }
    }

    func testLeadingAndTrailingSilenceAreRemoved() {
        let samples = silence(4_800) + tone(4_800) + silence(4_800)
        let trimmed = AudioUtil.trimSilence(samples)

        // Speech runs 4800..<9600. Trimming keeps it plus 50 ms of air each side.
        XCTAssertEqual(trimmed.count, 6_400)
        XCTAssertLessThan(trimmed.count, samples.count)
    }

    /// The padding is the point: clipping the first phoneme is worse than
    /// uploading a few extra kilobytes.
    func testAirIsLeftAroundTheSpeech() {
        let samples = silence(4_800) + tone(4_800) + silence(4_800)
        let trimmed = AudioUtil.trimSilence(samples)
        XCTAssertGreaterThan(trimmed.count, 4_800, "speech kept, plus padding")
    }

    func testSilenceCollapsesFarBelowTheUploadThreshold() {
        // GroqTranscription refuses anything under 1,600 samples, so a silent
        // clip must land under that however long it was.
        for length in [4_800, 32_000, 160_000] {
            let trimmed = AudioUtil.trimSilence(silence(length))
            XCTAssertLessThan(trimmed.count, 1_600, "\(length) samples of silence should collapse")
        }
    }

    func testEmptyInputIsReturnedUnchanged() {
        XCTAssertTrue(AudioUtil.trimSilence([]).isEmpty)
    }

    func testSpeechWithNoSilenceSurvivesIntact() {
        let samples = tone(4_800)
        XCTAssertEqual(AudioUtil.trimSilence(samples).count, samples.count)
    }

    func testRMS() {
        XCTAssertEqual(AudioUtil.rms([1, 1, 1, 1]), 1.0, accuracy: 0.0001)
        XCTAssertEqual(AudioUtil.rms([0, 0]), 0.0, accuracy: 0.0001)
        XCTAssertEqual(AudioUtil.rms([]), 0.0, accuracy: 0.0001)
        XCTAssertEqual(AudioUtil.rms([-1, 1]), 1.0, accuracy: 0.0001, "sign does not reduce energy")
    }
}

// MARK: - Personal dictionary

final class PersonalDictionaryTests: XCTestCase {

    func testMishearingsAreReplacedWithTheCanonicalSpelling() {
        let d = PersonalDictionary(entries: [
            .init(canonical: "Egoscue", misheard: ["ego skew", "ego q"])
        ])
        XCTAssertEqual(d.apply(to: "I did ego skew today"), "I did Egoscue today")
        XCTAssertEqual(d.apply(to: "I did EGO SKEW today"), "I did Egoscue today", "matching is case-insensitive")
        XCTAssertEqual(d.apply(to: "try ego q now"), "try Egoscue now")
    }

    func testReplacementIsWholeWordOnly() {
        let d = PersonalDictionary(entries: [.init(canonical: "Egoscue", misheard: ["ego skew"])])
        XCTAssertEqual(d.apply(to: "ego skewing"), "ego skewing", "a longer word is not a mishearing")
    }

    func testTextWithNoMishearingsIsUntouched() {
        let d = PersonalDictionary(entries: [.init(canonical: "Egoscue", misheard: ["ego skew"])])
        XCTAssertEqual(d.apply(to: "nothing to fix here"), "nothing to fix here")
    }

    func testAddMergesMishearingsForTheSameWord() {
        var d = PersonalDictionary()
        d.add(.init(canonical: "Egoscue", misheard: ["ego skew"]))
        d.add(.init(canonical: "egoscue", misheard: ["ego q"]))

        XCTAssertEqual(d.entries.count, 1, "same word, different capitalisation, one entry")
        XCTAssertEqual(d.entries[0].canonical, "Egoscue", "the first spelling wins")
        XCTAssertEqual(d.entries[0].misheard.sorted(), ["ego q", "ego skew"])
    }

    func testAddDoesNotDuplicateAMishearingItAlreadyHas() {
        var d = PersonalDictionary()
        d.add(.init(canonical: "Egoscue", misheard: ["ego skew"]))
        d.add(.init(canonical: "Egoscue", misheard: ["ego skew"]))
        XCTAssertEqual(d.entries[0].misheard, ["ego skew"])
    }

    func testRemove() {
        var d = PersonalDictionary(entries: [.init(canonical: "Egoscue")])
        d.remove(canonical: "EGOSCUE")
        XCTAssertTrue(d.entries.isEmpty, "removal is case-insensitive too")
    }

    func testLearnRecordsACorrection() {
        var d = PersonalDictionary()
        d.learn(misheard: "ego skew", corrected: "Egoscue")
        XCTAssertEqual(d.apply(to: "ego skew"), "Egoscue")
    }

    func testLearnIgnoresNonCorrections() {
        var d = PersonalDictionary()
        d.learn(misheard: "same", corrected: "SAME")
        d.learn(misheard: "", corrected: "something")
        d.learn(misheard: "something", corrected: "")
        XCTAssertTrue(d.entries.isEmpty)
    }

    func testPromptHintListsTermsAndIsCapped() {
        XCTAssertEqual(PersonalDictionary().promptHint(), "", "no words, nothing to bias with")

        let many = (0..<100).map { PersonalDictionary.Entry(canonical: "Word\($0)") }
        let hint = PersonalDictionary(entries: many).promptHint(limit: 60)
        XCTAssertTrue(hint.contains("Word0"))
        XCTAssertTrue(hint.contains("Word59"))
        XCTAssertFalse(hint.contains("Word60"), "capped so it cannot dominate the prompt")
    }

    func testRoundTripsThroughJSON() throws {
        let original = PersonalDictionary(entries: [.init(canonical: "Egoscue", misheard: ["ego skew"])])
        let decoded = try JSONDecoder().decode(
            PersonalDictionary.self,
            from: try JSONEncoder().encode(original)
        )
        XCTAssertEqual(decoded.entries, original.entries)
    }
}

// MARK: - Tone profiles

final class ToneProfileTests: XCTestCase {

    func testKnownAppsGetTheirProfile() {
        XCTAssertEqual(ToneProfile.forBundleID("com.apple.Terminal").name, "Code and terminal")
        XCTAssertEqual(ToneProfile.forBundleID("com.apple.MobileSMS").name, "Messaging")
        XCTAssertEqual(ToneProfile.forBundleID("com.apple.Notes").name, "Longform writing")
    }

    func testUnknownAndMissingAppsFallBackToNeutral() {
        XCTAssertEqual(ToneProfile.forBundleID("com.example.nothing").name, "Neutral")
        XCTAssertEqual(ToneProfile.forBundleID(nil).name, "Neutral")
    }

    func testSystemPromptCarriesTheProfileTheDictionaryAndTheMode() {
        let prompt = ToneProfile.code.systemPrompt(
            dictionaryHint: "Known proper nouns: Egoscue",
            mode: .formal
        )
        XCTAssertTrue(prompt.contains("transcription formatter"), "the base framing")
        XCTAssertTrue(prompt.contains("Technical register"), "the profile's own instructions")
        XCTAssertTrue(prompt.contains("Egoscue"), "the dictionary bias")
        XCTAssertTrue(prompt.contains("FORMAL"), "the mode the speaker chose")
    }

    /// The mode is appended last so that where it disagrees with the field's
    /// profile, the register the speaker picked by hand wins.
    func testModeComesAfterTheProfile() {
        let prompt = ToneProfile.messaging.systemPrompt(dictionaryHint: "", mode: .formal)
        let profileAt = prompt.range(of: "Casual register")
        let modeAt = prompt.range(of: "FORMAL")
        XCTAssertNotNil(profileAt)
        XCTAssertNotNil(modeAt)
        if let profileAt, let modeAt {
            XCTAssertLessThan(profileAt.lowerBound, modeAt.lowerBound)
        }
    }

    func testEmptyDictionaryHintIsOmitted() {
        let withHint = ToneProfile.neutral.systemPrompt(dictionaryHint: "Known terms: Egoscue", mode: .casual)
        let without = ToneProfile.neutral.systemPrompt(dictionaryHint: "", mode: .casual)
        XCTAssertTrue(withHint.contains("Egoscue"))
        XCTAssertFalse(without.contains("Known terms"))
        XCTAssertLessThan(without.count, withHint.count, "no empty section is added for an absent hint")
    }

    func testEveryModeHasADistinctLabelAndInstructions() {
        let labels = DictationMode.allCases.map(\.displayName)
        XCTAssertEqual(Set(labels).count, labels.count)
        for mode in DictationMode.allCases {
            XCTAssertFalse(mode.instructions.isEmpty, "\(mode) has no instructions")
        }
    }
}

// MARK: - Cleanup

private struct StubCleanup: CleanupProvider {
    enum Failure: Error { case unreachable }
    /// nil means "throw", to stand in for a network failure.
    let returns: String?

    func clean(_ raw: String, system: String) async throws -> String {
        guard let returns else { throw Failure.unreachable }
        return returns
    }
}

final class CleanerTests: XCTestCase {

    private let dictionary = PersonalDictionary(entries: [
        .init(canonical: "Egoscue", misheard: ["ego skew"])
    ])

    /// The bug this guards: the model's output was trimmed to test it for a
    /// refusal, and then the UNTRIMMED text was returned. Models routinely end a
    /// response with a newline, so dictating into a chat box put the caret on a
    /// new line and, in some apps, sent the message.
    func testModelWhitespaceIsNotInsertedIntoTheUsersText() async {
        let cleaner = Cleaner(provider: StubCleanup(returns: "  Hello there.\n\n"), dictionary: dictionary)
        let result = await cleaner.process("hello there", profile: .neutral)

        XCTAssertEqual(result.text, "Hello there.")
        XCTAssertTrue(result.usedProvider)
        XCTAssertNil(result.note)
    }

    func testDictionaryStillRunsOverTheModelsOutput() async {
        let cleaner = Cleaner(provider: StubCleanup(returns: "I tried ego skew."), dictionary: dictionary)
        let result = await cleaner.process("i tried ego skew", profile: .neutral)
        XCTAssertEqual(result.text, "I tried Egoscue.", "the dictionary wins any disagreement")
    }

    func testWithNoProviderTheDictionaryPassStillApplies() async {
        let cleaner = Cleaner(provider: nil, dictionary: dictionary)
        let result = await cleaner.process("  i tried ego skew  ", profile: .neutral)

        XCTAssertEqual(result.text, "i tried Egoscue")
        XCTAssertFalse(result.usedProvider)
        XCTAssertEqual(result.note, "no cleanup provider")
    }

    /// Never let the model's failure replace what the user actually said.
    func testARefusalFallsBackToTheRawTranscript() async {
        let cleaner = Cleaner(
            provider: StubCleanup(returns: "I'm sorry, but I can't help with that."),
            dictionary: dictionary
        )
        let result = await cleaner.process("delete the staging database", profile: .neutral)

        XCTAssertEqual(result.text, "delete the staging database")
        XCTAssertFalse(result.usedProvider)
        XCTAssertEqual(result.note, "cleanup refused; used raw transcript")
    }

    /// ...but someone who genuinely dictates an apology keeps their words.
    func testAnApologyTheSpeakerActuallySaidIsNotTreatedAsARefusal() async {
        let cleaner = Cleaner(
            provider: StubCleanup(returns: "I'm sorry I missed the meeting."),
            dictionary: dictionary
        )
        let result = await cleaner.process("i'm sorry i missed the meeting", profile: .neutral)

        XCTAssertEqual(result.text, "I'm sorry I missed the meeting.")
        XCTAssertTrue(result.usedProvider)
    }

    func testAnEmptyCompletionFallsBackToTheRawTranscript() async {
        let cleaner = Cleaner(provider: StubCleanup(returns: "   \n "), dictionary: dictionary)
        let result = await cleaner.process("something worth keeping", profile: .neutral)

        XCTAssertEqual(result.text, "something worth keeping")
        XCTAssertFalse(result.usedProvider)
        XCTAssertEqual(result.note, "cleanup returned empty; used raw transcript")
    }

    func testANetworkFailureFallsBackAndSaysWhy() async {
        let cleaner = Cleaner(provider: StubCleanup(returns: nil), dictionary: dictionary)
        let result = await cleaner.process("i tried ego skew", profile: .neutral)

        XCTAssertEqual(result.text, "i tried Egoscue", "words kept, dictionary still applied")
        XCTAssertFalse(result.usedProvider)
        XCTAssertEqual(result.note?.hasPrefix("cleanup skipped:"), true)
    }

    func testEmptyInputIsNotSentAnywhere() async {
        let cleaner = Cleaner(provider: StubCleanup(returns: "should never be used"), dictionary: dictionary)
        let result = await cleaner.process("   \n  ", profile: .neutral)

        XCTAssertEqual(result.text, "")
        XCTAssertFalse(result.usedProvider)
    }
}
