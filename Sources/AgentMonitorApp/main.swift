import AgentMonitorCore
import AppKit

// The pet.
//
//   swift run agent-monitor                     run it
//   swift run agent-monitor --selftest [secs]   run it, dump window state, then exit
//
// `--selftest` exists because the settings that make an overlay behave are invisible
// from the outside and have a history of silently not taking. Printing what the window
// server actually believes is the only honest check.

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: PetController?
    private let selfTestDuration: TimeInterval?
    private let fadePolicy: FadePolicy
    private let startMode: PetController.Mode?

    init(selfTestDuration: TimeInterval?, fadePolicy: FadePolicy, startMode: PetController.Mode?) {
        self.selfTestDuration = selfTestDuration
        self.fadePolicy = fadePolicy
        self.startMode = startMode
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon, no menu bar, never steals focus. Set at runtime so the app
        // behaves correctly straight out of `swift run`, before there is a bundle with
        // an LSUIElement key in it.
        NSApp.setActivationPolicy(.accessory)

        let locator = ClaudeConfigLocator.resolve()
        let controller = PetController(
            registry: SessionRegistry(source: ClaudeSessionSource(locator: locator)),
            fadePolicy: fadePolicy,
            mode: startMode
        )
        controller.start()
        self.controller = controller
        if showsCard {
            controller.pinsCard = true
            Task { @MainActor in
                // Wait for the first snapshot so the card has something to show.
                try? await Task.sleep(for: .seconds(1.5))
                controller.showCard()
            }
        }

        guard let selfTestDuration else { return }
        print("config dir : \(locator.directory.path)")
        Task { @MainActor in
            // Let the window server settle before asking it what it thinks.
            try? await Task.sleep(for: .seconds(showsCard ? 2.5 : 1))
            report(controller)

            // Measure over a window that excludes launch.
            //
            // CPU is read with `getrusage` rather than sampled with `ps`: `ps -o time=`
            // resolves to 10 ms, which at these levels is the same order as the whole
            // signal, and picking the process externally is fragile enough that two
            // consecutive runs produced 0.8% and 0.0% for the same state. A process
            // asking the kernel about itself has neither problem.
            let sample = max(2.0, min(20.0, selfTestDuration - 2))
            let startCPU = processCPUTime()
            let startTicks = controller.tickCount
            let startWall = Date()
            try? await Task.sleep(for: .seconds(sample))
            let elapsed = Date().timeIntervalSince(startWall)
            let usedCPU = processCPUTime() - startCPU
            let delivered = Double(controller.tickCount - startTicks) / elapsed

            print("  \("measured fps".padding(toLength: 24, withPad: " ", startingAt: 0))" +
                  String(format: "%.1f", delivered))
            print("  \("cpu".padding(toLength: 24, withPad: " ", startingAt: 0))" +
                  String(format: "%.3f%% of one core (%.0f ms over %.0f s)",
                         usedCPU / elapsed * 100, usedCPU * 1000, elapsed))
            print("  \("resident memory".padding(toLength: 24, withPad: " ", startingAt: 0))" +
                  String(format: "%.1f MB", residentMemoryMB()))
            print("")

            try? await Task.sleep(for: .seconds(max(0, selfTestDuration - 1 - sample)))
            controller.stop()
            NSApp.terminate(nil)
        }
    }

    private func report(_ controller: PetController) {
        print("")
        print("WINDOW STATE")
        print(String(repeating: "-", count: 62))
        for (key, value) in controller.diagnostics {
            print("  \(key.padding(toLength: 24, withPad: " ", startingAt: 0))\(value)")
        }
        print("")
        print("  \("screens".padding(toLength: 24, withPad: " ", startingAt: 0))\(NSScreen.screens.count)")
        for screen in NSScreen.screens {
            let notch = screen.safeAreaInsets.top > 0 ? "notch \(Int(screen.safeAreaInsets.top))pt" : "no notch"
            let size = "\(Int(screen.frame.width))x\(Int(screen.frame.height))"
            print("  \("".padding(toLength: 24, withPad: " ", startingAt: 0))\(screen.localizedName): \(size), \(notch)")
        }
        print("")
    }
}

/// Total CPU seconds this process has consumed, user plus system, at microsecond
/// resolution.
func processCPUTime() -> Double {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    func seconds(_ time: timeval) -> Double {
        Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000
    }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
}

/// Physical footprint, the number Activity Monitor shows under "Memory".
func residentMemoryMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return 0 }
    return Double(info.phys_footprint) / 1_048_576
}

let arguments = Array(CommandLine.arguments.dropFirst())

func value(after flag: String) -> Double? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return Double(arguments[index + 1])
}

let selfTestDuration: TimeInterval? = arguments.contains("--selftest")
    ? (value(after: "--selftest") ?? 6)
    : nil

// Exposed because it is a real preference (DESIGN.md §2 B.1 makes the fade delay
// user-configurable), and because a ten-minute default is untestable by hand.
let fadePolicy: FadePolicy = {
    if arguments.contains("--no-fade") { return .never }
    if let delay = value(after: "--fade-after") { return FadePolicy(delay: delay) }
    return .default
}()

// Which shell to start in. Normally remembered from last run and toggled with the
// hotkey; the flag exists so either can be exercised directly.
let startMode: PetController.Mode? = {
    guard let index = arguments.firstIndex(of: "--mode"), index + 1 < arguments.count else { return nil }
    return PetController.Mode(rawValue: arguments[index + 1])
}()

// Opens the detail card without hovering — for previewing or screenshotting it.
let showsCard = arguments.contains("--show-card")

setvbuf(stdout, nil, _IOLBF, 0)

let application = NSApplication.shared
let delegate = AppDelegate(selfTestDuration: selfTestDuration, fadePolicy: fadePolicy, startMode: startMode)
application.delegate = delegate
application.run()
