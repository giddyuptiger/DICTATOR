package design.irons.dictator

/**
 * The cleanup safety net, ported from `Cleaner.reconcile` in
 * Sources/DictationCore/Cleanup.swift.
 *
 * The backend returns (raw, cleaned). A cleanup model can misbehave: return an
 * empty string, treat the transcript as a request and refuse it, drop content, or
 * balloon into an answer. This never lets that overwrite what the user actually
 * said — it falls back to the raw transcript in those cases.
 *
 * For modes where [DictationMode.transformsWording] is true (Patois,
 * Shakespearean) the word-count / overlap fidelity guards are SKIPPED, because a
 * correct translation legitimately changes the words. The empty/refusal guards
 * still apply to every mode.
 */
object Cleaner {

    /**
     * Reconcile the raw transcript with the server-cleaned text and return the
     * string to insert. No network. Inputs are trimmed internally.
     *
     * @param raw the raw transcript (may be empty).
     * @param cleaned the server-cleaned text.
     * @param mode the active mode, which decides whether the fidelity guards run.
     */
    fun reconcile(raw: String, cleaned: String, mode: DictationMode): String {
        val rawT = raw.trim()
        val cleanT = cleaned.trim()

        // Empty cleanup -> use the raw transcript (the user's words are never lost).
        if (cleanT.isEmpty()) return rawT

        // Refusal cleanup -> use raw, UNLESS the transcript itself opens like a
        // refusal (someone genuinely dictating "I'm sorry...").
        if (looksLikeRefusal(cleanT) && !looksLikeRefusal(rawT)) return rawT

        // Fidelity guards below assume cleanup only reformats the SAME words. The
        // wording-transform modes deliberately rewrite, so skip them there.
        if (!mode.transformsWording && rawT.isNotEmpty()) {
            val rawWords = wordCount(rawT)
            val cleanWords = wordCount(cleanT)

            // Content-fidelity guard: under half the words of a non-trivial
            // transcript means content was cut. Keep the user's words.
            if (rawWords >= 12 && cleanWords * 2 < rawWords) return rawT

            // Ramble guard: a model that ANSWERS balloons the output. Reformatting
            // never doubles length.
            if (rawWords >= 3 && cleanWords > rawWords * 2 + 12) return rawT

            // Answer guard: a reply won't contain the user's own words. If fewer
            // than 60% of the raw words survive, it answered rather than reformatted.
            val rawSet = wordSet(rawT)
            if (rawSet.size >= 5) {
                val kept = rawSet.intersect(wordSet(cleanT)).size.toDouble() / rawSet.size
                if (kept < 0.6) return rawT
            }
        }

        return cleanT
    }

    /**
     * Whether a cleanup result reads as the model refusing or apologising rather
     * than reformatting. Checked against the OUTPUT; the caller confirms the raw
     * transcript does not itself start this way.
     */
    private fun looksLikeRefusal(text: String): Boolean {
        val t = text.lowercase()
        val openers = listOf(
            "i'm sorry", "i am sorry", "sorry, ", "i cannot", "i can't", "i can not",
            "i'm not able", "i am not able", "i'm unable", "i am unable",
            "i won't", "i will not", "i'm just an", "i am just an", "as an ai",
            "i can't help", "i cannot help", "i can't assist", "i cannot assist",
            "i can't provide", "i cannot provide", "i'm not going to", "unfortunately, i",
        )
        return openers.any { t.startsWith(it) }
    }

    private fun wordCount(s: String): Int =
        s.split(Regex("\\s+")).count { it.isNotEmpty() }

    private fun wordSet(s: String): Set<String> =
        s.lowercase()
            .split(Regex("[^\\p{L}\\p{N}]+"))
            .filter { it.isNotEmpty() }
            .toSet()
}
