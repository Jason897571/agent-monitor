import AgentMonitorCore
import AppKit
import ImageIO

/// A character the user supplies: a folder of animated GIFs (or APNG, or still PNGs), one
/// per pose, plus a `skin.json` saying which is which.
///
/// Skins are user data and live outside the app —
/// `~/Library/Application Support/AgentMonitor/skins/<folder>/`. That is deliberate:
/// most characters people want are somebody's intellectual property, which is fine on
/// their own machine and not fine in a public repository or a download. See docs/SKINS.md.
@MainActor
final class Skin {

    struct Manifest: Decodable {
        let name: String
        let poses: [String: PoseSpec]
    }

    /// `"working": "typing.gif"` or `"working": {"file": "typing.gif", "speed": 1.5}`.
    struct PoseSpec: Decodable {
        let file: String
        /// Playback speed multiplier.
        let speed: Double?

        init(from decoder: Decoder) throws {
            if let file = try? decoder.singleValueContainer().decode(String.self) {
                self.file = file
                self.speed = nil
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            file = try container.decode(String.self, forKey: .file)
            speed = try container.decodeIfPresent(Double.self, forKey: .speed)
        }

        enum CodingKeys: String, CodingKey { case file, speed }
    }

    let id: String
    let name: String
    let directory: URL
    private let poses: [PetPose: PoseSpec]
    /// Only the pose on screen is kept decoded; a skin with ten poses of sixty frames
    /// each would otherwise hold a hundred megabytes for animations nobody is watching.
    private var cached: (pose: PetPose, pixels: Int, animation: SkinAnimation)?
    private var stills: [PetPose: CGImage] = [:]

    init?(directory: URL) {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("skin.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return nil }
        var poses: [PetPose: PoseSpec] = [:]
        for (key, spec) in manifest.poses {
            guard let pose = PetPose(rawValue: key),
                  FileManager.default.fileExists(atPath: directory.appendingPathComponent(spec.file).path)
            else { continue }
            poses[pose] = spec
        }
        guard !poses.isEmpty else { return nil }
        self.id = directory.lastPathComponent
        self.name = manifest.name
        self.directory = directory
        self.poses = poses
    }

    /// The pose to actually play for `pose`: itself if the skin has it, otherwise the
    /// nearest relative. A skin does not have to draw all ten poses — two or three
    /// already make a working character.
    func resolve(_ pose: PetPose) -> PetPose? {
        var visited: Set<PetPose> = []
        var current: PetPose? = pose
        while let candidate = current, !visited.contains(candidate) {
            if poses[candidate] != nil { return candidate }
            visited.insert(candidate)
            current = Self.fallback[candidate]
        }
        return poses.keys.contains(.resting) ? .resting : poses.keys.first
    }

    static let fallback: [PetPose: PetPose] = [
        .digesting: .working,
        .swarming: .working,
        .working: .attentive,
        .waking: .resting,
        .done: .attentive,
        .troubled: .alert,
        .alert: .attentive,
        .attentive: .resting,
        .resting: .sleeping,
        .sleeping: .resting,
    ]

    /// The animation for `pose`, decoded at most `pixels` on its longer side.
    func animation(for pose: PetPose, pixels: Int) -> SkinAnimation? {
        guard let resolved = resolve(pose), let spec = poses[resolved] else { return nil }
        if let cached, cached.pose == resolved, cached.pixels == pixels { return cached.animation }
        guard let animation = SkinAnimation(url: directory.appendingPathComponent(spec.file),
                                            maxPixels: pixels, speed: spec.speed ?? 1) else { return nil }
        cached = (resolved, pixels, animation)
        return animation
    }

    /// How long a pose's animation runs, from frame delays alone — without decoding a
    /// single frame. Decoding a 90-frame sticker just to learn its length cost seconds of
    /// CPU at every launch.
    func duration(of pose: PetPose) -> TimeInterval? {
        guard let spec = poses[pose],
              let source = CGImageSourceCreateWithURL(directory.appendingPathComponent(spec.file) as CFURL, nil)
        else { return nil }
        let total = (0..<CGImageSourceGetCount(source)).reduce(0.0) { $0 + SkinAnimation.delay(of: source, at: $1) }
        return total / max(0.1, spec.speed ?? 1)
    }

    /// First frame only, small — for the teammates drawn around the pet.
    func still(for pose: PetPose) -> CGImage? {
        guard let resolved = resolve(pose), let spec = poses[resolved] else { return nil }
        if let still = stills[resolved] { return still }
        let still = SkinAnimation(url: directory.appendingPathComponent(spec.file), maxPixels: 96, speed: 1,
                                  firstFrameOnly: true)?.frames.first
        stills[resolved] = still
        return still
    }
}

/// One decoded animation: frames, how long each shows, and a coarse alpha mask for hit
/// testing.
struct SkinAnimation {
    let frames: [CGImage]
    /// Cumulative end time of each frame, in seconds.
    private let ends: [Double]
    let duration: Double
    let mask: AlphaMask

