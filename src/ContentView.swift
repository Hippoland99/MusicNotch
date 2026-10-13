import SwiftUI
import Cocoa

enum MediaSource: String {
    case spotify = "Spotify"
    case appleMusic = "Music"
    case safari = "YouTube Music"
    case none = "None"

    var iconName: String {
        switch self {
        case .spotify: return "music.note"
        case .appleMusic: return "apple.logo"
        case .safari: return "play.rectangle.fill"
        case .none: return "speaker.slash"
        }
    }

    var accentColor: Color {
        switch self {
        case .spotify: return Color.green
        case .appleMusic: return Color(red: 0.98, green: 0.22, blue: 0.35)
        case .safari: return Color(red: 1.0, green: 0.2, blue: 0.2)
        case .none: return Color.gray
        }
    }
}

@MainActor
final class UniversalMediaManager: ObservableObject {
    @Published var currentTrack: String = ""
    @Published var currentArtist: String = ""
    @Published var source: MediaSource = .none
    @Published var isPlaying: Bool = false
    @Published var artworkImage: NSImage? = nil

    private var pollTimer: Timer?
    private var lastId: String = ""

    init() {
        setupSystemListeners()
        fetchInitialState()
        startFallbackPolling()
    }

    private func setupSystemListeners() {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self else { return }
            if let info = note.userInfo {
                let state = (info["Player State"] as? String) ?? "Paused"
                let name = (info["Name"] as? String) ?? ""
                let artist = (info["Artist"] as? String) ?? ""
                self.updateState(source: .spotify, title: name, artist: artist, isPlaying: state == "Playing")
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self else { return }
            if let info = note.userInfo {
                let state = (info["Player State"] as? String) ?? "Paused"
                let name = (info["Name"] as? String) ?? ""
                let artist = (info["Artist"] as? String) ?? ""
                self.updateState(source: .appleMusic, title: name, artist: artist, isPlaying: state == "Playing")
            }
        }
    }

    private func updateState(source: MediaSource, title: String, artist: String, isPlaying: Bool) {
        guard !title.isEmpty else { return }
        self.source = source
        self.isPlaying = isPlaying

        let newId = "\(source.rawValue)::\(artist)::\(title)"
        if newId != self.lastId {
            self.lastId = newId
            self.currentTrack = title
            self.currentArtist = artist
            self.artworkImage = nil
            loadArtwork(for: source)
        }
    }

