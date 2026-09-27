import AgentMonitorCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The settings window. One instance, reused; opened from the menu bar (⌘,).
@MainActor
final class SettingsWindowController {

    private var window: NSWindow?
    private let controller: PetController
    private let integrations: Integrations

    init(controller: PetController, integrations: Integrations) {
        self.controller = controller
        self.integrations = integrations
    }

    func show() {
        if window == nil {
            let view = SettingsView(controller: controller, integrations: integrations)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            window.title = "Agent Monitor 设置"
            window.contentView = NSHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            self.window = window
        }
        // On the pet's screen, not the "main" one: with several displays `center()`
        // put it on a monitor the user was not looking at, and it looked like nothing
        // had opened at all.
        if let window, let screen = controller.currentScreen, !(window.isVisible && window.screen == screen) {
            let bounds = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: bounds.midX - window.frame.width / 2,
                                          y: bounds.midY - window.frame.height / 2))
        }
        // An accessory app has no Dock icon to bring it forward; activate explicitly or
        // the window opens behind whatever the user was in.
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    let controller: PetController
    let integrations: Integrations

    var body: some View {
        TabView {
            AppearanceTab(controller: controller)
                .tabItem { Label("外观", systemImage: "pawprint") }
            BehaviourTab(controller: controller)
                .tabItem { Label("行为", systemImage: "slider.horizontal.3") }
            AttentionTab()
                .tabItem { Label("提醒", systemImage: "bell") }
            SourcesTab(integrations: integrations)
                .tabItem { Label("数据源", systemImage: "point.3.connected.trianglepath.dotted") }
        }
        .frame(minWidth: 600, minHeight: 560)
        .padding(12)
    }
}

// MARK: - Appearance

private struct AppearanceTab: View {
    let controller: PetController
    @ObservedObject private var prefs = Preferences.shared
    @State private var skinID: String?
    @State private var skins: [(id: String, name: String)] = []
    @State private var editor: SkinEditor?
    @State private var newSkinName = ""
    @State private var showingNewSkin = false

