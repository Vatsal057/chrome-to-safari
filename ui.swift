// ui.swift — native macOS front-end for chrome-to-safari.sh
// Compiled on first run by `./chrome-to-safari.sh --ui` (swiftc, no Xcode project).
// The shell script stays the single source of truth; this window just runs it
// and shows its output.

import SwiftUI
import UniformTypeIdentifiers

struct Step: Identifiable {
    let id = UUID()
    let label: String
    var done = false
}

final class Runner: ObservableObject {
    static let scriptPath = ProcessInfo.processInfo.environment["C2S_SCRIPT"]
        ?? FileManager.default.currentDirectoryPath + "/chrome-to-safari.sh"

    @Published var steps: [Step] = []
    @Published var log = ""
    @Published var running = false
    @Published var finished = false
    @Published var succeeded = false

    private var process: Process?

    func run(input: String, env: [String: String] = [:], buildOnly: Bool = false) {
        steps = []
        log = ""
        finished = false
        succeeded = false
        running = true

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = buildOnly ? [Self.scriptPath, input, "--build-only"]
                                   : [Self.scriptPath, input]
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in env where !value.trimmingCharacters(in: .whitespaces).isEmpty {
            environment[key] = value
        }
        proc.environment = environment
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.append(text) }
        }
        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                guard let self else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                for i in self.steps.indices { self.steps[i].done = true }
                self.running = false
                self.finished = true
                self.succeeded = p.terminationStatus == 0
            }
        }

        do {
            try proc.run()
            process = proc
        } catch {
            append("ERROR: could not run \(Self.scriptPath): \(error.localizedDescription)\n")
            running = false
            finished = true
        }
    }

    private func append(_ text: String) {
        log += text
        for line in text.split(separator: "\n") where line.hasPrefix("==> ") {
            for i in steps.indices { steps[i].done = true }
            steps.append(Step(label: String(line.dropFirst(4))))
        }
    }
}

struct ContentView: View {
    @StateObject private var runner = Runner()
    @State private var input = ""
    @State private var dropTargeted = false
    @State private var showLog = false
    @State private var showOptions = false
    @State private var appName = ""
    @State private var bundleID = ""
    @State private var teamID = ""
    @State private var outDir = ""
    @State private var buildOnly = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            dropZone

            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .foregroundStyle(.secondary)
                    TextField("Store link or folder path", text: $input)
                        .textFieldStyle(.roundedBorder)
                        .disabled(runner.running)
                        .onSubmit(convert)
                }

                Button(action: convert) {
                    HStack(spacing: 8) {
                        if runner.running {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(runner.running ? "Converting…" : "Convert")
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(runner.running || input.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            DisclosureGroup("Options", isExpanded: $showOptions) {
                Text("Leave any field blank to use its default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)

                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 8) {
                    optionRow("App Name", "from the extension's manifest", $appName)
                    optionRow("Bundle ID", "com.converted.<name>", $bundleID)
                    optionRow("Team ID", "auto-detected from your keychain", $teamID)
                    GridRow {
                        Text("Output Folder")
                            .gridColumnAlignment(.trailing)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            TextField("next to the extension", text: $outDir)
                                .textFieldStyle(.roundedBorder)
                            Button("…", action: chooseOutDir)
                        }
                    }
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        Toggle("Build only, don't install to /Applications", isOn: $buildOnly)
                    }
                }
                .font(.callout)
                .disabled(runner.running)
            }
            .font(.callout)

            if !runner.steps.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(runner.steps) { step in
                        HStack(spacing: 8) {
                            if step.done {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else if runner.finished && !runner.succeeded {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                            } else {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(step.label)
                                .font(.callout)
                                .foregroundStyle(step.done ? .secondary : .primary)
                        }
                        .transition(.opacity)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color(nsColor: .separatorColor))
                )
            }

            if runner.finished {
                resultBanner
            }

            DisclosureGroup("Log", isExpanded: $showLog) {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(runner.log.isEmpty ? "No output yet." : runner.log)
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(8)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(height: 170)
                    .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
                    .onChange(of: runner.log) { _ in proxy.scrollTo("end") }
                    .padding(.top, 8)
                }
            }
            .font(.callout)
        }
        .padding(20)
        .frame(width: 480)
        .animation(.easeOut(duration: 0.2), value: runner.steps.count)
        .animation(.easeOut(duration: 0.2), value: runner.finished)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { input = url.path } }
            }
            return true
        }
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary)
            Text("Drop an unpacked extension folder here, or click to choose one")
                .font(.callout.weight(.medium))
            Text("or paste a Chrome Web Store link below")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(dropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(dropTargeted ? Color.accentColor : Color(nsColor: .separatorColor),
                              style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1, dash: [5, 4]))
        )
        .contentShape(Rectangle())
        .onTapGesture { if !runner.running { chooseFolder() } }
        .animation(.easeOut(duration: 0.15), value: dropTargeted)
    }

    private var resultBanner: some View {
        let ok = runner.succeeded
        return HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? Color.green : Color.red)
            Text(ok ? (buildOnly ? "Done. The built app is in the output folder — see the log for the path."
                                 : "Done. Enable it in Safari → Settings → Extensions.")
                    : "Failed. See the log below for details.")
                .font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((ok ? Color.green : Color.red).opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 8))
        .onAppear { if !ok { showLog = true } }
    }

    private func convert() {
        let value = input.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, !runner.running else { return }
        runner.run(input: value,
                   env: ["APP_NAME": appName, "BUNDLE_ID": bundleID,
                         "TEAM_ID": teamID, "OUT_DIR": outDir],
                   buildOnly: buildOnly)
    }

    private func optionRow(_ label: String, _ defaultHint: String, _ text: Binding<String>) -> some View {
        GridRow {
            Text(label)
                .gridColumnAlignment(.trailing)
                .foregroundStyle(.secondary)
            TextField(defaultHint, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func chooseOutDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Pick where the build output should go"
        if panel.runModal() == .OK, let url = panel.url {
            outDir = url.path
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Pick the unpacked extension folder (the one containing manifest.json)"
        if panel.runModal() == .OK, let url = panel.url {
            input = url.path
        }
    }
}

@main
struct ChromeToSafariApp: App {
    var body: some Scene {
        WindowGroup("Chrome to Safari") {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}
