import AVKit
import Foundation
import Network
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
                    DispatchQueue.main.async {
                        appDelegate.playerWindowAppeared()
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var appState: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeMain),
            name: NSWindow.didBecomeMainNotification,
            object: nil
        )

        DispatchQueue.main.async {
            self.focusSinglePlayerWindow()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        DispatchQueue.main.async {
            self.appState?.open(url.absoluteString)
            self.focusSinglePlayerWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        focusSinglePlayerWindow()
        return false
    }

    func playerWindowAppeared() {
        focusSinglePlayerWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc private func windowDidBecomeMain(_ notification: Notification) {
        DispatchQueue.main.async {
            self.keepOnlyOnePlayerWindow()
        }
    }

    private func focusSinglePlayerWindow() {
        keepOnlyOnePlayerWindow()
        if let window = playerWindows.first {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func keepOnlyOnePlayerWindow() {
        let windows = playerWindows
        guard windows.count > 1 else { return }

        let windowToKeep = windows.first { $0.isKeyWindow } ?? windows.first { $0.isMainWindow } ?? windows[0]
        for window in windows where window !== windowToKeep {
            window.close()
        }
    }

    private var playerWindows: [NSWindow] {
        NSApp.orderedWindows.filter { window in
            window.canBecomeMain &&
            !window.isSheet &&
            window.contentView != nil
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    private let engineContainerName = "aceserve"
    private let engineImageName = "jopsis/aceserve:latest"
    private let remuxImageName = "lscr.io/linuxserver/ffmpeg:latest"
    private var activeRemuxContainerName: String?
    private var activeHLSDirectory: URL?
    private var activeHLSServer: HLSFileServer?

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

        Task {
            await stopCurrentRemux()
        }
    }

    func testEngine() {
        Task {
            isLoading = true
            status = "Проверяю и запускаю AceStream Engine..."
            let available = await ensureEngineIsRunning()
            isLoading = false
            status = available
                ? "AceStream Engine отвечает на \(normalizedEngineAddress)."
                : status
        }
    }

    private func openResolvedURL(_ playbackURL: URL, source: String, requiresEngine: Bool) async {
        isLoading = true
        defer { isLoading = false }

        await stopCurrentRemux()

        var playableURL = playbackURL
        if requiresEngine {
            status = "Проверяю AceStream Engine..."
            guard await ensureEngineIsRunning() else {
                return
            }

            status = "Жду данные трансляции..."
            guard let streamURL = await waitForStreamData(from: playbackURL) else {
                return
            }

            status = "Готовлю поток для macOS-плеера..."
            guard let hlsURL = await startHLSRemux(from: streamURL) else {
                return
            }
            playableURL = hlsURL
        }

        input = source
        player.replaceCurrentItem(with: AVPlayerItem(url: playableURL))
        player.play()
        isPlaying = true
        status = "Открыто: \(playableURL.absoluteString)"
    }

    private func ensureEngineIsRunning() async -> Bool {
        if await engineIsAvailable() {
            return true
        }

        guard isLocalEngineAddress else {
            status = "AceStream Engine не отвечает на \(normalizedEngineAddress). Автозапуск доступен только для локального Engine."
            return false
        }

        guard let dockerPath = dockerExecutablePath() else {
            status = "Docker Desktop не найден. Установите Docker Desktop для Mac, запустите его и попробуйте снова."
            return false
        }

        status = "AceStream Engine не запущен. Проверяю Docker Desktop..."
        if !(await dockerIsRunning(dockerPath: dockerPath)) {
            status = "Запускаю Docker Desktop..."
            _ = await runCommand("/usr/bin/open", ["-a", "Docker"])
            guard await waitForDocker(dockerPath: dockerPath) else {
                status = "Docker Desktop не запустился. Откройте Docker Desktop вручную и дождитесь статуса Docker is running."
                return false
            }
        }

        status = "Запускаю AceStream Engine..."
        guard await startEngineContainer(dockerPath: dockerPath) else {
            return false
        }

        status = "Жду AceStream Engine на \(normalizedEngineAddress)..."
        guard await waitForEngine() else {
            status = "Контейнер запущен, но Engine пока не ответил на \(normalizedEngineAddress). Попробуйте еще раз через несколько секунд."
            return false
        }

        return true
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

    private var isLocalEngineAddress: Bool {
        guard let host = URL(string: normalizedEngineAddress)?.host?.lowercased() else {
            return false
        }
        return ["127.0.0.1", "localhost", "::1"].contains(host)
    }

    private func waitForEngine() async -> Bool {
        for _ in 1...60 {
            if await engineIsAvailable() {
                return true
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return false
    }

    private func waitForStreamData(from url: URL) async -> URL? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 45
        let session = URLSession(configuration: configuration)

        do {
            let (bytes, response) = try await session.bytes(from: url)
            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                status = "AceStream Engine вернул HTTP \(httpResponse.statusCode). Проверьте ссылку."
                return nil
            }

            for try await _ in bytes {
                return response.url ?? url
            }

            status = "Трансляция открылась, но не отдала видео-данные."
            return nil
        } catch {
            status = "Трансляция сейчас не отдает данные. Возможно, ссылка неактивна или нет peers."
            return nil
        }
    }

    private func startHLSRemux(from streamURL: URL) async -> URL? {
        guard let dockerPath = dockerExecutablePath() else {
            status = "Docker Desktop не найден. Нужен Docker для подготовки AceStream-потока к воспроизведению."
            return nil
        }

        let containerName = "acestream-remux-\(UUID().uuidString.lowercased())"
        let hlsDirectory = URL(fileURLWithPath: "/tmp/AceStreamMac/HLS/\(UUID().uuidString)", isDirectory: true)
        let playlistURL = hlsDirectory.appendingPathComponent("stream.m3u8")

        do {
            try FileManager.default.createDirectory(at: hlsDirectory, withIntermediateDirectories: true)
        } catch {
            status = "Не удалось создать папку HLS: \(error.localizedDescription)"
            return nil
        }

        guard let dockerInputURL = dockerReachableURL(from: streamURL) else {
            status = "Не удалось подготовить URL потока для Docker."
            return nil
        }

        activeRemuxContainerName = containerName
        activeHLSDirectory = hlsDirectory

        let result = await runCommand(dockerPath, [
            "run", "-d", "--rm",
            "--name", containerName,
            "-v", "\(hlsDirectory.path):/hls",
            remuxImageName,
            "-hide_banner",
            "-loglevel", "warning",
            "-fflags", "+genpts",
            "-i", dockerInputURL.absoluteString,
            "-c", "copy",
            "-f", "hls",
            "-hls_time", "3",
            "-hls_list_size", "8",
            "-hls_flags", "delete_segments+append_list+omit_endlist",
            "/hls/stream.m3u8"
        ])

        if result.exitCode != 0 {
            status = "Не удалось запустить ffmpeg для HLS: \(result.output.trimmedForStatus)"
            activeRemuxContainerName = nil
            activeHLSDirectory = nil
            return nil
        }

        guard await waitForHLSPlaylist(at: playlistURL, in: hlsDirectory) else {
            status = "ffmpeg запустился, но HLS-поток не появился. Возможно, трансляция оборвалась или формат не поддержан."
            await stopCurrentRemux()
            return nil
        }

        do {
            let server = HLSFileServer(directory: hlsDirectory)
            let httpURL = try await server.start()
            activeHLSServer = server
            return httpURL
        } catch {
            status = "Не удалось запустить локальный HLS-сервер: \(error.localizedDescription)"
            await stopCurrentRemux()
            return nil
        }
    }

    private func waitForHLSPlaylist(at playlistURL: URL, in directory: URL) async -> Bool {
        for _ in 1...60 {
            if FileManager.default.fileExists(atPath: playlistURL.path),
               let contents = try? String(contentsOf: playlistURL, encoding: .utf8),
               contents.contains("#EXTINF"),
               hlsDirectoryHasSegments(directory) {
                return true
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return false
    }

    private func hlsDirectoryHasSegments(_ directory: URL) -> Bool {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return false
        }

        return files.contains { file in
            guard file.pathExtension == "ts",
                  let values = try? file.resourceValues(forKeys: [.fileSizeKey]),
                  let fileSize = values.fileSize else {
                return false
            }
            return fileSize > 0
        }
    }

    private func dockerReachableURL(from url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        if let host = components.host?.lowercased(),
           ["127.0.0.1", "localhost", "::1"].contains(host) {
            components.host = "host.docker.internal"
        }

        return components.url
    }

    private func stopCurrentRemux() async {
        let containerName = activeRemuxContainerName
        let hlsDirectory = activeHLSDirectory
        let hlsServer = activeHLSServer
        activeRemuxContainerName = nil
        activeHLSDirectory = nil
        activeHLSServer = nil

        hlsServer?.stop()

        if let containerName,
           let dockerPath = dockerExecutablePath() {
            _ = await runCommand(dockerPath, ["stop", containerName])
        }

        if let hlsDirectory {
            try? FileManager.default.removeItem(at: hlsDirectory)
        }
    }

    private func dockerExecutablePath() -> String? {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/docker",
            "/usr/local/bin/docker",
            "\(homeDirectory)/.docker/bin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker"
        ]

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func dockerIsRunning(dockerPath: String) async -> Bool {
        let result = await runCommand(dockerPath, ["info"])
        return result.exitCode == 0
    }

    private func waitForDocker(dockerPath: String) async -> Bool {
        for _ in 1...90 {
            if await dockerIsRunning(dockerPath: dockerPath) {
                return true
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return false
    }

    private func startEngineContainer(dockerPath: String) async -> Bool {
        let runningContainers = await runCommand(dockerPath, ["ps", "--format", "{{.Names}}"])
        if runningContainers.output.lines.contains(engineContainerName) {
            return true
        }

        let allContainers = await runCommand(dockerPath, ["ps", "-a", "--format", "{{.Names}}"])
        if allContainers.output.lines.contains(engineContainerName) {
            let startResult = await runCommand(dockerPath, ["start", engineContainerName])
            if startResult.exitCode != 0 {
                status = "Не удалось запустить контейнер \(engineContainerName): \(startResult.output.trimmedForStatus)"
                return false
            }
            return true
        }

        status = "Скачиваю и запускаю AceStream Engine. Первый запуск может занять несколько минут..."
        let runResult = await runCommand(dockerPath, [
            "run", "-d",
            "--name", engineContainerName,
            "--restart", "unless-stopped",
            "-p", "6878:6878",
            "-p", "8621:8621",
            "-p", "62062:62062",
            engineImageName
        ])

        if runResult.exitCode != 0 {
            status = "Не удалось запустить AceStream Engine: \(runResult.output.trimmedForStatus)"
            return false
        }

        return true
    }

    private func runCommand(_ executablePath: String, _ arguments: [String]) async -> CommandResult {
        await Task.detached(priority: .utility) {
            let process = Process()
            let pipe = Pipe()

            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe
            process.environment = [
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": FileManager.default.homeDirectoryForCurrentUser.path
            ]

            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                return CommandResult(exitCode: process.terminationStatus, output: output)
            } catch {
                return CommandResult(exitCode: 127, output: error.localizedDescription)
            }
        }.value
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

private struct CommandResult {
    let exitCode: Int32
    let output: String
}

private final class HLSFileServer {
    private let directory: URL
    private let queue = DispatchQueue(label: "local.hls.server")
    private var listener: NWListener?

    init(directory: URL) {
        self.directory = directory.standardizedFileURL
    }

    func start() async throws -> URL {
        let listener = try NWListener(using: .tcp, on: 0)
        self.listener = listener

        return try await withCheckedThrowingContinuation { continuation in
            let resumeState = OneShotResume()

            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumeState.resume {
                        let port = listener.port?.rawValue ?? 0
                        continuation.resume(returning: URL(string: "http://127.0.0.1:\(port)/stream.m3u8")!)
                    }
                case .failed(let error):
                    resumeState.resume {
                        continuation.resume(throwing: error)
                    }
                default:
                    break
                }
            }

            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }

            self.respond(to: request, on: connection)
        }
    }

    private func respond(to request: String, on connection: NWConnection) {
        let firstLine = request.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            send(status: "400 Bad Request", body: Data(), contentType: "text/plain", on: connection)
            return
        }

        let method = String(parts[0])
        guard method == "GET" || method == "HEAD" else {
            send(status: "405 Method Not Allowed", body: Data(), contentType: "text/plain", on: connection)
            return
        }

        let rawPath = String(parts[1]).components(separatedBy: "?").first ?? "/"
        let requestedName = rawPath == "/" ? "stream.m3u8" : String(rawPath.dropFirst()).removingPercentEncoding ?? ""
        let fileURL = directory.appendingPathComponent(requestedName).standardizedFileURL

        guard fileURL.path.hasPrefix(directory.path + "/"),
              let body = try? Data(contentsOf: fileURL) else {
            send(status: "404 Not Found", body: Data(), contentType: "text/plain", on: connection)
            return
        }

        let responseBody = method == "HEAD" ? Data() : body
        let shouldSendLength = fileURL.pathExtension.lowercased() != "m3u8" || method == "HEAD"
        send(
            status: "200 OK",
            body: responseBody,
            contentType: contentType(for: fileURL),
            contentLength: shouldSendLength ? body.count : nil,
            on: connection
        )
    }

    private func send(status: String, body: Data, contentType: String, contentLength: Int? = nil, on connection: NWConnection) {
        var headers = """
        HTTP/1.1 \(status)\r
        Content-Type: \(contentType)\r
        Cache-Control: no-cache\r
        Access-Control-Allow-Origin: *\r
        Connection: close\r
        """

        if let contentLength {
            headers += "Content-Length: \(contentLength)\r\n"
        }

        headers += "\r\n"

        var response = Data(headers.utf8)
        response.append(body)
        connection.send(content: response, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m3u8":
            return "application/vnd.apple.mpegurl"
        case "ts":
            return "video/mp2t"
        default:
            return "application/octet-stream"
        }
    }
}

private final class OneShotResume: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resume(_ block: () -> Void) {
        lock.lock()
        if didResume {
            lock.unlock()
            return
        }
        didResume = true
        lock.unlock()
        block()
    }
}

private extension String {
    var lines: [String] {
        split(whereSeparator: \.isNewline).map(String.init)
    }

    var trimmedForStatus: String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "нет деталей ошибки" : trimmed
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
                    Label("Запустить Engine", systemImage: "power")
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
                    Text("Вставьте ссылку. Engine запустится автоматически через Docker Desktop.")
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
