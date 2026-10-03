import AppKit
import Observation

/// Counts down alternating focus and break phases. Durations are always valid whole minutes;
/// temporary text edits belong to the clock's editor rather than the saved timer state.
@MainActor
@Observable
final class PomodoroTimer {
    static let minuteRange = 1...999

    private(set) var focusMinutes: Int
    private(set) var breakMinutes: Int
    private(set) var onBreak = false
    /// Seconds left once a phase has started, or nil before the first start and after reset.
    private(set) var remaining: TimeInterval?
    private var phaseLength: TimeInterval
    private var endDate: Date? {
        didSet { blocker?.isActive = endDate != nil && !onBreak }
    }

    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private let store: UserDefaults
    @ObservationIgnored private let currentDate: () -> Date
    @ObservationIgnored private let automaticallyTicks: Bool
    @ObservationIgnored private let onPhaseEnd: () -> Void
    private let blocker: Blocker?

    let blockList: BlockList

    var isRunning: Bool { endDate != nil }
    var isIdle: Bool { remaining == nil }
    var currentSeconds: TimeInterval { remaining ?? length(onBreak: onBreak) }
    var fractionRemaining: Double { min(max(currentSeconds / phaseLength, 0), 1) }
    var domainProblem: String? { blocker?.domains.problem }

    /// Disabling blocking avoids constructing the blocker at all, so previews and tests cannot quit
    /// apps or request hosts-file access. An isolated defaults store also keeps their edits separate.
    /// Those timers are silent unless an explicit phase-end callback is supplied.
    init(
        defaults: UserDefaults = .standard,
        blockList: BlockList? = nil,
        blockingEnabled: Bool = true,
        automaticallyTicks: Bool = true,
        onPhaseEnd: (() -> Void)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        store = defaults
        currentDate = now
        self.automaticallyTicks = automaticallyTicks
        self.onPhaseEnd = onPhaseEnd ?? (blockingEnabled ? TimerSound.play : {})
        let focus = Self.savedMinutes(in: defaults, key: "focusMinutes", fallback: 25)
        let rest = Self.savedMinutes(in: defaults, key: "breakMinutes", fallback: 5)
        focusMinutes = focus
        breakMinutes = rest
        phaseLength = TimeInterval(focus * 60)
        // Upgrade the previous text preferences and repair empty or invalid saved values once.
        defaults.set(focus, forKey: "focusMinutes")
        defaults.set(rest, forKey: "breakMinutes")
        let list = blockList ?? BlockList(defaults: defaults)
        self.blockList = list
        blocker = blockingEnabled ? Blocker(list: list) : nil
    }

    func duration(onBreak: Bool) -> Int { onBreak ? breakMinutes : focusMinutes }

    /// Editing a stopped current phase fills it to the new length. The next phase remains editable
    /// during a countdown, but a running phase keeps its original deadline and progress.
    func setDuration(_ minutes: Int, onBreak isBreak: Bool) {
        guard !isRunning || isBreak != onBreak else { return }
        let value = Self.clamped(minutes)
        if isBreak {
            breakMinutes = value
            store.set(value, forKey: "breakMinutes")
        } else {
            focusMinutes = value
            store.set(value, forKey: "focusMinutes")
        }
        if isBreak == onBreak {
            phaseLength = length(onBreak: isBreak)
            if remaining != nil { remaining = phaseLength }
        }
    }

    func adjustDuration(_ delta: Int, onBreak: Bool) {
        let (value, overflow) = duration(onBreak: onBreak).addingReportingOverflow(delta)
        setDuration(overflow ? (delta > 0 ? Self.minuteRange.upperBound : Self.minuteRange.lowerBound) : value,
                    onBreak: onBreak)
    }

    /// Selects a fresh phase at its saved duration, preserving whether the clock is running,
    /// paused or idle. Assigning the new deadline also updates focus blocking immediately.
    func selectPhase(onBreak isBreak: Bool) {
        guard isBreak != onBreak else { return }
        let wasRunning = isRunning
        let wasIdle = isIdle
        stopTicker()
        endDate = nil
        onBreak = isBreak
        phaseLength = length(onBreak: isBreak)
        remaining = wasIdle ? nil : phaseLength
        if wasRunning {
            endDate = currentDate() + phaseLength
            startTicker()
        }
    }

    /// Starts or resumes the countdown, or pauses it at the actual current time.
    func toggle() {
        let date = currentDate()
        if isRunning {
            advance(to: date)
            endDate = nil
            stopTicker()
        } else {
            if remaining == nil {
                phaseLength = length(onBreak: onBreak)
                remaining = phaseLength
            }
            endDate = date + currentSeconds
            startTicker()
        }
    }

    func reset() {
        stopTicker()
        endDate = nil
        remaining = nil
        onBreak = false
        phaseLength = length(onBreak: false)
    }

    /// Refreshes from the clock rather than subtracting ticks, so sleep and slow run loops do not
    /// stretch a phase. Tests can use an injected clock without scheduling a real timer.
    func refresh() { advance(to: currentDate()) }

    private func advance(to date: Date) {
        guard var deadline = endDate else { return }
        var changedPhase = false
        while deadline <= date {
            onBreak.toggle()
            phaseLength = length(onBreak: onBreak)
            deadline += phaseLength
            changedPhase = true
        }
        remaining = deadline.timeIntervalSince(date)
        if changedPhase {
            endDate = deadline
            onPhaseEnd()
        }
    }

    private func startTicker() {
        guard automaticallyTicks else { return }
        stopTicker()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func length(onBreak: Bool) -> TimeInterval { TimeInterval(duration(onBreak: onBreak) * 60) }

    private static func clamped(_ minutes: Int) -> Int {
        min(max(minutes, minuteRange.lowerBound), minuteRange.upperBound)
    }

    private static func savedMinutes(in defaults: UserDefaults, key: String, fallback: Int) -> Int {
        if let text = defaults.object(forKey: key) as? String {
            return Int(text.trimmingCharacters(in: .whitespacesAndNewlines)).map(clamped) ?? fallback
        }
        if let number = defaults.object(forKey: key) as? NSNumber { return clamped(number.intValue) }
        return fallback
    }
}
