import AppKit
import OSLog

@MainActor
enum TimerSound {
    private static let logger = Logger(subsystem: "com.marcusmalloc.pomodoroblocker", category: "TimerSound")
    // Keep the sound alive for asynchronous playback and reuse it at each phase boundary.
    private static let buzz = load()

    static func load(from bundle: Bundle = .main) -> NSSound? {
        // NSSound(named:) doesn't discover our CAF file, even though NSSound can decode it.
        guard let url = bundle.url(forResource: "tomato-timer-buzz", withExtension: "caf") else { return nil }
        return NSSound(contentsOf: url, byReference: false)
    }

    static func play() {
        if let buzz {
            buzz.stop()
            if buzz.play() { return }
        }
        logger.error("Timer buzz could not load or play; using the system beep.")
        NSSound.beep()
    }
}
