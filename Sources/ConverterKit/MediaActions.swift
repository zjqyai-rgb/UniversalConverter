import AVFoundation
import Foundation

enum AV {
    static func export(_ asset: AVAsset, preset: String, to url: URL, type: AVFileType, ctx: ActionContext) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConvertError.failed("This file can't be exported with the \(preset) preset.")
        }
        session.outputURL = url
        session.outputFileType = type
        session.shouldOptimizeForNetworkUse = true
        let poll = Task {
            while !Task.isCancelled {
                ctx.progress(Double(session.progress))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer { poll.cancel() }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { c.resume() }
        }
        if session.status != .completed {
            try? FileManager.default.removeItem(at: url)
            throw ConvertError.failed(session.error?.localizedDescription ?? "Export failed.")
        }
    }

    static func hasVideo(_ url: URL) async -> Bool {
        let tracks = (try? await AVURLAsset(url: url).loadTracks(withMediaType: .video)) ?? []
        return !tracks.isEmpty
    }

    /// Returns a URL that afconvert can read: audio files directly, video soundtracks extracted to a temp .m4a.
    static func audioSource(_ url: URL, ctx: ActionContext) async throws -> (URL, Bool) {
        guard url.kind == .video else { return (url, false) }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        try await export(AVURLAsset(url: url), preset: AVAssetExportPresetAppleM4A, to: tmp, type: .m4a, ctx: ctx)
        return (tmp, true)
    }
}

enum MediaActions {
    static let video: Set<FileKind> = [.video]
    static let audioIn: Set<FileKind> = [.audio, .video]

    static var all: [FileAction] { videoActions + audioActions + ffmpegActions }

    // MARK: Video

