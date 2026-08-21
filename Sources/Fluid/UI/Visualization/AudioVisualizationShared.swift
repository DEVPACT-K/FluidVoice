import Combine
import SwiftUI

protocol AudioVisualizationConfig {
    var noiseThreshold: CGFloat { get }
    var maxAnimationScale: CGFloat { get }
    var animationSpring: Animation { get }
}

final class AudioVisualizationData: ObservableObject {
    @Published var audioLevel: CGFloat = 0.0
    private var cancellable: AnyCancellable?

    init(audioLevelPublisher: AnyPublisher<CGFloat, Never>) {
        // Monterey 4GB: throttle viz to 15fps to save CPU for Whisper
        let isLowRAM = ProcessInfo.processInfo.physicalMemory <= 4 * 1024 * 1024 * 1024
        let publisher: AnyPublisher<CGFloat, Never> = isLowRAM ? audioLevelPublisher.throttle(for: .milliseconds(66), scheduler: RunLoop.main, latest: true).eraseToAnyPublisher() : audioLevelPublisher
        self.cancellable = publisher
            .receive(on: RunLoop.main)
            .sink { [weak self] level in
                self?.audioLevel = level
            }
    }

    deinit {
        cancellable?.cancel()
    }
}
