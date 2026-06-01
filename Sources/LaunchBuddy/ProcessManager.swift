import Foundation
import SwiftUI
import Darwin

@Observable
final class ProcessManager {
    static let shared = ProcessManager()

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var outputPipe: Pipe?
    @ObservationIgnored private var processGroupID: pid_t = 0
    var running: Bool = false
    var launchError: String?
    var outputLines: [String] = []

    private var outputQueue = DispatchQueue(label: "launchbuddy.output")

    private init() {}

    func start(scriptPath: String) {
        Task { @MainActor in
            launchError = nil
            outputLines = []

            guard !scriptPath.isEmpty else {
                launchError = "No script path configured"
                return
            }

            guard FileManager.default.fileExists(atPath: scriptPath) else {
                launchError = "File not found: \(scriptPath)"
                return
            }

            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: scriptPath)
                let perms = (attrs[.posixPermissions] as? UInt) ?? 0
                if perms & 0o111 == 0 {
                    try FileManager.default.setAttributes([.posixPermissions: perms | 0o755], ofItemAtPath: scriptPath)
                }
            } catch {
                launchError = "Permission error: \(error.localizedDescription)"
                return
            }

            let proc = Process()
            let pipe = Pipe()

            let ext = URL(fileURLWithPath: scriptPath).pathExtension.lowercased()
            if ["sh", "bash", "zsh", "csh", "ksh", "fish"].contains(ext) {
                proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
                proc.arguments = [scriptPath]
            } else {
                proc.executableURL = URL(fileURLWithPath: scriptPath)
            }

            proc.standardOutput = pipe
            proc.standardError = pipe

            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                if let data = try? handle.read(upToCount: 65536),
                   let text = String(data: data, encoding: .utf8) {
                    self?.outputQueue.async {
                        var lines = self?.outputLines ?? []
                        lines.append(contentsOf: text.components(separatedBy: .newlines))
                        if lines.count > 1000 {
                            lines = Array(lines.suffix(1000))
                        }
                        self?.outputLines = lines
                    }
                }
            }

            proc.terminationHandler = { [weak self] _ in
                pipe.fileHandleForReading.readabilityHandler = nil
                Task { @MainActor [weak self] in
                    self?.running = false
                    self?.process = nil
                    self?.outputPipe = nil
                    self?.processGroupID = 0
                }
            }

            do {
                try proc.run()
                setpgid(proc.processIdentifier, 0)
                self.process = proc
                self.outputPipe = pipe
                self.processGroupID = proc.processIdentifier
                self.running = true
            } catch {
                let nsError = error as NSError
                self.launchError = "Failed to launch: \(nsError.localizedDescription) (code: \(nsError.code))"
            }
        }
    }

    func stop() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil

        let pgid = processGroupID
        let proc = self.process

        self.process = nil
        self.outputPipe = nil
        self.processGroupID = 0
        self.running = false

        guard let proc = proc else { return }

        Task.detached {
            if pgid > 0 {
                kill(-pgid, SIGTERM)
            } else {
                proc.terminate()
            }

            try? await Task.sleep(for: .seconds(2))

            if proc.isRunning {
                if pgid > 0 {
                    kill(-pgid, SIGKILL)
                } else {
                    kill(proc.processIdentifier, SIGKILL)
                }
            }
        }
    }

    func killSync() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil

        let pgid = processGroupID
        let proc = self.process

        self.process = nil
        self.outputPipe = nil
        self.processGroupID = 0
        self.running = false

        if pgid > 0 {
            kill(-pgid, SIGKILL)
        } else if let proc = proc {
            kill(proc.processIdentifier, SIGKILL)
        }
    }
}
