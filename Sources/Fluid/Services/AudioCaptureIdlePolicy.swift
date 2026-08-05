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

    static func shouldReconcileInputSelection(
        preferredInputUID: String?,
        migrationPending: Bool,
        previousInputUIDs: Set<String>,
        currentInputUIDs: Set<String>
    ) -> Bool {
        guard currentInputUIDs.isEmpty == false else { return false }
        let needsInitialSelection = preferredInputUID?.isEmpty ?? true
        return migrationPending || needsInitialSelection || self.didPreferredInputAvailabilityChange(
            preferredInputUID: preferredInputUID,
            previousInputUIDs: previousInputUIDs,
            currentInputUIDs: currentInputUIDs
        )
    }

    static func shouldRecoverEngineConfigurationChange(
        isRunning: Bool,
        isStarting: Bool
    ) -> Bool {
        isRunning || isStarting
    }
}
