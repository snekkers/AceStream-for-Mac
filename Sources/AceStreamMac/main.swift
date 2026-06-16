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
    @Published var isLoading = false

    let player = AVPlayer()

    func open(_ value: String? = nil) {
        let source = (value ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else {
            status = "Добавьте ссылку для открытия."
            return
        }

        UserDefaults.standard.set(engineAddress, forKey: "engineAddress")

        guard let resolved = makePlaybackURL(from: source) else {
            status = "Не удалось распознать AceStream-ссылку или URL."
            return
        }

        Task {
            await openResolvedURL(resolved.url, source: source, requiresEngine: resolved.requiresEngine)
        }
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        isLoading = false
        status = "Воспроизведение остановлено."
    }

    func testEngine() {
        Task {
            isLoading = true
            status = "Проверяю AceStream Engine..."
            let available = await engineIsAvailable()
            isLoading = false
            status = available
                ? "AceStream Engine отвечает на \(normalizedEngineAddress)."
                : "AceStream Engine не отвечает на \(normalizedEngineAddress). Запустите engine и попробуйте снова."
        }
    }

    private func openResolvedURL(_ playbackURL: URL, source: String, requiresEngine: Bool) async {
        isLoading = true
        defer { isLoading = false }

        if requiresEngine {
            status = "Проверяю AceStream Engine..."
            guard await engineIsAvailable() else {
                status = "AceStream Engine не отвечает на \(normalizedEngineAddress). Ссылка не сможет запуститься без engine."
                return
            }
        }

        input = source
        player.replaceCurrentItem(with: AVPlayerItem(url: playbackURL))
        player.play()
        isPlaying = true
        status = "Открыто: \(playbackURL.absoluteString)"
    }

    private func engineIsAvailable() async -> Bool {
        guard let url = URL(string: normalizedEngineAddress) else { return false }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 3
        let session = URLSession(configuration: configuration)

        do {
            _ = try await session.data(from: url)
            return true
        } catch {
            return false
        }
    }

    private var normalizedEngineAddress: String {
        engineAddress.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    private func makePlaybackURL(from source: String) -> PlaybackURL? {
        if let url = URL(string: source), ["http", "https"].contains(url.scheme?.lowercased()) {
            return PlaybackURL(url: url, requiresEngine: false)
        }

        guard let contentID = extractContentID(from: source) else { return nil }
        guard var components = URLComponents(string: "\(normalizedEngineAddress)/ace/getstream") else {
            return nil
        }
        components.queryItems = [URLQueryItem(name: "id", value: contentID)]
        guard let url = components.url else { return nil }
        return PlaybackURL(url: url, requiresEngine: true)
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

private struct PlaybackURL {
    let url: URL
    let requiresEngine: Bool
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
                .disabled(appState.isLoading)

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

                Button {
                    appState.testEngine()
                } label: {
                    Label("Проверить", systemImage: "checkmark.circle")
                }
                .disabled(appState.isLoading)

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
