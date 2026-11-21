import Foundation
import AVFoundation
import Combine

// MARK: - Audio Manager
// MARK: - 栖时场景库（qishi_presets.json 随包快照；音频 macOS 优先本机栖时仓库、缺失走公开站流式，iOS 直接流式）

struct QishiTrack: Codable {
    let id: String
    let file: String
    let volume: Int   // 0-100，栖时调好的场景混音比例
}

struct QishiPreset: Codable {
    let id: String
    let name: String
    let subtitle: String
    let tracks: [QishiTrack]
}

struct QishiLibraryFile: Codable {
    let version: Int
    let presets: [QishiPreset]
}

enum QishiSceneStore {
    static let streamBase = "https://allen7wang.github.io/qishi-meditation-web/audio/"

    static let presets: [QishiPreset] = {
        let url = Bundle.main.url(forResource: "qishi_presets", withExtension: "json", subdirectory: "audio")
            ?? Bundle.main.url(forResource: "qishi_presets", withExtension: "json")
        guard let url = url, let data = try? Data(contentsOf: url),
              let lib = try? JSONDecoder().decode(QishiLibraryFile.self, from: data) else { return [] }
        return lib.presets
    }()

    static func audioURL(for file: String) -> URL? {
        #if os(macOS)
        let local = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("GitHub/qishi-meditation/public/audio").appendingPathComponent(file)
        if FileManager.default.fileExists(atPath: local.path) { return local }
        #endif
        guard let encoded = file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: streamBase + encoded)
    }

    /// 随机一个场景；候选多于一个时避开 excluding（不与上个番茄重复）
    static func randomPreset(excluding id: String?) -> QishiPreset? {
        guard !presets.isEmpty else { return nil }
        var pool = presets
        if let id = id, pool.count > 1 { pool.removeAll { $0.id == id } }
        return pool.randomElement()
    }
}

class AudioManager: ObservableObject {
    static let shared = AudioManager()

    private var ambientPlayer: AVAudioPlayer?
    private var soundPlayer: AVAudioPlayer?
    private var ambientFilename: String?
    // 栖时场景多轨播放（AVPlayer：本地文件与公开站流式统一支持；循环 = 播完 seek 0 重播）
    private var qishiPlayers: [(player: AVPlayer, trackVolume: Int)] = []
    private var qishiObservers: [NSObjectProtocol] = []
    private var qishiPaused = false
    private var qishiPreviewManager: AudioManager?
    private(set) var currentQishiSceneId: String?
    /// 跨番茄记忆：新番茄随机场景时避开上一个（stop 后保留）
    private(set) var lastQishiSceneId: String?
    @Published var lastError: String?

    // Sound file lists (mirror the extension)
    static let sounds = ["Sound1", "Sound2", "Sound3", "Sound4", "Sound5", "Sound6", "Sound7", "Sound8", "Sound9"]
    static let ambientSounds = ["Ambient Clock", "Ambient Rain", "Ambient Crickets", "Ambient Birds"]
    static var allSoundOptions: [String] { ["None"] + (sounds.map { "\($0).mp3" } + ["clockTicking.mp3"]).filter { bundledAudio($0) != nil } }
    static var allAmbientOptions: [String] { ["None"] + ambientSounds.map { "\($0).mp3" }.filter { bundledAudio($0) != nil } }

    private static func bundledAudio(_ filename: String) -> URL? {
        Bundle.main.url(forResource: filename, withExtension: nil, subdirectory: "audio") ?? Bundle.main.url(forResource: filename, withExtension: nil)
    }