    private func loadArtwork(for source: MediaSource) {
        if source == .spotify {
            let script = "tell application \"Spotify\" to get artwork url of current track"
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                var error: NSDictionary?
                if let urlString = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue,
                   let url = URL(string: urlString),
                   let data = try? Data(contentsOf: url),
                   let img = NSImage(data: data) {
                    DispatchQueue.main.async {
                        self?.artworkImage = img
                    }
                }
            }
        } else if source == .appleMusic {
            let script = """
            tell application "Music"
                try
                    if (count of artworks of current track) > 0 then
                        try
                            return raw data of artwork 1 of current track
                        on error
                            return data of artwork 1 of current track
                        end try
                    end if
                end try
                return ""
            end tell
            """
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                var error: NSDictionary?
                if let scriptObj = NSAppleScript(source: script) {
                    let descriptor = scriptObj.executeAndReturnError(&error)
                    let data = descriptor.data
                    if data.count > 100, let img = NSImage(data: data) {
                        DispatchQueue.main.async {
                            self?.artworkImage = img
                        }
                        return
                    }
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard self?.source == .appleMusic, self?.artworkImage == nil else { return }
                    self?.retryAppleMusicArtwork()
                }
            }
        } else if source == .safari {
            let script = """
            tell application "Safari"
                repeat with w in windows
                    repeat with t in tabs of w
                        if URL of t contains "music.youtube.com" then
                            try
                                tell t to return do JavaScript "(function() { try { var a = navigator.mediaSession.metadata.artwork; if (a && a.length > 0) return a[a.length - 1].src; } catch(e){} var img = document.querySelector('ytmusic-player-bar img#img') || document.querySelector('ytmusic-player-bar img'); return img ? img.src : ''; })()"
                            end try
                        end if
                    end repeat
                end repeat
                return ""
            end tell
            """
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                var error: NSDictionary?
                if let urlString = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue,
                   !urlString.isEmpty,
                   let url = URL(string: urlString),
                   let data = try? Data(contentsOf: url),
                   let img = NSImage(data: data) {
                    DispatchQueue.main.async {
                        self?.artworkImage = img
                    }
                }
            }
        } else {
            self.artworkImage = nil
        }
    }

    private func retryAppleMusicArtwork() {
        let script = """
        tell application "Music"
            try
                if (count of artworks of current track) > 0 then
                    return raw data of artwork 1 of current track
                end if
            end try
            return ""
        end tell
        """
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var error: NSDictionary?
            if let scriptObj = NSAppleScript(source: script) {
                let descriptor = scriptObj.executeAndReturnError(&error)
                let data = descriptor.data
                if data.count > 100, let img = NSImage(data: data) {
                    DispatchQueue.main.async {
                        self?.artworkImage = img
                    }
                }
            }
        }
    }

    private func startFallbackPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollActiveMedia()
            }
        }
    }

    func fetchInitialState() {
        pollActiveMedia()
    }

    func pollActiveMedia() {
        if isPlaying && (source == .spotify || source == .appleMusic) {
            return
        }

        let script = """
        if application "Spotify" is running then
            tell application "Spotify"
                if player state is playing then
                    return "Spotify|||playing|||" & (name of current track) & "|||" & (artist of current track)
                end if
            end tell
        end if

        if application "Music" is running then
            tell application "Music"
                if player state is playing then
                    return "Music|||playing|||" & (name of current track) & "|||" & (artist of current track)
                end if
            end tell
        end if

        if application "Safari" is running then
            tell application "Safari"
                repeat with w in windows
                    repeat with t in tabs of w
                        set u to URL of t
                        if u contains "music.youtube.com" then
                            try
                                set isActuallyPlaying to (do JavaScript "var v = document.querySelector('video'); (v && !v.paused && v.currentTime > 0) ? 'playing' : 'paused'" in t)
                                if isActuallyPlaying is "playing" then
                                    return "Safari|||playing|||" & (name of t) & "|||YouTube Music"
                                end if
                            end try
                        end if
                    end repeat
                end repeat
            end tell
        end if

        return ""
        """

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var error: NSDictionary?
            if let res = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue, !res.isEmpty {
                let parts = res.components(separatedBy: "|||")
                if parts.count >= 4 {
                    let srcRaw = parts[0]
                    let src = (srcRaw == "Safari") ? MediaSource.safari : (MediaSource(rawValue: srcRaw) ?? .none)
                    let state = parts[1] == "playing"
                    var title = parts[2]
                    var artist = parts[3]

                    if src == .safari {
                        title = title.replacingOccurrences(of: " - YouTube Music", with: "")
                        if let regex = try? NSRegularExpression(pattern: #"^\([0-9]+\)\s*"#) {
                            title = regex.stringByReplacingMatches(in: title, range: NSRange(location: 0, length: title.utf16.count), withTemplate: "")
                        }
                        if title.contains(" • ") {
                            let ch = title.components(separatedBy: " • ")
                            title = ch[0]
                            artist = ch.dropFirst().joined(separator: " • ")
                        } else if title.contains(" - ") {
                            let ch = title.components(separatedBy: " - ")
                            artist = ch[0]
                            title = ch.dropFirst().joined(separator: " - ")
                        }
                    }

                    DispatchQueue.main.async {
                        self?.updateState(source: src, title: title, artist: artist, isPlaying: state)
                    }
                }
            }
        }
    }

    private func executeYouTubeMusicAction(_ jsCode: String) {
        let script = """
        tell application "Safari"
            repeat with w in windows
                repeat with t in tabs of w
                    if URL of t contains "music.youtube.com" then
                        try
                            tell t to do JavaScript "\(jsCode)"
                        end try
                        return
                    end if
                end repeat
            end repeat
        end tell
        """
        runAppleScript(script)
    }

    func togglePlayPause() {
        switch source {
        case .spotify:
            runAppleScript("tell application \"Spotify\" to playpause")
        case .appleMusic:
            let script = """
            tell application "Music"
                if player state is playing then
                    pause
                else
                    play
                end if
            end tell
            """
            runAppleScript(script)
        case .safari:
            let js = "var btn = document.querySelector('#play-pause-button #button') || document.querySelector('#play-pause-button') || document.querySelector('.play-pause-button'); if (btn) { btn.click(); } else { var v = document.querySelector('video'); if (v) { v.paused ? v.play() : v.pause(); } }"
            executeYouTubeMusicAction(js)
        case .none: break
        }
        isPlaying.toggle()
    }

    func nextTrack() {
        switch source {
        case .spotify:
            runAppleScript("tell application \"Spotify\" to next track")
        case .appleMusic:
            runAppleScript("tell application \"Music\" to next track")
        case .safari:
            let js = "var btn = document.querySelector('.next-button #button') || document.querySelector('.next-button') || document.querySelector('#next-button'); if (btn) { btn.click(); } else { var v = document.querySelector('video'); if (v) { v.currentTime = v.duration; } }"
            executeYouTubeMusicAction(js)
        case .none: break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.pollActiveMedia()
        }
    }

    func previousTrack() {
        switch source {
        case .spotify:
            runAppleScript("tell application \"Spotify\" to previous track")
        case .appleMusic:
            let script = """
            tell application "Music"
                if player position > 2 then
                    set player position to 0
                end if
                back track
            end tell
            """
            runAppleScript(script)
        case .safari:
            let js = "var btn = document.querySelector('.previous-button #button') || document.querySelector('.previous-button') || document.querySelector('#previous-button'); if (btn) { btn.click(); } else { var v = document.querySelector('video'); if (v) { v.currentTime = 0; } }"
            executeYouTubeMusicAction(js)
        case .none: break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.pollActiveMedia()
        }
    }

    private func runAppleScript(_ src: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            NSAppleScript(source: src)?.executeAndReturnError(nil)
        }
    }
}