    static var videoActions: [FileAction] {
        func exportAction(_ id: String, _ title: String, _ detail: String, _ symbol: String, preset: String,
                          ext: String, type: AVFileType, suffix: String? = nil, same: Set<String> = []) -> FileAction {
            FileAction(id: id, title: title, detail: detail, symbol: symbol, category: .video, accepts: video, sameFormat: same,
                       mode: .each { url, ctx in
                let out = ctx.destination(for: url, ext: ext, suffix: suffix)
                try await AV.export(AVURLAsset(url: url), preset: preset, to: out, type: type, ctx: ctx)
                return ActionOutput(files: [out])
            })
        }
        return [
            exportAction("video.mp4", "MP4", "H.264 MP4 at original size", "film", preset: AVAssetExportPresetHighestQuality, ext: "mp4", type: .mp4, same: ["mp4"]),
            exportAction("video.mov", "MOV", "QuickTime movie", "film.stack", preset: AVAssetExportPresetHighestQuality, ext: "mov", type: .mov, same: ["mov"]),
            exportAction("video.m4v", "M4V", "Apple M4V video", "tv", preset: AVAssetExportPresetHighestQuality, ext: "m4v", type: .m4v, same: ["m4v"]),
            exportAction("video.hevc", "HEVC", "H.265 – smaller files, same quality", "film.circle", preset: AVAssetExportPresetHEVCHighestQuality, ext: "mp4", type: .mp4, suffix: "HEVC"),
            exportAction("video.prores", "ProRes", "Apple ProRes 422 for editing", "slider.horizontal.below.rectangle", preset: AVAssetExportPresetAppleProRes422LPCM, ext: "mov", type: .mov, suffix: "ProRes"),
            exportAction("video.4k", "4K", "Scale to 3840×2160 (HEVC)", "4k.tv", preset: AVAssetExportPresetHEVC3840x2160, ext: "mp4", type: .mp4, suffix: "4K"),
            exportAction("video.1080", "1080p", "Scale to 1920×1080", "rectangle.inset.filled", preset: AVAssetExportPreset1920x1080, ext: "mp4", type: .mp4, suffix: "1080p"),
            exportAction("video.720", "720p", "Scale to 1280×720", "rectangle.inset.filled", preset: AVAssetExportPreset1280x720, ext: "mp4", type: .mp4, suffix: "720p"),
            exportAction("video.480", "480p", "Scale to 640×480", "rectangle.inset.filled", preset: AVAssetExportPreset640x480, ext: "mp4", type: .mp4, suffix: "480p"),
            exportAction("video.small", "Shrink", "Medium quality for sharing", "arrow.down.circle", preset: AVAssetExportPresetMediumQuality, ext: "mp4", type: .mp4, suffix: "small"),
            FileAction(id: "video.mute", title: "Remove Audio", detail: "Strip the soundtrack, keep the picture", symbol: "speaker.slash",
                       category: .video, accepts: video, mode: .each { url, ctx in
                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration)
                let comp = AVMutableComposition()
                for track in try await asset.loadTracks(withMediaType: .video) {
                    guard let ct = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                    try ct.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
                    ct.preferredTransform = try await track.load(.preferredTransform)
                }
                let mov = url.ext == "mov"
                let out = ctx.destination(for: url, ext: mov ? "mov" : "mp4", suffix: "muted")
                try await AV.export(comp, preset: AVAssetExportPresetPassthrough, to: out, type: mov ? .mov : .mp4, ctx: ctx)
                return ActionOutput(files: [out])
            }),
            FileAction(id: "video.gif", title: "GIF", detail: "Animated GIF (first 20 s, 10 fps)", symbol: "square.stack.3d.forward.dottedline",
                       category: .video, accepts: video, mode: .each { url, ctx in
                let asset = AVURLAsset(url: url)
                let seconds = min(try await asset.load(.duration).seconds, 20)
                let gen = AVAssetImageGenerator(asset: asset)
                gen.appliesPreferredTrackTransform = true
                gen.maximumSize = CGSize(width: 480, height: 480)
                gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 20)
                gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 20)
                let fps = 10.0
                let count = max(1, Int(seconds * fps))
                var frames: [CGImage] = []
                for i in 0..<count {
                    let (img, _) = try await gen.image(at: CMTime(seconds: Double(i) / fps, preferredTimescale: 600))
                    frames.append(img)
                    ctx.progress(Double(i) / Double(count))
                }
                let out = ctx.destination(for: url, ext: "gif")
                try ImageKit.writeGIF(frames, delay: 1 / fps, to: out)
                return ActionOutput(files: [out])
            }),
            FileAction(id: "video.frame", title: "Snapshot", detail: "Save a still frame as PNG", symbol: "camera",
                       category: .video, accepts: video, mode: .each { url, ctx in
                let asset = AVURLAsset(url: url)
                let seconds = try await asset.load(.duration).seconds
                let gen = AVAssetImageGenerator(asset: asset)
                gen.appliesPreferredTrackTransform = true
                let (img, _) = try await gen.image(at: CMTime(seconds: min(1, seconds / 2), preferredTimescale: 600))
                let out = ctx.destination(for: url, ext: "png", suffix: "frame")
                try ImageKit.write(img, to: out, type: "public.png")
                return ActionOutput(files: [out])
            }),
            FileAction(id: "video.frames", title: "Contact Sheet", detail: "Grid of 12 frames as JPEG", symbol: "square.grid.3x3",
                       category: .video, accepts: video, mode: .each { url, ctx in
                let asset = AVURLAsset(url: url)
                let seconds = try await asset.load(.duration).seconds
                let gen = AVAssetImageGenerator(asset: asset)
                gen.appliesPreferredTrackTransform = true
                gen.maximumSize = CGSize(width: 480, height: 480)
                var frames: [CGImage] = []
                for i in 0..<12 {
                    let (img, _) = try await gen.image(at: CMTime(seconds: seconds * (Double(i) + 0.5) / 12, preferredTimescale: 600))
                    frames.append(img)
                    ctx.progress(Double(i) / 12)
                }
                let cw = frames[0].width, ch = frames[0].height, gap = 8
                let sheet = ImageKit.draw(width: cw * 4 + gap * 5, height: ch * 3 + gap * 4, opaque: true) { c in
                    c.setFillColor(CGColor(gray: 0.1, alpha: 1))
                    c.fill(CGRect(x: 0, y: 0, width: cw * 4 + gap * 5, height: ch * 3 + gap * 4))
                    for (i, f) in frames.enumerated() {
                        let col = i % 4, row = 2 - i / 4
                        c.draw(f, in: CGRect(x: gap + col * (cw + gap), y: gap + row * (ch + gap), width: cw, height: ch))
                    }
                }
                guard let sheet else { throw ConvertError.failed("Couldn't draw contact sheet.") }
                let out = ctx.destination(for: url, ext: "jpg", suffix: "contact sheet")
                try ImageKit.write(sheet, to: out, type: "public.jpeg", quality: 0.85)
                return ActionOutput(files: [out])
            }),
        ]
    }

    // MARK: Audio (afconvert, built into macOS)

    struct AudioFormat { let title, ext, file, data, symbol, detail: String; var extra: [String] = []; var same: Set<String> = [] }

    static let audioFormats: [AudioFormat] = [
        AudioFormat(title: "M4A", ext: "m4a", file: "m4af", data: "aac", symbol: "music.note", detail: "AAC in M4A, high-quality VBR", extra: ["-s", "3", "-q", "127"]),
        AudioFormat(title: "ALAC", ext: "m4a", file: "m4af", data: "alac", symbol: "music.quarternote.3", detail: "Apple Lossless in M4A"),
        AudioFormat(title: "WAV", ext: "wav", file: "WAVE", data: "LEI16", symbol: "waveform", detail: "Uncompressed 16-bit WAV", same: ["wav"]),
        AudioFormat(title: "AIFF", ext: "aiff", file: "AIFF", data: "BEI16", symbol: "waveform.path", detail: "Uncompressed 16-bit AIFF", same: ["aiff", "aif"]),
        AudioFormat(title: "FLAC", ext: "flac", file: "flac", data: "flac", symbol: "waveform.badge.plus", detail: "Free Lossless Audio Codec", same: ["flac"]),
        AudioFormat(title: "CAF", ext: "caf", file: "caff", data: "LEI16", symbol: "waveform.circle", detail: "Core Audio Format", same: ["caf"]),
        AudioFormat(title: "AAC", ext: "aac", file: "adts", data: "aac", symbol: "music.note.list", detail: "Raw AAC (ADTS) stream", extra: ["-s", "3", "-q", "127"], same: ["aac"]),
        AudioFormat(title: "M4R Ringtone", ext: "m4r", file: "m4af", data: "aac", symbol: "bell", detail: "iPhone ringtone (first 30 s)", extra: ["-s", "3", "-q", "127"]),
        AudioFormat(title: "AU", ext: "au", file: "NeXT", data: "BEI16", symbol: "speaker.wave.1", detail: "Sun/NeXT audio", same: ["au", "snd"]),
    ]

    static var audioActions: [FileAction] {
        var list = audioFormats.map { f in
            FileAction(id: "audio.\(f.title.lowercased().replacingOccurrences(of: " ", with: ""))", title: f.title, detail: f.detail,
                       symbol: f.symbol, category: .audio, accepts: audioIn, sameFormat: f.same, mode: .each { url, ctx in
                let (src, temp) = try await AV.audioSource(url, ctx: ctx)
                defer { if temp { try? FileManager.default.removeItem(at: src) } }
                var input = src
                var trimmed: URL?
                if f.ext == "m4r" { // ringtones are limited to 30 s
                    let t = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
                    let asset = AVURLAsset(url: src)
                    guard let s = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw ConvertError.unreadable(url) }
                    s.outputURL = t; s.outputFileType = .m4a
                    s.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 30, preferredTimescale: 600))
                    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in s.exportAsynchronously { c.resume() } }
                    if s.status == .completed { input = t; trimmed = t }
                }
                defer { if let trimmed { try? FileManager.default.removeItem(at: trimmed) } }
                let suffix = f.title == "ALAC" ? "ALAC" : (url.ext == f.ext ? f.title : nil)
                let out = ctx.destination(for: url, ext: f.ext, suffix: suffix)
                var args = ["-f", f.file, "-d", f.data] + f.extra
                try await Shell.run("/usr/bin/afconvert", args + [input.path, out.path])
                return ActionOutput(files: [out])
            })
        }
        list.append(FileAction(id: "audio.mono", title: "Mono", detail: "Mix down to a single channel (M4A)", symbol: "speaker.wave.1",
                               category: .audio, accepts: audioIn, mode: .each { url, ctx in
            let (src, temp) = try await AV.audioSource(url, ctx: ctx)
            defer { if temp { try? FileManager.default.removeItem(at: src) } }
            let out = ctx.destination(for: url, ext: "m4a", suffix: "mono")
            try await Shell.run("/usr/bin/afconvert", ["-f", "m4af", "-d", "aac", "-c", "1", "-s", "3", "-q", "100", src.path, out.path])
            return ActionOutput(files: [out])
        }))
        list.append(FileAction(id: "audio.voice", title: "Voice Memo", detail: "Small mono M4A for speech", symbol: "mic",
                               category: .audio, accepts: audioIn, mode: .each { url, ctx in
            let (src, temp) = try await AV.audioSource(url, ctx: ctx)
            defer { if temp { try? FileManager.default.removeItem(at: src) } }
            let out = ctx.destination(for: url, ext: "m4a", suffix: "voice")
            try await Shell.run("/usr/bin/afconvert", ["-f", "m4af", "-d", "aac", "-c", "1", "-s", "3", "-q", "50", src.path, out.path])
            return ActionOutput(files: [out])
        }))
        list.append(FileAction(id: "audio.info", title: "Media Info", detail: "Duration, codec and bitrate", symbol: "info.circle",
                               category: .audio, accepts: audioIn, mode: .each { url, _ in
            let info = (try? await Shell.run("/usr/bin/afinfo", [url.path])) ?? ""
            let asset = AVURLAsset(url: url)
            let dur = (try? await asset.load(.duration).seconds) ?? 0
            var lines = ["\(url.lastPathComponent) · \(String(format: "%d:%02d", Int(dur) / 60, Int(dur) % 60))"]
            for line in info.split(separator: "\n") where line.contains("Data format") || line.contains("bit rate") {
                lines.append(line.trimmingCharacters(in: .whitespaces))
            }
            if let v = try? await asset.loadTracks(withMediaType: .video).first, let size = try? await v.load(.naturalSize) {
                lines.append("Video: \(Int(abs(size.width)))×\(Int(abs(size.height)))")
            }
            let msg = lines.joined(separator: "\n")
            return ActionOutput(message: msg, clipboard: msg)
        }))
        return list
    }

    // MARK: Extras when ffmpeg is installed (still fully offline)

    static var ffmpegActions: [FileAction] {
        guard let ffmpeg = Tools.ffmpeg else { return [] }
        func ff(_ id: String, _ title: String, _ detail: String, _ symbol: String, _ category: ActionCategory,
                accepts: Set<FileKind>, ext: String, same: Set<String> = [], args: [String]) -> FileAction {
            FileAction(id: id, title: title, detail: detail, symbol: symbol, category: category, accepts: accepts, sameFormat: same,
                       mode: .each { url, ctx in
                let out = ctx.destination(for: url, ext: ext)
                try await Shell.run(ffmpeg, ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", url.path] + args + [out.path])
                return ActionOutput(files: [out])
            })
        }
        return [
            ff("audio.mp3", "MP3", "MP3, VBR ~190 kbps (ffmpeg)", "music.note", .audio, accepts: audioIn, ext: "mp3", same: ["mp3"],
               args: ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]),
            ff("audio.ogg", "OGG", "Opus in .ogg (ffmpeg)", "dot.radiowaves.right", .audio, accepts: audioIn, ext: "ogg", same: ["ogg"],
               args: ["-vn", "-c:a", "libopus", "-b:a", "160k"]),
            ff("audio.opusff", "Opus", "Opus, 128 kbps (ffmpeg)", "dot.radiowaves.left.and.right", .audio, accepts: audioIn, ext: "opus", same: ["opus"],
               args: ["-vn", "-c:a", "libopus", "-b:a", "128k"]),
            ff("video.webm", "WebM", "VP9 + Opus for the web (ffmpeg)", "globe", .video, accepts: video, ext: "webm", same: ["webm"],
               args: ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-c:a", "libopus"]),
            ff("video.mkv", "MKV", "Matroska (stream copy, instant)", "shippingbox", .video, accepts: video, ext: "mkv", same: ["mkv"],
               args: ["-map", "0", "-c", "copy"]),
            ff("video.avi", "AVI", "MPEG-4 AVI for old players (ffmpeg)", "opticaldisc", .video, accepts: video, ext: "avi", same: ["avi"],
               args: ["-c:v", "mpeg4", "-q:v", "3", "-c:a", "libmp3lame", "-q:a", "3"]),
            ff("video.anyto.mp4", "MP4 (ffmpeg)", "H.264 MP4 from any container, e.g. MKV/WebM/AVI", "film", .video, accepts: video, ext: "mp4", same: ["mp4"],
               args: ["-c:v", "libx264", "-crf", "20", "-preset", "medium", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]),
        ]
    }
}
