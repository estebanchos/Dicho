import Foundation

/// M12 eval-harness tokenizer + number normalizer. Pure logic.
///
/// Produces "alignment units" from raw text: usually one unit per
/// whitespace-separated word (leading/trailing punctuation split off, internal
/// punctuation like apostrophes, hyphens, and dots preserved), with two
/// normalizations that keep formatting differences out of the MAJOR bucket:
/// - runs of spelled-out cardinals collapse into one digit unit
///   ("one thousand seventy" → "1070"; "a thousand" → "1000") — the collapse
///   is greedy, so counting sequences ("one two three" → "6") and
///   digit-by-digit phone numbers would merge wrongly; fixture scripts must
///   avoid those shapes (covered by a documented-quirk test),
/// - ordinals canonicalize across forms ("first" ≡ "1st"),
/// - a trailing "%" becomes a synthetic "percent" unit ("7%" ≡ "seven percent").
enum EvalTokenizer {

    struct Token: Equatable {
        let core: String
        let leadingPunctuation: String
        let trailingPunctuation: String
    }

    /// One alignment unit. `normalized` is the canonical comparison form;
    /// `cores` are the original word cores the unit spans (1 except for
    /// collapsed number runs).
    struct Unit: Equatable {
        let cores: [String]
        let normalized: String
        let numberNormalized: Bool
        let leadingPunctuation: String
        let trailingPunctuation: String

        var surface: String { cores.joined(separator: " ") }
        var folded: String { surface.lowercased() }
    }

    // MARK: - Tokenization

    static func tokenize(_ text: String) -> [Token] {
        text.split(whereSeparator: { $0.isWhitespace }).compactMap { chunk -> Token? in
            let scalars = Array(String(chunk).unicodeScalars)
            guard let first = scalars.firstIndex(where: { CharacterSet.alphanumerics.contains($0) }),
                  let last = scalars.lastIndex(where: { CharacterSet.alphanumerics.contains($0) })
            else { return nil } // pure punctuation (freestanding dash etc.) — dropped
            let leading = String(String.UnicodeScalarView(scalars[..<first]))
            let core = String(String.UnicodeScalarView(scalars[first...last]))
            let trailing = String(String.UnicodeScalarView(scalars[(last + 1)...]))
            return Token(core: core, leadingPunctuation: leading, trailingPunctuation: trailing)
        }
    }

    // MARK: - Units (normalization + number-run collapsing)

