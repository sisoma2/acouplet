#if !ACOUPLET_PUBLIC_APIS_ONLY
import Darwin
import Foundation

@MainActor
final class MacMediaPlaybackLifetime {
    static let shared = MacMediaPlaybackLifetime()

    private var worker: Process?
    private var hasPaused = false

    func start() {
        guard worker == nil, let executable = Bundle.main.executableURL else { return }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--media-playback-watch", String(getpid())]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            worker = process
        } catch {
            NSLog("Playback could not be paused after an unexpected exit: %@", error.localizedDescription)
        }
    }

    func pauseForTermination() {
        guard !hasPaused else { return }
        hasPaused = true
        MacMediaPlayback.pause()
    }

    func cancelTermination() {
        hasPaused = false
    }

    func finishTermination() {
        pauseForTermination()
        disarm()
    }

    func disarm() {
        if let worker, worker.isRunning { worker.terminate() }
        worker = nil
    }
}

@MainActor
enum MacMediaPlaybackExitWorker {
    private static var watcher: DispatchSourceProcess?
    private static var hasPaused = false

    static func run(parent: pid_t) {
        guard parent > 1 else { return }
        let source = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { parentExited() }
        }
        watcher = source
        source.resume()
        if getppid() != parent { parentExited() }
        dispatchMain()
    }

    private static func parentExited() {
        guard !hasPaused else { return }
        hasPaused = true
        MacMediaPlayback.pause()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(EXIT_SUCCESS) }
    }
}
#endif
