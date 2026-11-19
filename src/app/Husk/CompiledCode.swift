import SwiftUI

/// Java methods compiled ahead of time (tools/dexc, husk-tl-dvmc.c): the switch that turns them off, and recording which
/// methods the apps use most, so the next build compiles those.
enum CompiledCode {
    static let enabledKey = "droidrun.compiledCode"
    static let recordKey = "droidrun.recordHotMethods"

    /// On unless turned off: the compiled dylibs in the app run in place of the interpreter.
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    static var recording: Bool { UserDefaults.standard.bool(forKey: recordKey) }

    /// In Documents, so Files shows it (On My iPhone › DroidRun) and it can be shared from there.
    static var profileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("DroidRun-hot-methods.txt")
    }

    /// Methods recorded so far (one per line).
    static var recordedMethods: Int {
        guard let s = try? String(contentsOf: profileURL, encoding: .utf8) else { return 0 }
        return s.split(separator: "\n").count
    }

    /// Before an app starts: the runtime reads these when it loads its DEX files.
    static func prepareLaunch() {
        if enabled { unsetenv("TL_DEXC") } else { setenv("TL_DEXC", "0", 1) }
        if recording { setenv("TL_DVM_PROFILE", profileURL.path, 1) } else { unsetenv("TL_DVM_PROFILE") }
        HuskLog.log("tl", "compiled code \(enabled ? "on" : "off")\(recording ? "; recording hot methods to \(profileURL.lastPathComponent)" : "")")
    }
}

struct CompiledCodeSettings: View {
    @AppStorage(CompiledCode.enabledKey) private var enabled = true
    @AppStorage(CompiledCode.recordKey) private var recording = false
    @State private var methods = CompiledCode.recordedMethods

    var body: some View {
        HuskForm {
            Section {
                Toggle("Use Compiled Code", isOn: $enabled)
            } footer: {
                Text("Java code the build compiled for this iPhone runs several times faster. Turn this off if an app crashes "
                     + "only with it on; the change applies when the app starts next.")
            }

            Section {
                Toggle("Record Hot Methods", isOn: $recording)
                DetailRow(label: "Recorded", value: "\(methods) methods", mono: false)
                if methods > 0 {
                    Button(role: .destructive) {
                        try? FileManager.default.removeItem(at: CompiledCode.profileURL); methods = 0
                    } label: { Label("Clear Recording", systemImage: "trash") }
                }
            } header: {
                Text("Make Apps Faster")
            } footer: {
                Text("While this is on, use your apps as you normally do: DroidRun notes which code they run most. Then open "
                     + "Files › On My iPhone › DroidRun, share \(CompiledCode.profileURL.lastPathComponent), and put it in the "
                     + "profiles folder of your APK repository: the next build compiles that code. Recording slows apps a little.")
            }
            .onAppear { methods = CompiledCode.recordedMethods }
        }
        .huskForm()
        .navigationTitle("Compiled Code")
    }
}
