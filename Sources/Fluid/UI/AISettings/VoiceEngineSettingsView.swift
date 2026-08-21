import SwiftUI

struct VoiceEngineSettingsView: View {
    @ObservedObject var viewModel: VoiceEngineSettingsViewModel
    @ObservedObject var settings: SettingsStore
    @Environment(\.colorScheme) var colorScheme
    @State var isShowingNemotronLanguagePicker = false
    let theme: AppTheme

    var voiceEngineTitleText: Color {
        Color(nsColor: .labelColor)
    }

    var voiceEngineSecondaryText: Color {
        self.colorScheme == .light ? Color(nsColor: .labelColor).opacity(0.90) : self.theme.palette.primaryText.opacity(0.82)
    }

    var voiceEngineTertiaryText: Color {
        self.colorScheme == .light ? Color(nsColor: .labelColor).opacity(0.85) : self.theme.palette.secondaryText
    }

    private var isMontereyIntel: Bool { !CPUArchitecture.isAppleSilicon && ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 12 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            self.speechRecognitionCard
            if self.isMontereyIntel {
                Text("Monterey Intel: Whisper Tiny & Apple Speech only — Parakeet/Nemotron require Apple Silicon for fast responses.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
            .onAppear { self.viewModel.onAppear() }
            .onChange(of: self.settings.selectedSpeechModel) { newValue in
                self.viewModel.handleSelectedSpeechModelChange(newValue)
            }
    }
}
