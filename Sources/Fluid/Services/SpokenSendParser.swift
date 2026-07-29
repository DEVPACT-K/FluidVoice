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

        if let literalRegex = try? NSRegularExpression(
            pattern: #"(?i)(?<![\p{L}\p{N}_])literal\s+("# + phrasePattern + #")"# + trailingPunctuation
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

        guard let commandRegex = try? NSRegularExpression(
            pattern: #"(?i)(?<![\p{L}\p{N}_])"# + phrasePattern + trailingPunctuation
        ), let match = commandRegex.firstMatch(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        ), match.range.location != NSNotFound,
        let commandRange = Range(match.range, in: text)
        else {
            return SpokenSendParseResult(text: text, shouldSend: false)
        }

        let commandPrefix = String(text[..<commandRange.lowerBound])
        let trimmedPrefix = commandPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedPrefix.isEmpty || Self.endsWithCommandSeparator(trimmedPrefix) else {
            return SpokenSendParseResult(text: text, shouldSend: false)
        }

        let cleaned = Self.polishCommandPrefix(commandPrefix)
        return SpokenSendParseResult(text: cleaned, shouldSend: true)
    }

    private static func endsWithCommandSeparator(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return [".", ",", ";", ":", "?", "!", "…", "-", "–", "—"].contains(last)
    }

    private static func polishCommandPrefix(_ text: String) -> String {
        var polished = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = polished.last, [",", ";", ":", "-", "–", "—"].contains(last) else {
            return polished
        }

        polished.removeLast()
        return polished.trimmingCharacters(in: .whitespacesAndNewlines) + "."
    }
}
