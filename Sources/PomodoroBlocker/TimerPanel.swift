import AppKit
import SwiftUI

/// A single phase clock. Durations are edited in place; app commands live in the status-item menu.
struct TimerPanel: View {
    @Bindable var timer: PomodoroTimer

    var body: some View {
        VStack(spacing: 2) {
            ClockControl(
                seconds: timer.currentSeconds,
                minutes: timer.duration(onBreak: timer.onBreak),
                isRunning: timer.isRunning,
                onBreak: timer.onBreak,
                toggle: { timer.toggle() },
                reset: { timer.reset() },
                setMinutes: { timer.setDuration($0, onBreak: timer.onBreak) },
                adjustMinutes: { timer.adjustDuration($0, onBreak: timer.onBreak) }
            )
            .frame(height: 70)

            phaseCaption
                .font(.system(size: 12))
                .padding(.bottom, 6)

            if let problem = timer.domainProblem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
        }
        .padding(PanelLayout.inset)
        .frame(width: PanelLayout.timerWidth)
        .fixedSize(horizontal: false, vertical: true)
        .pomodoroSurface()
    }

    private var phaseCaption: some View {
        HStack(spacing: 4) {
            Text(timer.onBreak ? "break" : "focus")
                .foregroundStyle(Color.accentColor)
            Text("·").foregroundStyle(.secondary)
            Button("\(timer.duration(onBreak: !timer.onBreak)) \(alternatePhase)") {
                selectAlternatePhase()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Switch to \(alternatePhase)")
            .help("Switch to \(alternatePhase)")
        }
    }

    private var alternatePhase: String { timer.onBreak ? "focus" : "break" }

    private func selectAlternatePhase() {
        // Finish a current clock edit before changing phase so its draft saves to that phase.
        if let content = NSApp.keyWindow?.contentView {
            ClockView.deactivate(in: content)
        }
        timer.selectPhase(onBreak: !timer.onBreak)
        focusClock()
    }

    private func focusClock() {
        guard let window = NSApp.keyWindow else { return }
        // Restore keyboard shortcuts after SwiftUI finishes handling the caption button.
        Task { @MainActor [weak window] in
            await Task.yield()
            guard let window, window.isVisible, window.isKeyWindow,
                  let content = window.contentView else { return }
            ClockView.focus(in: content)
        }
    }
}
