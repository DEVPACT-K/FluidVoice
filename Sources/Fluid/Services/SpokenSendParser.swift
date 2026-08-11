import Foundation

struct SpokenSendParseResult: Equatable {
    let text: String
    let shouldSend: Bool
}

enum SpokenSendParser {
    static let immediateStopSettleDuration: TimeInterval = 1.5
    static let immediateStopSettleNanoseconds: UInt64 = 1_500_000_000
    static let immediateStopRequiredSilenceDuration: TimeInterval = 0.35
    static let immediateStopVoiceActivityGraceDuration: TimeInterval = 0.35
    static let immediateStopVoiceActivityLevelThreshold: CGFloat = 0.12
    private static let regexCache: NSCache<NSString, NSRegularExpression> = {
        let cache = NSCache<NSString, NSRegularExpression>()
        cache.countLimit = 12
        return cache
    }()

    static func shouldStopImmediately(
        _ text: String,
        phrase: String,
        spokenSendEnabled: Bool,
        sendImmediatelyEnabled: Bool
    ) -> Bool {
        sendImmediatelyEnabled &&
            self.parse(text, phrase: phrase, enabled: spokenSendEnabled).shouldSend
    }

    static func canCompleteImmediateStop(
        _ text: String,
        phrase: String,
        spokenSendEnabled: Bool,
        sendImmediatelyEnabled: Bool,
        receivedFreshTranscript: Bool,
        quietDuration: TimeInterval
    ) -> Bool {
        receivedFreshTranscript &&
            quietDuration >= self.immediateStopRequiredSilenceDuration &&
            self.shouldStopImmediately(
                text,
                phrase: phrase,
                spokenSendEnabled: spokenSendEnabled,
                sendImmediatelyEnabled: sendImmediatelyEnabled
            )
    }

    static func shouldCancelCountdownForVoiceActivity(
        countdownStartedAt: TimeInterval,
        voiceActivityAt: TimeInterval
    ) -> Bool {
        voiceActivityAt - countdownStartedAt >= self.immediateStopVoiceActivityGraceDuration
    }

    static func isMeaningfulVoiceActivity(_ level: CGFloat) -> Bool {
        level >= self.immediateStopVoiceActivityLevelThreshold
    }

    static func parse(_ text: String, phrase: String, enabled: Bool) -> SpokenSendParseResult {
        guard enabled else {
            return SpokenSendParseResult(text: text, shouldSend: false)
        }

        let phraseWords = phrase
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !phraseWords.isEmpty else {
            return SpokenSendParseResult(text: text, shouldSend: false)
        }

        let phrasePattern = phraseWords
            .map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: #"\s+"#)
        let trailingPunctuation = #"[\s\p{P}]*$"#

        if let literalRegex = Self.regex(
            #"(?i)(?<![\p{L}\p{N}_])literal\s+("# + phrasePattern + #")"# + trailingPunctuation
        ), let match = literalRegex.firstMatch(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        ), match.range.location != NSNotFound,
        let wholeRange = Range(match.range, in: text),
        let phraseRange = Range(match.range(at: 1), in: text) {
            var output = text
            output.replaceSubrange(wholeRange, with: text[phraseRange])
            return SpokenSendParseResult(text: output, shouldSend: false)
        }

        guard let commandRegex = Self.regex(
            #"(?i)(?<![\p{L}\p{N}_])("# +
                phrasePattern +
                #")(?:[\s\p{P}]+"# +
                phrasePattern +
                #")*"# +
                trailingPunctuation
        ), let match = commandRegex.firstMatch(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        ), match.range.location != NSNotFound,
        let commandRange = Range(match.range, in: text),
        let firstPhraseRange = Range(match.range(at: 1), in: text)
        else {
            return SpokenSendParseResult(
                text: Self.strippingLiteralMarkers(in: text, phrasePattern: phrasePattern),
                shouldSend: false
            )
        }

        var commandPrefix = String(text[..<commandRange.lowerBound])
        let commandSuffix = String(text[firstPhraseRange.upperBound..<commandRange.upperBound])
        Self.removePairedOpeningDelimiters(
            from: &commandPrefix,
            closedBy: commandSuffix
        )
        if let literalPrefixRegex = Self.regex(
            #"(?i)(?<![\p{L}\p{N}_])literal\s*$"#
        ), let literalMatch = literalPrefixRegex.firstMatch(
            in: commandPrefix,
            range: NSRange(commandPrefix.startIndex..., in: commandPrefix)
        ), let literalRange = Range(literalMatch.range, in: commandPrefix) {
            commandPrefix.replaceSubrange(literalRange, with: text[firstPhraseRange])
        }
        commandPrefix = Self.strippingLiteralMarkers(
            in: commandPrefix,
            phrasePattern: phrasePattern
        )

        let cleaned = Self.polishCommandPrefix(commandPrefix)
        return SpokenSendParseResult(text: cleaned, shouldSend: true)
    }

    private static func strippingLiteralMarkers(in text: String, phrasePattern: String) -> String {
        guard let regex = Self.regex(
            #"(?i)(?<![\p{L}\p{N}_])literal\s+("# + phrasePattern + #")"#
        ) else {
            return text
        }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: "$1"
        )
    }

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        let key = pattern as NSString
        if let cached = self.regexCache.object(forKey: key) {
            return cached
        }
        guard let compiled = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        self.regexCache.setObject(compiled, forKey: key)
        return compiled
    }

    private static func removePairedOpeningDelimiters(
        from text: inout String,
        closedBy commandSuffix: String
    ) {
        let delimiterPairs: [Character: Character] = [
            "(": ")", "[": "]", "{": "}",
            "\"": "\"", "'": "'", "“": "”", "‘": "’", "«": "»",
        ]
        while true {
            var candidate = text
            while candidate.last?.isWhitespace == true {
                candidate.removeLast()
            }
            guard let opener = candidate.last,
                  let closer = delimiterPairs[opener],
                  commandSuffix.contains(closer)
            else {
                return
            }
            candidate.removeLast()
            text = candidate
            while text.last?.isWhitespace == true {
                text.removeLast()
            }
        }
    }

    private static func polishCommandPrefix(_ text: String) -> String {
        var polished = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = polished.last, [",", ";", ":", "-", "–", "—"].contains(last) {
            polished.removeLast()
            while polished.last?.isWhitespace == true {
                polished.removeLast()
            }
        }

        guard let last = polished.last else {
            return polished
        }
        if [".", "?", "!", "…"].contains(last) {
            return polished
        }
        return polished + "."
    }
}