// MARK: - Notch View mit Intent-Delay & präziser Trefferzone
struct ContentView: View {
    @StateObject private var media = UniversalMediaManager()
    @State private var isHovered: Bool = false
    @State private var hoverIntentTask: Task<Void, Never>?
    @State private var hideTask: Task<Void, Never>?

    private let notchHeight: CGFloat = (NSScreen.main?.safeAreaInsets.top ?? 34 > 0) ? (NSScreen.main?.safeAreaInsets.top ?? 34) : 34
    private let expansionHeight: CGFloat = 46.0

    private var isExpanded: Bool {
        return isHovered && !media.currentTrack.isEmpty
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Im geschlossenen Zustand existiert die Trefferzone NUR an der Hardware-Notch!
            // Safari-Suchleiste darunter ist absolut frei von Geister-Events.
            Color.clear
                .frame(width: 250, height: isExpanded ? (notchHeight + expansionHeight) : notchHeight)
                .contentShape(Rectangle())

            VStack(spacing: 0) {
                Color.black
                    .frame(height: notchHeight)

                HStack(spacing: 8) {
                    if let art = media.artworkImage {
                        Image(nsImage: art)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 32, height: 32)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 0.5))
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(media.source.accentColor.opacity(0.25))
                                .frame(width: 32, height: 32)

                            Image(systemName: media.source.iconName)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(media.isPlaying ? media.source.accentColor : .gray)
                        }
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text(media.currentTrack.isEmpty ? "Bereit" : media.currentTrack)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Text(media.currentArtist.isEmpty ? media.source.rawValue : media.currentArtist)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.72))
                            .lineLimit(1)
                    }
                    .frame(width: 108, alignment: .leading)

                    HStack(spacing: 4) {
                        Button(action: { media.previousTrack() }) {
                            Image(systemName: "backward.fill")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundColor(.white)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(Color.white.opacity(0.16)))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)

                        Button(action: { media.togglePlayPause() }) {
                            Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundColor(.white)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(Color.white.opacity(0.16)))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)

                        Button(action: { media.nextTrack() }) {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundColor(.white)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(Color.white.opacity(0.16)))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
                .frame(height: expansionHeight)
            }
            .background(Color.black)
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 16,
                    bottomTrailingRadius: 16,
                    topTrailingRadius: 0,
                    style: .continuous
                )
            )
            .overlay(
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 16,
                    bottomTrailingRadius: 16,
                    topTrailingRadius: 0,
                    style: .continuous
                )
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
            )
            .compositingGroup()
            .shadow(color: Color.black.opacity(isExpanded ? 0.5 : 0), radius: 10, x: 0, y: 5)
            .offset(y: isExpanded ? 0 : -(expansionHeight + 4))
            .opacity(isExpanded ? 1.0 : 0.0)
            .animation(.spring(response: 0.38, dampingFraction: 0.86, blendDuration: 0), value: isExpanded)
        }
        .frame(width: 250, height: isExpanded ? (notchHeight + expansionHeight) : notchHeight, alignment: .top)
        .contentShape(Rectangle())
        .onHover { hovering in
            handleHover(hovering)
        }
    }

    private func handleHover(_ hovering: Bool) {
        hoverIntentTask?.cancel()
        hideTask?.cancel()

        if hovering {
            if isExpanded {
                isHovered = true
            } else {
                // 180ms Verweilschutz: Schnelles Durchqueren zur Safari-Suchleiste löst NICHT aus!
                hoverIntentTask = Task {
                    try? await Task.sleep(nanoseconds: 180_000_000)
                    if !Task.isCancelled {
                        isHovered = true
                    }
                }
            }
        } else {
            // Nach Verlassen 0.8s Schonfrist
            hideTask = Task {
                try? await Task.sleep(nanoseconds: 800_000_000)
                isHovered = false
            }
        }
    }
}