    // Audio bundle: look in the app bundle's "audio" subfolder
    private func audioURL(_ filename: String) -> URL? {
        // Try bundle Resources/audio folder (works in .app bundle)
        if let url = Bundle.main.url(forResource: filename, withExtension: nil, subdirectory: "audio") {
            return url
        }
        // Try bundle Resources directly (if audio files are flat)
        if let url = Bundle.main.url(forResource: filename, withExtension: nil) {
            return url
        }
        // Try adjacent audio folder (dev mode - running from binary)
        let execURL = URL(fileURLWithPath: Bundle.main.bundlePath)
        let audioDir = execURL.appendingPathComponent("audio")
        let candidate = audioDir.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        // Try relative to source directory (dev mode)
        let relDir = URL(fileURLWithPath: "audio")
        let relCandidate = relDir.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: relCandidate.path) {
            return relCandidate
        }
        return nil
    }

    func playSound(_ filename: String, volume: Double) {
        guard filename != "None" else { stopPreview(); return }
        lastError = nil
        guard let url = audioURL(filename) else { lastError = "音频文件不存在：\(filename)"; return }
        do {
            soundPlayer = try AVAudioPlayer(contentsOf: url)
            soundPlayer?.volume = Float(volume)
            soundPlayer?.play()
        } catch { lastError = "无法播放音效：\(error.localizedDescription)"; print("Audio error: \(error)") }
    }

    func playAmbient(sound: String, volume: Double) {
        guard sound != "None" else { stopAmbient(); return }
        if ambientFilename == sound, let player = ambientPlayer {
            player.volume = Float(min(1, max(0, volume)))
            if !player.isPlaying { player.play() }
            return
        }
        stopAmbient()
        ambientFilename = sound
        guard let url = audioURL(sound) else { lastError = "音频文件不存在：\(sound)"; return }
        do {
            ambientPlayer = try AVAudioPlayer(contentsOf: url)
            ambientPlayer?.numberOfLoops = -1
            ambientPlayer?.volume = Float(volume)
            ambientPlayer?.play()
        } catch { lastError = "无法播放环境音：\(error.localizedDescription)"; print("Ambient audio error: \(error)") }
    }

    /// Pause playback resources without discarding this focus session's scene or position.
    func pauseAmbient() {
        ambientPlayer?.pause()
        qishiPaused = true
        for entry in qishiPlayers { entry.player.pause() }
    }

    func stopAmbient() {
        ambientPlayer?.stop()
        ambientPlayer = nil
        ambientFilename = nil
        stopQishi()
    }

    // MARK: - 栖时随机场景（ambientSource == "qishi"）

    /// 统一环境音入口：qishi 模式每个番茄随机一个场景混音；custom 模式维持原单轨方案。
    /// newSession=true 在番茄开始时调用（换新场景，避开上个番茄）；
    /// false 在暂停恢复/回前台时调用（延续当前场景，只调音量或重播同一场景）。
    func playAmbientFor(settings: UserSettings, newSession: Bool) {
        if newSession { stopPreview() }
        guard settings.ambientSource == "qishi" else {
            stopQishi()
            playAmbient(sound: settings.ambientSound, volume: settings.ambientSoundVolume)
            return
        }
        // 停掉自定义单轨（若之前是 custom 模式）
        ambientPlayer?.stop(); ambientPlayer = nil; ambientFilename = nil
        let preset: QishiPreset?
        if !newSession, let id = currentQishiSceneId,
           let p = QishiSceneStore.presets.first(where: { $0.id == id }) {
            preset = p
        } else {
            preset = QishiSceneStore.randomPreset(excluding: lastQishiSceneId)
        }
        guard let chosen = preset else {
            lastError = "栖时场景库不可用（qishi_presets.json 缺失或为空）"
            return
        }
        if currentQishiSceneId == chosen.id, !qishiPlayers.isEmpty {
            setQishiVolume(settings.ambientSoundVolume)
            if qishiPaused {
                qishiPaused = false
                for entry in qishiPlayers { entry.player.play() }
            }
            return
        }
        playQishiScene(chosen, volume: settings.ambientSoundVolume)
    }

    private static func trackGain(_ trackVolume: Int, user: Double) -> Double {
        min(1, max(0, Double(trackVolume) / 100.0 * min(1, max(0, user))))
    }

    func playQishiScene(_ preset: QishiPreset, volume: Double) {
        stopQishi()
        for track in preset.tracks {
            guard let url = QishiSceneStore.audioURL(for: track.file) else { continue }
            let player = AVPlayer(url: url)
            player.volume = Float(Self.trackGain(track.volume, user: volume))
            let observer = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main
            ) { [weak self, weak player] _ in
                guard let self = self, let player = player,
                      self.qishiPlayers.contains(where: { $0.player === player }) else { return }
                // EOF can be delivered after pause. Keep the owned loop ready for resume,
                // but never restart playback while this focus session is paused.
                player.seek(to: .zero)
                if !self.qishiPaused { player.play() }
            }
            qishiObservers.append(observer)
            qishiPlayers.append((player, track.volume))
            player.play()
        }
        guard !qishiPlayers.isEmpty else {
            lastError = "栖时场景播放失败：\(preset.name)（音频不可用）"
            return
        }
        currentQishiSceneId = preset.id
        lastQishiSceneId = preset.id
        lastError = nil
    }

    /// 只调音量不重启播放（暂停恢复/设置变更）
    func setQishiVolume(_ volume: Double) {
        for entry in qishiPlayers {
            entry.player.volume = Float(Self.trackGain(entry.trackVolume, user: volume))
        }
    }

    func stopQishi() {
        for o in qishiObservers { NotificationCenter.default.removeObserver(o) }
        qishiObservers.removeAll()
        for entry in qishiPlayers { entry.player.pause(); entry.player.replaceCurrentItem(with: nil) }
        qishiPlayers.removeAll()
        qishiPaused = false
        currentQishiSceneId = nil
    }

    /// Preview has its own player owner and never changes focus scene identity/history.
    func playQishiPreview(_ preset: QishiPreset, volume: Double) {
        stopPreview()
        let preview = AudioManager()
        preview.playQishiScene(preset, volume: volume)
        qishiPreviewManager = preview
        lastError = preview.lastError
    }

    /// Settings disappearance and stop-preview release preview resources only.
    func stopPreview() {
        soundPlayer?.stop()
        soundPlayer = nil
        qishiPreviewManager?.stopAmbient()
        qishiPreviewManager = nil
    }
}
