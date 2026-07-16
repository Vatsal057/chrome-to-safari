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
        VStack(alignment: .leading, spacing: 14) {
            Text("Chrome → Safari")
                .font(.system(size: 22, weight: .bold))
            Text("Paste a Chrome Web Store link, or drop an unpacked extension folder anywhere in this window.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                TextField("https://chromewebstore.google.com/detail/…  or  /path/to/extension", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .disabled(runner.running)
                    .onSubmit(convert)
                Button("Choose Folder…", action: chooseFolder)
                    .disabled(runner.running)
            }

            Button(action: convert) {
                Text(runner.running ? "Converting…" : "Convert")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(runner.running || input.trimmingCharacters(in: .whitespaces).isEmpty)

            DisclosureGroup("Options", isExpanded: $showOptions) {
                VStack(alignment: .leading, spacing: 8) {
                    optionField("App name", "from the extension's manifest", $appName)
                    optionField("Bundle ID", "com.converted.<name>", $bundleID)
                    optionField("Team ID", "auto-detected from your keychain", $teamID)
                    HStack(spacing: 8) {
                        optionField("Output folder", "next to the extension", $outDir)
                        Button("…", action: chooseOutDir)
                    }
                    Toggle("Build only — don't install to /Applications", isOn: $buildOnly)
                        .font(.system(size: 12))
                }
                .padding(.top, 6)
                .disabled(runner.running)
            }
            .font(.system(size: 12))

            if !runner.steps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(runner.steps) { step in
                        HStack(spacing: 8) {
                            if step.done {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else if runner.finished && !runner.succeeded {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                            } else {
                                ProgressView().controlSize(.small)
                            }
                            Text(step.label).font(.system(size: 12))
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }

            if runner.finished {
                if runner.succeeded {
                    Label(buildOnly ? "Done. The built app is in the output folder — see the log for the path."
                                    : "Done. Enable it in Safari → Settings → Extensions.",
                          systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 12, weight: .medium))
                } else {
                    Label("Failed — see the log below.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.system(size: 12, weight: .medium))
                        .onAppear { showLog = true }
                }
            }

            DisclosureGroup("Log", isExpanded: $showLog) {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(runner.log.isEmpty ? "No output yet." : runner.log)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(height: 160)
                    .onChange(of: runner.log) { _ in proxy.scrollTo("end") }
                }
            }
            .font(.system(size: 12))

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 480)
        .frame(minHeight: 340)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(dropTargeted ? Color.accentColor : .clear, lineWidth: 3)
                .padding(4)
        )
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

    private func convert() {
        let value = input.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, !runner.running else { return }
        runner.run(input: value,
                   env: ["APP_NAME": appName, "BUNDLE_ID": bundleID,
                         "TEAM_ID": teamID, "OUT_DIR": outDir],
                   buildOnly: buildOnly)
    }

    private func optionField(_ label: String, _ defaultHint: String, _ text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .frame(width: 90, alignment: .trailing)
            TextField("default: \(defaultHint)", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
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
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}