    static func units(_ text: String) -> [Unit] {
        // Expand tokens: split a trailing "%" into a synthetic "percent" word
        // so "7%" and "seven percent" normalize identically.
        var tokens: [Token] = []
        for token in tokenize(text) {
            if token.trailingPunctuation.contains("%") {
                let remainder = token.trailingPunctuation.replacingOccurrences(of: "%", with: "")
                tokens.append(Token(core: token.core, leadingPunctuation: token.leadingPunctuation, trailingPunctuation: ""))
                tokens.append(Token(core: "percent", leadingPunctuation: "", trailingPunctuation: remainder))
            } else {
                tokens.append(token)
            }
        }

        var units: [Unit] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            let lowered = token.core.lowercased()

            // Try to open a cardinal number run (optionally led by "a"/"an"
            // when a scale word follows: "a thousand" → 1000).
            var runStart = index
            var hasNumberWord = false
            if isArticle(lowered), index + 1 < tokens.count, isScaleWord(tokens[index + 1].core.lowercased()) {
                runStart = index
                index += 1
            }
            var runEnd = index
            while runEnd < tokens.count, isCardinalCore(tokens[runEnd].core.lowercased()) {
                hasNumberWord = true
                runEnd += 1
            }

            if hasNumberWord {
                let span = Array(tokens[runStart..<runEnd])
                let value = parseCardinalRun(span.map { $0.core.lowercased() })
                units.append(Unit(
                    cores: span.map(\.core),
                    normalized: String(value),
                    numberNormalized: true,
                    leadingPunctuation: span.first?.leadingPunctuation ?? "",
                    trailingPunctuation: span.last?.trailingPunctuation ?? ""
                ))
                index = runEnd
                continue
            }

            // Not a cardinal run — single-token unit.
            index = runStart // undo any article lookahead
            let single = tokens[index]
            let core = single.core.lowercased()
            let unit: Unit
            if let ordinal = ordinalValue(core) {
                unit = Unit(
                    cores: [single.core],
                    normalized: "ord\(ordinal)",
                    numberNormalized: true,
                    leadingPunctuation: single.leadingPunctuation,
                    trailingPunctuation: single.trailingPunctuation
                )
            } else if isDigitCore(core) {
                unit = Unit(
                    cores: [single.core],
                    normalized: core.replacingOccurrences(of: ",", with: ""),
                    numberNormalized: true,
                    leadingPunctuation: single.leadingPunctuation,
                    trailingPunctuation: single.trailingPunctuation
                )
            } else {
                unit = Unit(
                    cores: [single.core],
                    normalized: core,
                    numberNormalized: false,
                    leadingPunctuation: single.leadingPunctuation,
                    trailingPunctuation: single.trailingPunctuation
                )
            }
            units.append(unit)
            index += 1
        }
        return units
    }

    /// Canonical comparison sequence for a text — used by assertion matching
    /// and layer attribution.
    static func normalizedSequence(_ text: String) -> [String] {
        units(text).map(\.normalized)
    }

    /// Contiguous-subsequence check over normalized sequences.
    static func containsSubsequence(_ haystack: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<(start + needle.count)]) == needle { return true }
        }
        return false
    }

    // MARK: - Number vocabulary

    private static let unitValues: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tenValues: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    private static let ordinalWords: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5,
        "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10,
        "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14,
        "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18,
        "nineteenth": 19, "twentieth": 20, "thirtieth": 30, "fortieth": 40,
        "fiftieth": 50, "sixtieth": 60, "seventieth": 70, "eightieth": 80,
        "ninetieth": 90, "hundredth": 100, "thousandth": 1000,
    ]

    private static func isArticle(_ word: String) -> Bool {
        word == "a" || word == "an"
    }

    private static func isScaleWord(_ word: String) -> Bool {
        word == "hundred" || word == "thousand"
    }

    private static func isCardinalWord(_ word: String) -> Bool {
        unitValues[word] != nil || tenValues[word] != nil || isScaleWord(word)
    }

    /// A core is cardinal when every hyphen-component is a cardinal word
    /// ("twenty-five") or the whole core is one cardinal word.
    private static func isCardinalCore(_ core: String) -> Bool {
        let parts = core.split(separator: "-").map(String.init)
        guard !parts.isEmpty else { return false }
        return parts.allSatisfy(isCardinalWord)
    }

    private static func isDigitCore(_ core: String) -> Bool {
        let stripped = core.replacingOccurrences(of: ",", with: "")
        return !stripped.isEmpty && stripped.allSatisfy(\.isNumber)
    }

    private static func ordinalValue(_ core: String) -> Int? {
        if let value = ordinalWords[core] { return value }
        // Digit ordinals: 1st, 2nd, 3rd, 21st, …
        for suffix in ["st", "nd", "rd", "th"] where core.hasSuffix(suffix) {
            let digits = String(core.dropLast(2))
            if !digits.isEmpty, digits.allSatisfy(\.isNumber) { return Int(digits) }
        }
        return nil
    }

    /// Standard small-number parser: units accumulate, "hundred" multiplies
    /// the current group, "thousand" banks it. Articles contribute nothing
    /// (the scale word defaults its multiplier to 1).
    private static func parseCardinalRun(_ words: [String]) -> Int {
        var total = 0
        var current = 0
        for word in words {
            let components = word.split(separator: "-").map(String.init)
            for component in components {
                if let value = unitValues[component] ?? tenValues[component] {
                    current += value
                } else if component == "hundred" {
                    current = max(current, 1) * 100
                } else if component == "thousand" {
                    total += max(current, 1) * 1_000
                    current = 0
                }
                // Articles were only admitted before scale words; ignore here.
            }
        }
        return total + current
    }
}
