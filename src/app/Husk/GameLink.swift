// SPDX-License-Identifier: GPL-2.0-or-later
// droidrun://game/<package>, from a game's page on the website ("Open in DroidRun"): its page here when it is added, else the Store's.
// droidrun://run/<package or app id>: the app itself, started at once -- what a Home Screen icon made in Shortcuts opens.
import AppIntents
import Foundation
import SwiftUI
import UIKit

@MainActor enum GameLink {
    static func handle(_ url: URL) -> Bool {
        guard url.scheme == "droidrun" else { return false }
        if url.host == "run" { return run(url.lastPathComponent) }
        guard url.host == "game" || url.host == "app" else { return false }
        let id = url.lastPathComponent
        guard !id.isEmpty, id != "/" else { return true }
        let router = Router.shared
        if let item = Launcher.items(store: TranslationLayerStore.shared, host: AndroidHost.shared).first(where: { $0.accountID == id }) {
            router.tab = .home
            router.home = [item.route]
        } else {
            router.tab = .store
            router.storePackage = id
        }
        HuskLog.log("ui", "game link \(id)")
        return true
    }

    /// The app with this package name (or DroidRun's own id for it), opened on its page and started there: its page plays it as
    /// soon as it can (autoPlay), or offers to close DroidRun when another app is already loaded in this run.
    @discardableResult
    static func run(_ id: String) -> Bool {
        guard !id.isEmpty, id != "/" else { return true }
        let router = Router.shared
        guard let app = TranslationLayerStore.shared.apps.first(where: { $0.packageName == id || $0.id == id }) else {
            HuskLog.log("ui", "run link \(id): no such app here")
            router.tab = .store
            router.storePackage = id
            return true
        }
        HuskLog.log("ui", "run link \(app.packageName ?? app.id)")
        router.tab = .library
        router.library = [.game(app.id)]
        router.autoPlay = app.id
        return true
    }

    static func runURL(for app: TLApp) -> URL { URL(string: "droidrun://run/\(app.packageName ?? app.id)")! }
}

// ---- a Home Screen icon for an Android app: a Shortcuts shortcut that opens droidrun://run/<package>

/// How to put an app on the Home Screen: iOS gives an icon of its own only to an installed iOS app, so the icon is a shortcut that
/// opens the app in DroidRun. The link and the app's picture are made ready here; Shortcuts does the rest.
struct HomeScreenIconSheet: View {
    let app: TLApp
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var iconSaved: String?

    private var icon: UIImage? { app.iconPath.flatMap { UIImage(contentsOfFile: $0) } }

    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack(spacing: 14) {
                        if let icon {
                            Image(uiImage: icon).resizable().frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 13))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.label).font(.headline)
                            Text(GameLink.runURL(for: app).absoluteString).font(.footnote.monospaced()).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                Section {
                    Button { UIPasteboard.general.string = GameLink.runURL(for: app).absoluteString; copied = true } label: {
                        Label(copied ? "Link Copied" : "Copy Link", systemImage: copied ? "checkmark" : "link")
                    }
                    if let icon {
                        Button { saveIcon(icon) } label: {
                            Label(iconSaved ?? "Save Icon to Photos", systemImage: iconSaved == nil ? "photo" : "checkmark")
                        }
                    }
                    Button { if let u = URL(string: "shortcuts://create-shortcut") { UIApplication.shared.open(u) } } label: {
                        Label("Open Shortcuts", systemImage: "square.on.square")
                    }
                } footer: {
                    Text("Tapping the icon opens \(app.label) in DroidRun. Only one app runs per session: if another is open, DroidRun offers to close and start this one.")
                }
                Section("In Shortcuts") {
                    step(1, "Tap + for a new shortcut, then Add Action.")
                    step(2, "Search \"Open \(app.label) in DroidRun\" (DroidRun's own action), or \"Open URLs\" and paste the link.")
                    step(3, "Tap the shortcut's name at the top, then Add to Home Screen.")
                    step(4, "Tap the icon, Choose Photo, and pick the icon you saved. Name it \(app.label), then Add.")
                }
            }
            .navigationTitle("Add to Home Screen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.footnote.bold()).frame(width: 22, height: 22).background(Circle().fill(Color.accentColor.opacity(0.18)))
            Text(text).font(.subheadline)
        }
    }

    /// At the size a Home Screen icon is chosen at, on an opaque background (a transparent corner shows black there)
    private func saveIcon(_ icon: UIImage) {
        let side: CGFloat = 512
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            UIColor.white.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: side, height: side))
            icon.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        iconSaved = "Icon Saved to Photos"
    }
}

// ---- Shortcuts: "Open <app> in DroidRun", with the apps added here to pick from

@available(iOS 16.0, *)
struct AndroidAppEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Android App")
    static var defaultQuery = AndroidAppQuery()
    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

@available(iOS 16.0, *)
struct AndroidAppQuery: EntityQuery {
    @MainActor private func all() -> [AndroidAppEntity] {
        TranslationLayerStore.shared.apps.map { AndroidAppEntity(id: $0.packageName ?? $0.id, name: $0.label) }
    }
    func entities(for identifiers: [String]) async throws -> [AndroidAppEntity] {
        await MainActor.run { all().filter { identifiers.contains($0.id) } }
    }
    func suggestedEntities() async throws -> [AndroidAppEntity] { await MainActor.run { all() } }
}

@available(iOS 16.0, *)
struct OpenAndroidAppIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Android App in DroidRun"
    static var description = IntentDescription("Opens an Android app added to DroidRun and starts it.")
    static var openAppWhenRun = true
    @Parameter(title: "App") var app: AndroidAppEntity
    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$app) in DroidRun") }

    @MainActor func perform() async throws -> some IntentResult {
        GameLink.run(app.id)
        return .result()
    }
}

@available(iOS 16.0, *)
struct DroidRunShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenAndroidAppIntent(), phrases: ["Open an Android app in \(.applicationName)"])
    }
}