    var body: some View {
        Form {
            Section("角色") {
                Picker("当前角色", selection: Binding(get: { skinID ?? "" }, set: { choose($0.isEmpty ? nil : $0) })) {
                    Text("默认（占位形象）").tag("")
                    ForEach(skins, id: \.id) { skin in Text(skin.name).tag(skin.id) }
                }
                HStack {
                    Button("新建角色…") { showingNewSkin = true }
                    Button("打开角色文件夹") {
                        try? FileManager.default.createDirectory(at: SkinLibrary.directory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(editor?.directory ?? SkinLibrary.directory)
                    }
                    Spacer()
                }
            }

            Section("大小") {
                HStack {
                    Slider(value: $prefs.petSize, in: Preferences.petSizeRange, step: 4) { Text("宠物大小") }
                    Text("\(Int(prefs.petSize)) pt").monospacedDigit().frame(width: 56, alignment: .trailing)
                }
            }

            if let editor {
                SkinPosesSection(editor: editor)
            } else {
                Section("每个状态用的动画") {
                    Text("默认形象是代码画的，不能换图。新建一个角色，或选一个已有的角色，就能给每个状态指定动画。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reload)
        .sheet(isPresented: $showingNewSkin) {
            VStack(alignment: .leading, spacing: 12) {
                Text("新建角色").font(.headline)
                TextField("名字，例如：我的猫", text: $newSkinName).frame(width: 260)
                HStack {
                    Spacer()
                    Button("取消") { showingNewSkin = false }
                    Button("创建") {
                        if let id = try? SkinEditor.create(named: newSkinName.isEmpty ? "新角色" : newSkinName) {
                            newSkinName = ""
                            showingNewSkin = false
                            reload()
                            choose(id)
                        }
                    }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
    }

    private func reload() {
        skins = SkinLibrary.available()
        // A freshly created skin has no poses yet, so the library (which only lists
        // usable skins) does not know it; keep it selectable while it is being filled.
        skinID = controller.currentSkinID
        if let id = skinID, !skins.contains(where: { $0.id == id }), let editor = SkinEditor(id: id) {
            skins.append((id, editor.name))
        }
        editor = skinID.flatMap(makeEditor)
    }

    private func choose(_ id: String?) {
        skinID = id
        controller.setSkin(id: id)
        editor = id.flatMap(makeEditor)
        if let id, !skins.contains(where: { $0.id == id }), let editor { skins.append((id, editor.name)) }
    }

    private func makeEditor(_ id: String) -> SkinEditor? {
        let editor = SkinEditor(id: id)
        editor?.onChange = { [controller] in controller.setSkin(id: id) }
        return editor
    }
}

private struct SkinPosesSection: View {
    @ObservedObject var editor: SkinEditor

    var body: some View {
        Section {
            TextField("角色名字", text: $editor.name)
            ForEach(PetPose.allCases, id: \.self) { pose in
                PoseRow(editor: editor, pose: pose)
            }
        } header: {
            Text("每个状态用的动画")
        } footer: {
            Text("没设置的状态会借用最接近的动画。支持 GIF / APNG / PNG，透明背景效果最好。导入的文件会复制进角色文件夹。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct PoseRow: View {
    @ObservedObject var editor: SkinEditor
    let pose: PetPose

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            preview
                .frame(width: 64, height: 64)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(SkinEditor.title(for: pose)).font(.body.weight(.medium))
                    Text(SkinEditor.states(for: pose)).font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Picker("", selection: Binding(
                        get: { editor.entry(for: pose)?.file ?? "" },
                        set: { editor.setFile($0.isEmpty ? nil : $0, for: pose) }
                    )) {
                        Text("不设置（借用其他动画）").tag("")
                        ForEach(editor.imageFiles, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                    Button("导入…", action: importImage)
                }
                if let entry = editor.entry(for: pose) {
                    HStack(spacing: 6) {
                        Text("速度").font(.caption)
                        Slider(value: Binding(get: { entry.speed }, set: { editor.setSpeed($0, for: pose) }),
                               in: 0.25...2, step: 0.05)
                            .frame(maxWidth: 160)
                        Text(String(format: "%.2f×", entry.speed)).font(.caption).monospacedDigit()
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in try? editor.importImage(from: url, for: pose) }
            }
            return true
        }
    }

    @ViewBuilder private var preview: some View {
        if let url = editor.url(for: pose) {
            AnimatedImage(url: url)
        } else {
            Text("借用").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func importImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = SkinEditor.imageTypes
        panel.allowsMultipleSelection = false
        panel.message = "选一个给「\(SkinEditor.title(for: pose))」用的动画"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? editor.importImage(from: url, for: pose)
    }
}

/// An animated GIF/APNG preview. `NSImageView` animates these natively; SwiftUI's
/// `Image` does not.
private struct AnimatedImage: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.animates = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        if view.toolTip != url.path {
            view.image = NSImage(contentsOf: url)
            view.toolTip = url.path
        }
    }
}

// MARK: - Behaviour

private struct BehaviourTab: View {
    let controller: PetController
    @ObservedObject private var prefs = Preferences.shared
    @State private var launchAtLogin = Preferences.shared.launchAtLogin
    @State private var loginError: String?
    @State private var mode: PetController.Mode = .pet

    var body: some View {
        Form {
            Section("形态") {
                Picker("显示为", selection: Binding(get: { mode }, set: { newValue in
                    if newValue != controller.currentMode { controller.toggleMode() }
                    mode = newValue
                })) {
                    Text("桌宠").tag(PetController.Mode.pet)
                    Text("刘海栏").tag(PetController.Mode.docked)
                }
                .pickerStyle(.segmented)
                Text("快捷键 ⌃⌥⌘P 随时切换").font(.caption).foregroundStyle(.secondary)
            }

            Section("睡着后") {
                Toggle("没有 agent 时慢慢变淡", isOn: $prefs.fadeEnabled)
                if prefs.fadeEnabled {
                    Picker("多久后开始变淡", selection: $prefs.fadeDelayMinutes) {
                        Text("1 分钟").tag(1.0)
                        Text("5 分钟").tag(5.0)
                        Text("10 分钟").tag(10.0)
                        Text("30 分钟").tag(30.0)
                    }
                    HStack {
                        Slider(value: $prefs.fadeOpacity, in: 0.1...1, step: 0.05) { Text("淡到") }
                        Text("\(Int(prefs.fadeOpacity * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Text("只有睡着时会变淡。有 agent 在等你时永远不会变淡。").font(.caption).foregroundStyle(.secondary)
            }

            Section("气泡与卡片") {
                Toggle("在宠物上方显示一句话气泡", isOn: $prefs.bubblesEnabled)
                if prefs.bubblesEnabled {
                    HStack {
                        Slider(value: $prefs.bubbleSeconds, in: 2...20, step: 1) { Text("停留") }
                        Text("\(Int(prefs.bubbleSeconds)) 秒").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                HStack {
                    Slider(value: $prefs.cardDelay, in: 0...1.5, step: 0.05) { Text("悬停多久弹出详情卡片") }
                    Text(String(format: "%.2f 秒", prefs.cardDelay)).monospacedDigit().frame(width: 64, alignment: .trailing)
                }
            }

            Section("启动") {
                Toggle("开机时自动启动", isOn: Binding(get: { launchAtLogin }, set: { value in
                    do {
                        try prefs.setLaunchAtLogin(value)
                        loginError = nil
                    } catch {
                        loginError = "没设置成功：\(error.localizedDescription)（需要从安装好的 app 运行，不能是 swift run）"
                    }
                    launchAtLogin = prefs.launchAtLogin
                }))
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .onAppear { mode = controller.currentMode; launchAtLogin = prefs.launchAtLogin }
    }
}

// MARK: - Attention

private struct AttentionTab: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Form {
            Section {
                Toggle("勿扰模式", isOn: $prefs.quietMode)
                Text("不出声音、不弹气泡。宠物照样跟着状态变化 —— 那是安静的，关掉它等于让监视器说谎。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("声音") {
                Toggle("agent 卡住等你太久时响一声", isOn: $prefs.soundEnabled)
                if prefs.soundEnabled {
                    HStack {
                        Picker("音效", selection: $prefs.soundName) {
                            ForEach(Preferences.sounds, id: \.self) { Text($0).tag($0) }
                        }
                        Button("试听") { prefs.playSound() }
                    }
                }
                Text("只在等你批准 / 回答、或者出错，等了一段时间还没处理时响一次，每个会话每次只响一次。完成一轮不会响。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Sources

private struct SourcesTab: View {
    let integrations: Integrations
    @ObservedObject private var prefs = Preferences.shared
    @State private var refresh = 0

    var body: some View {
        Form {
            Section("Claude Code") {
                LabeledContent("Hook", value: integrations.hookSummary)
                HStack {
                    switch integrations.hookStatus {
                    case .notInstalled: Button("安装 hook…") { integrations.installHooks(); refresh += 1 }
                    case .installed: Button("移除 hook") { integrations.uninstallHooks(); refresh += 1 }
                    case .partial:
                        Button("重新安装 hook…") { integrations.installHooks(); refresh += 1 }
                        Button("移除 hook") { integrations.uninstallHooks(); refresh += 1 }
                    case .disabledByPolicy, .unreadable: EmptyView()
                    }
                }
                Text("可选。装上后多显示：压缩上下文、多个子 agent、当前工具。").font(.caption).foregroundStyle(.secondary)

                switch integrations.statusLineSlot {
                case .empty:
                    LabeledContent("额度显示", value: "未启用")
                    Button("启用额度和上下文显示…") { integrations.enableQuota(); refresh += 1 }
                case .ours:
                    LabeledContent("额度显示", value: "已启用")
                    Button("关闭额度显示") { integrations.disableQuota(); refresh += 1 }
                case .occupied(let owner, let command):
                    LabeledContent("额度显示", value: "statusLine 被 \(owner) 占用")
                    Button("复制接入命令（保留 \(owner)）") { integrations.copyQuotaCommand(for: command) }
                }
            }
            .id(refresh)

            Section("其他 agent") {
                Toggle("读取 Codex 会话", isOn: $prefs.codexEnabled)
                Button("打开自定义 agent 清单文件夹") { integrations.openManifestFolder() }
            }
        }
        .formStyle(.grouped)
    }
}
