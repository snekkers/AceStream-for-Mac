import AVKit
import SwiftUI

@main
struct AceStreamMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 860, minHeight: 560)
                .onAppear {
                    appDelegate.appState = appState
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var appState: AppState?

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        DispatchQueue.main.async {
            self.appState?.open(url.absoluteString)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var input = ""
    @Published var engineAddress = UserDefaults.standard.string(forKey: "engineAddress") ?? "http://127.0.0.1:6878"
    @Published var status = "Введите acestream:// ссылку или content id."
    @Published var isPlaying = false

    let player = AVPlayer()

    func open(_ value: String? = nil) {
        let source = (value ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else {
            status = "Добавьте ссылку для открытия."
            return
        }

        UserDefaults.standard.set(engineAddress, forKey: "engineAddress")

        guard let playbackURL = makePlaybackURL(from: source) else {
            status = "Не удалось распознать AceStream-ссылку или URL."
            return
        }

        input = source
        player.replaceCurrentItem(with: AVPlayerItem(url: playbackURL))
        player.play()
        isPlaying = true
        status = "Открыто: \(playbackURL.absoluteString)"
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        status = "Воспроизведение остановлено."
    }

    private func makePlaybackURL(from source: String) -> URL? {
        if let url = URL(string: source), ["http", "https"].contains(url.scheme?.lowercased()) {
            return url
        }

        guard let contentID = extractContentID(from: source) else { return nil }
        let normalizedEngineAddress = engineAddress.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard var components = URLComponents(string: "\(normalizedEngineAddress)/ace/getstream") else {
            return nil
        }
        components.queryItems = [URLQueryItem(name: "id", value: contentID)]
        return components.url
    }

    private func extractContentID(from source: String) -> String? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.range(of: #"^[A-Fa-f0-9]{40}$"#, options: .regularExpression) != nil {
            return trimmed.lowercased()
        }

        if let url = URL(string: trimmed), url.scheme?.lowercased() == "acestream" {
            let hostPart = url.host ?? ""
            let pathPart = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let candidate = hostPart.isEmpty ? pathPart : hostPart + pathPart
            if candidate.range(of: #"^[A-Fa-f0-9]{40}$"#, options: .regularExpression) != nil {
                return candidate.lowercased()
            }
        }

        guard let match = trimmed.range(of: #"[A-Fa-f0-9]{40}"#, options: .regularExpression) else {
            return nil
        }
        return String(trimmed[match]).lowercased()
    }
}

struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            playerArea
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var toolbar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                TextField("acestream://... или content id", text: $appState.input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        appState.open()
                    }

                Button {
                    appState.open()
                } label: {
                    Label("Открыть", systemImage: "play.fill")
                }
                .keyboardShortcut(.return, modifiers: .command)

                Button {
                    appState.stop()
                } label: {
                    Label("Стоп", systemImage: "stop.fill")
                }
                .disabled(!appState.isPlaying)
            }

            HStack(spacing: 10) {
                Label("Engine", systemImage: "network")
                    .foregroundStyle(.secondary)

                TextField("http://127.0.0.1:6878", text: $appState.engineAddress)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)

                Spacer()
            }
        }
        .padding(14)
    }

    private var playerArea: some View {
        ZStack {
            Color.black

            VideoPlayer(player: appState.player)

            if !appState.isPlaying {
                VStack(spacing: 10) {
                    Image(systemName: "play.rectangle")
                        .font(.system(size: 46, weight: .regular))
                    Text("AceStream Mac Player")
                        .font(.title2.weight(.semibold))
                    Text("Вставьте ссылку и запустите локальный AceStream Engine.")
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.white)
                .padding()
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text(appState.status)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .font(.footnote)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}
