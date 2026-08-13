import CoreAudio

enum AudioCaptureIdlePolicy {
    struct SilentPCMRecoveryWatchdog {
        static let requiredSilentWindows = 3
        static let maximumSilentRMS: Float = 0.00_001
        static let maximumSilentPeak: Float = 0.00_005

        private var hasSeenSignal = false
        private var consecutiveSilentWindows = 0
        private var hasRequestedRecovery = false

        mutating func shouldRecover(
            isBuiltInInput: Bool,
            isDirectCapture: Bool,
            rms: Float,
            peak: Float
        ) -> Bool {
            guard isBuiltInInput, isDirectCapture, self.hasRequestedRecovery == false else { return false }
            let isEffectivelySilent = rms <= Self.maximumSilentRMS && peak <= Self.maximumSilentPeak
            if isEffectivelySilent == false {
                self.hasSeenSignal = true
                self.consecutiveSilentWindows = 0
                return false
            }
            guard self.hasSeenSignal else { return false }
            self.consecutiveSilentWindows += 1
            guard self.consecutiveSilentWindows >= Self.requiredSilentWindows else { return false }
            self.hasRequestedRecovery = true
            return true
        }
    }

    struct BluetoothInputStabilization {
        static let maximumDuration: TimeInterval = 5

        private(set) var inputUID: String?
        private(set) var startedAt: TimeInterval?

        mutating func shouldRetry(
            inputUID: String,
            isBluetoothInput: Bool,
            now: TimeInterval
        ) -> Bool {
            guard isBluetoothInput || self.inputUID == inputUID else { return false }
            if self.inputUID != inputUID || self.startedAt == nil {
                self.inputUID = inputUID
                self.startedAt = now
            }
            return self.elapsed(at: now) < Self.maximumDuration
        }

        func elapsed(at now: TimeInterval) -> TimeInterval {
            guard let startedAt else { return 0 }
            return max(now - startedAt, 0)
        }
    }

    static func shouldPrewarmCapture(experimentalDirectAudioCaptureEnabled: Bool) -> Bool {
        experimentalDirectAudioCaptureEnabled
    }

    static func didResolvedPriorityInputChange(
        priorityInputUIDs: [String],
        previousInputUIDs: Set<String>,
        currentInputUIDs: Set<String>
    ) -> Bool {
        let previousChoice = priorityInputUIDs.first(where: previousInputUIDs.contains)
        let currentChoice = priorityInputUIDs.first(where: currentInputUIDs.contains)
        return previousChoice != currentChoice
    }

    static func didResolvedPriorityInputIdentityChange(
        priorityInputUIDs: [String],
        previousInputDeviceIDsByUID: [String: AudioObjectID],
        currentInputDeviceIDsByUID: [String: AudioObjectID]
    ) -> Bool {
        let previousChoice = priorityInputUIDs.first { previousInputDeviceIDsByUID[$0] != nil }
        let currentChoice = priorityInputUIDs.first { currentInputDeviceIDsByUID[$0] != nil }
        guard previousChoice == currentChoice else { return true }
        guard let currentChoice else { return false }
        return previousInputDeviceIDsByUID[currentChoice] != currentInputDeviceIDsByUID[currentChoice]
    }

    static func shouldReconcileInputSelection(
        priorityInputUIDs: [String],
        migrationPending: Bool,
        previousInputUIDs: Set<String>,
        currentInputUIDs: Set<String>
    ) -> Bool {
        if currentInputUIDs.isEmpty {
            return previousInputUIDs.isEmpty == false && self.didResolvedPriorityInputChange(
                priorityInputUIDs: priorityInputUIDs,
                previousInputUIDs: previousInputUIDs,
                currentInputUIDs: currentInputUIDs
            )
        }
        return migrationPending || priorityInputUIDs.isEmpty || self.didResolvedPriorityInputChange(
            priorityInputUIDs: priorityInputUIDs,
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

    static func shouldDeferRouteRecoveryToBluetoothStart(
        directCaptureEnabled: Bool,
        isStarting: Bool,
        isRunning: Bool,
        attemptedInputIsBluetooth: Bool
    ) -> Bool {
        directCaptureEnabled && isStarting && isRunning == false && attemptedInputIsBluetooth
    }
}
