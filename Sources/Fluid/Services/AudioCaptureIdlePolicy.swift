enum AudioCaptureIdlePolicy {
    static func shouldPrewarmCapture(experimentalDirectAudioCaptureEnabled: Bool) -> Bool {
        experimentalDirectAudioCaptureEnabled
    }

    static func didPreferredInputAvailabilityChange(
        preferredInputUID: String?,
        previousInputUIDs: Set<String>,
        currentInputUIDs: Set<String>
    ) -> Bool {
        guard let preferredInputUID, preferredInputUID.isEmpty == false else { return false }
        return previousInputUIDs.contains(preferredInputUID) != currentInputUIDs.contains(preferredInputUID)
    }

    static func shouldRecoverEngineConfigurationChange(
        isRunning: Bool,
        isStarting: Bool
    ) -> Bool {
        isRunning || isStarting
    }
}
