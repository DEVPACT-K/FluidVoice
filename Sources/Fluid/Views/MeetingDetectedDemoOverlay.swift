import AppKit
import QuartzCore
import SwiftUI

enum MeetingDetectedDemoCopy {
    static let title = "Meeting detected"
    static let detail = "Zoom"
    static let action = "Take Notes"
}

@MainActor
final class MeetingDetectedDemoOverlayController {
    static let shared = MeetingDetectedDemoOverlayController()

    private static let panelSize = NSSize(width: 408, height: 64)
    private static let screenInset: CGFloat = 18
    private static let horizontalTravel: CGFloat = 32
    private static let presentationDuration: TimeInterval = 0.26
    private static let dismissalDuration: TimeInterval = 0.18
    private static let reducedMotionDuration: TimeInterval = 0.14
    private static let displayDurationNanoseconds: UInt64 = 10_000_000_000

    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    private var restingFrame: NSRect?
    private var presentationGeneration: UInt64 = 0

    private init() {}

    func show() {
        self.presentationGeneration &+= 1
        self.dismissTask?.cancel()

        let content = MeetingDetectedDemoOverlayView(
            onStartNotetaker: { [weak self] in
                DebugLogger.shared.info(
                    "Start Notetaker demo action selected",
                    source: "MeetingDetectedDemo"
                )
                self?.hide()
                NSApp.activate(ignoringOtherApps: true)
            },
            onDismiss: { [weak self] in
                self?.hide()
            }
        )

        let panel = self.panel ?? self.makePanel()
        panel.contentView = self.makeHostingView(rootView: content)
        guard let restingFrame = self.restingFrameForCurrentScreen() else { return }
        self.restingFrame = restingFrame

        if panel.isVisible {
            let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                ? Self.reducedMotionDuration
                : Self.presentationDuration
            self.animate(panel, to: restingFrame, alphaValue: 1, duration: duration)
        } else {
            self.present(panel, at: restingFrame)
        }

        self.dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.displayDurationNanoseconds)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        self.presentationGeneration &+= 1
        let hideGeneration = self.presentationGeneration
        self.dismissTask?.cancel()
        self.dismissTask = nil

        guard let panel, panel.isVisible else { return }
        let restingFrame = self.restingFrame ?? panel.frame
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let dismissalFrame = reduceMotion ? restingFrame : restingFrame.offsetBy(dx: Self.horizontalTravel, dy: 0)
        let duration = reduceMotion ? Self.reducedMotionDuration : Self.dismissalDuration

        self.animate(panel, to: dismissalFrame, alphaValue: 0, duration: duration) { [weak self] in
            guard let self, self.presentationGeneration == hideGeneration else { return }
            panel.orderOut(nil)
            panel.alphaValue = 1
            panel.setFrame(restingFrame, display: false)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        self.panel = panel
        return panel
    }

    private func makeHostingView(rootView: MeetingDetectedDemoOverlayView) -> NSHostingView<MeetingDetectedDemoOverlayView> {
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: Self.panelSize)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        return hostingView
    }

    private func restingFrameForCurrentScreen() -> NSRect? {
        guard let screen = OverlayScreenResolver.screenForCurrentPointer() ?? NSScreen.main else { return nil }

        let visibleFrame = screen.visibleFrame
        return NSRect(
            x: visibleFrame.maxX - Self.panelSize.width - Self.screenInset,
            y: visibleFrame.maxY - Self.panelSize.height - Self.screenInset,
            width: Self.panelSize.width,
            height: Self.panelSize.height
        )
    }

    private func present(_ panel: NSPanel, at restingFrame: NSRect) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let presentationFrame = reduceMotion ? restingFrame : restingFrame.offsetBy(dx: Self.horizontalTravel, dy: 0)
        let duration = reduceMotion ? Self.reducedMotionDuration : Self.presentationDuration

        panel.setFrame(presentationFrame, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        self.animate(panel, to: restingFrame, alphaValue: 1, duration: duration)
    }

    private func animate(
        _ panel: NSPanel,
        to frame: NSRect,
        alphaValue: CGFloat,
        duration: TimeInterval,
        completion: (() -> Void)? = nil
    ) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = alphaValue
        } completionHandler: {
            completion?()
        }
    }
}

private struct MeetingDetectedDemoOverlayView: View {
    let onStartNotetaker: () -> Void
    let onDismiss: () -> Void

    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        HStack(spacing: 10) {
            self.appIcon

            VStack(alignment: .leading, spacing: 2) {
                Text(MeetingDetectedDemoCopy.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Circle()
                        .fill(self.settings.accentColor)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)

                    Text(MeetingDetectedDemoCopy.detail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            Button(action: self.onStartNotetaker) {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.system(size: 12, weight: .semibold))
                        .accessibilityHidden(true)

                    Text(MeetingDetectedDemoCopy.action)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.horizontal, 11)
                .frame(height: 34)
            }
            .buttonStyle(MeetingDetectedDemoActionButtonStyle())

            Button(action: self.onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 20, height: 20)
                    .contentShape(Circle())
            }
            .buttonStyle(MeetingDetectedDemoDismissButtonStyle())
            .accessibilityLabel("Dismiss")
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .frame(width: 408, height: 64)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.primary.opacity(0.12), lineWidth: 0.75)
        }
    }

    private var appIcon: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .scaledToFit()
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)
    }
}

private struct MeetingDetectedDemoActionButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.72 : 0.92),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .scaleEffect(configuration.isPressed && !self.reduceMotion ? 0.97 : 1)
            .animation(self.reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct MeetingDetectedDemoDismissButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.secondary)
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.12 : 0),
                in: Circle()
            )
            .scaleEffect(configuration.isPressed && !self.reduceMotion ? 0.95 : 1)
            .animation(self.reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
