// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "agent-monitor",
    platforms: [.macOS(.v14)],
    products: [
        // The state engine. Deliberately free of AppKit so it can run headless as a
        // daemon and drive renderers other than the pet (menu bar, tmux, e-ink, ...).
        // See DESIGN.md §8.
        .library(name: "AgentMonitorCore", targets: ["AgentMonitorCore"]),
        .executable(name: "agent-monitor-cli", targets: ["AgentMonitorCLI"]),
        .executable(name: "agent-monitor", targets: ["AgentMonitorApp"]),
    ],
    targets: [
        .target(name: "AgentMonitorCore"),
        .executableTarget(name: "AgentMonitorCLI", dependencies: ["AgentMonitorCore"]),
        // The only target that touches AppKit.
        .executableTarget(name: "AgentMonitorApp", dependencies: ["AgentMonitorCore"]),
        .testTarget(name: "AgentMonitorCoreTests", dependencies: ["AgentMonitorCore"]),
    ]
)
