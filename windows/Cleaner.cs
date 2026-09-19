namespace Dictator;

/// <summary>
/// The cleanup safety net, ported from Cleaner.reconcile in Sources/DictationCore/
/// Cleanup.swift. The backend already runs the cleanup model, but a bad cleanup must
/// never overwrite the user's actual words — so we reconcile the (raw, cleaned) pair
/// locally with NO network call and decide which string to inject.
///
/// Every guard falls back to the RAW transcript when the cleaned text looks empty,
/// refused, gutted, ballooned, or diverged from the words actually said. The
/// fidelity guards are skipped for modes that deliberately rewrite the wording
/// (Patois, Shakespearean) — see <see cref="ToneProfiles.TransformsWording"/>.
/// </summary>
public static class Cleaner
{
    /// <summary>
    /// Given the raw transcript and the server's cleaned text, return the text to
    /// actually inject. Both are trimmed internally.
    /// </summary>
    public static string Reconcile(string raw, string cleaned, DictationMode mode)
    {
        var rawTrimmed = raw.Trim();
        var cleanedTrimmed = cleaned.Trim();

        // If the transcript itself is empty there is nothing to do.
        if (rawTrimmed.Length == 0) return cleanedTrimmed;

        // A cleanup model can return an empty string, or treat the transcript as a
        // request and refuse it. Never let that replace what the user said.
        if (cleanedTrimmed.Length == 0)
            return rawTrimmed;

        if (LooksLikeRefusal(cleanedTrimmed) && !LooksLikeRefusal(rawTrimmed))
            return rawTrimmed;

        // The fidelity guards assume cleanup only reformats the SAME words. Patois /
        // Shakespearean deliberately rewrite the wording, so these guards would
        // wrongly discard a correct translation — skip them for those modes. The
        // empty/refusal guards above still apply.
        if (!mode.TransformsWording())
        {
            int rawWords = WordCount(rawTrimmed);
            int cleanWords = WordCount(cleanedTrimmed);

            // Content-fidelity guard: cleanup must reformat, not summarize. If the
            // cleaned text is under half the word count of a non-trivial transcript,
            // content was cut — keep the user's actual words.
            if (rawWords >= 12 && cleanWords * 2 < rawWords)
                return rawTrimmed;

            // Ramble guard: a model that ANSWERS the transcript balloons the output.
            // Reformatting never doubles length, so a big expansion means it went off
            // the rails.
            if (rawWords >= 3 && cleanWords > rawWords * 2 + 12)
                return rawTrimmed;

            // Answer guard: a cleanup that REPLIES won't contain the user's own words.
            // If fewer than 60% of the raw words survive, the model answered rather
            // than reformatted.
            var rawSet = WordSet(rawTrimmed);
            if (rawSet.Count >= 5)
            {
                var cleanSet = WordSet(cleanedTrimmed);
                int keptCount = rawSet.Count(w => cleanSet.Contains(w));
                double kept = (double)keptCount / rawSet.Count;
                if (kept < 0.6)
                    return rawTrimmed;
            }
        }

        return cleanedTrimmed;
    }

    /// <summary>
    /// Whether a cleanup result reads as the model refusing or apologising rather than
    /// reformatting. Checked against the model's OUTPUT; the caller also confirms the
    /// raw transcript does not itself start this way.
    /// </summary>
    private static bool LooksLikeRefusal(string text)
    {
        var t = text.ToLowerInvariant();
        foreach (var opener in RefusalOpeners)
            if (t.StartsWith(opener, StringComparison.Ordinal))
                return true;
        return false;
    }

    private static readonly string[] RefusalOpeners =
    {
        "i'm sorry", "i am sorry", "sorry, ", "i cannot", "i can't", "i can not",
        "i'm not able", "i am not able", "i'm unable", "i am unable",
        "i won't", "i will not", "i'm just an", "i am just an", "as an ai",
        "i can't help", "i cannot help", "i can't assist", "i cannot assist",
        "i can't provide", "i cannot provide", "i'm not going to", "unfortunately, i",
    };

    private static int WordCount(string s) =>
        s.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;

    private static HashSet<string> WordSet(string s)
    {
        var set = new HashSet<string>();
        var current = new System.Text.StringBuilder();
        foreach (var ch in s.ToLowerInvariant())
        {
            if (char.IsLetterOrDigit(ch))
            {
                current.Append(ch);
            }
            else if (current.Length > 0)
            {
                set.Add(current.ToString());
                current.Clear();
            }
        }
        if (current.Length > 0) set.Add(current.ToString());
        return set;
    }
}
