import SwiftUI

/// The same frosted, rounded surface is used by every Pomodoro panel.
enum PanelLayout {
    static let cornerRadius: CGFloat = 12
    static let inset: CGFloat = 8
    static let timerWidth: CGFloat = 260
    static let blockListWidth: CGFloat = 558
}

extension View {
    func pomodoroSurface() -> some View {
        background(.regularMaterial, in: RoundedRectangle(cornerRadius: PanelLayout.cornerRadius))
    }
}