    init?(url: URL, maxPixels: Int, speed: Double, firstFrameOnly: Bool = false) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = firstFrameOnly ? min(1, CGImageSourceGetCount(source)) : CGImageSourceGetCount(source)
        guard count > 0 else { return nil }

        // Decoded straight to the size it is shown at: a 1080px sticker scaled down by
        // the render server every frame would cost memory and GPU for no visible gain.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        var frames: [CGImage] = []
        var ends: [Double] = []
        var total = 0.0
        for index in 0..<count {
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { continue }
            frames.append(image)
            total += Self.delay(of: source, at: index) / max(0.1, speed)
            ends.append(total)
        }
        guard !frames.isEmpty else { return nil }
        self.frames = frames
        self.ends = ends
        self.duration = total
        self.mask = AlphaMask(frames: frames)
    }

    /// Browsers treat GIF delays under 20 ms as 100 ms, and stickers are authored
    /// against that; honouring a literal 0 would play them at the display's refresh rate.
    static func delay(of source: CGImageSource, at index: Int) -> Double {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let container = (properties?[kCGImagePropertyGIFDictionary] ?? properties?[kCGImagePropertyPNGDictionary])
            as? [CFString: Any]
        let raw = (container?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
            ?? (container?[kCGImagePropertyGIFDelayTime] as? Double)
            ?? (container?[kCGImagePropertyAPNGUnclampedDelayTime] as? Double)
            ?? (container?[kCGImagePropertyAPNGDelayTime] as? Double)
            ?? 0.1
        return raw < 0.02 ? 0.1 : raw
    }

    /// Native frame rate, for asking the display link for enough frames.
    var framesPerSecond: Double { duration > 0 ? Double(frames.count) / duration : 10 }

    /// The frame to show `elapsed` seconds into the pose. `loops == false` holds the last
    /// frame — the waking animation plays once.
    func frame(at elapsed: Double, loops: Bool = true) -> CGImage {
        guard frames.count > 1, duration > 0 else { return frames[0] }
        let t = loops ? elapsed.truncatingRemainder(dividingBy: duration) : min(elapsed, duration - 0.0001)
        let index = ends.firstIndex { t < $0 } ?? frames.count - 1
        return frames[index]
    }
}

/// Where a skin is opaque, on a coarse grid, across all of an animation's frames.
///
/// The union rather than one frame, so a pet mid-wave does not become click-through where
/// its paw was a moment ago; and dilated a little, because a 2 px outline is not a
/// target anyone can hit.
struct AlphaMask {
    private let size = 48
    private var bits: [Bool]

    init(frames: [CGImage]) {
        bits = Array(repeating: false, count: size * size)
        let step = max(1, frames.count / 8)
        for frame in stride(from: 0, to: frames.count, by: step).map({ frames[$0] }) {
            guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                          bytesPerRow: size, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { continue }
            context.draw(frame, in: CGRect(x: 0, y: 0, width: size, height: size))
            guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { continue }
            for index in 0..<(size * size) where data[index] > 40 { bits[index] = true }
        }
        // One cell of dilation.
        let original = bits
        for y in 0..<size {
            for x in 0..<size where original[y * size + x] {
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = x + dx, ny = y + dy
                        if nx >= 0, ny >= 0, nx < size, ny < size { bits[ny * size + nx] = true }
                    }
                }
            }
        }
    }

    /// `point` in unit coordinates of the image, origin bottom-left.
    func contains(_ point: CGPoint) -> Bool {
        guard point.x >= 0, point.y >= 0, point.x < 1, point.y < 1 else { return false }
        // A bitmap context stores its top row first; unit coordinates start at the bottom.
        let x = Int(point.x * CGFloat(size)), row = size - 1 - Int(point.y * CGFloat(size))
        return bits[row * size + x]
    }
}

/// The installed skins.
@MainActor
enum SkinLibrary {
    static var directory: URL {
        StatuslineFeed.defaultSupportDirectory.appendingPathComponent("skins", isDirectory: true)
    }

    static func available() -> [(id: String, name: String)] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return folders.compactMap { Skin(directory: $0) }
            .map { ($0.id, $0.name) }
            .sorted { $0.name < $1.name }
    }

    static func load(id: String) -> Skin? {
        Skin(directory: directory.appendingPathComponent(id, isDirectory: true))
    }
}
