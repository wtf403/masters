#if os(iOS)
import Foundation

/// A clip the app can open.
public struct ClipItem: Identifiable, Hashable, Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public var id: URL { url }
    public var name: String { url.deletingPathExtension().lastPathComponent }
}

/// Finds playable clips.
///
/// Clips live in the app's Documents directory so a test clip can be dropped in
/// without a rebuild, and in the bundle so a shipped sample works on first launch.
enum ClipLibrary {
    static let playableExtensions: Set<String> = ["mov", "mp4", "m4v", "scpak"]

    static func clips(in directory: URL? = nil) -> [ClipItem] {
        var found: [ClipItem] = []

        if let bundled = Bundle.main.resourceURL {
            found += scan(bundled)
        }
        if let directory {
            found += scan(directory)
        } else if let documents = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) {
            found += scan(documents)
        }

        var seen = Set<URL>()
        return found
            .filter { seen.insert($0.url).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func scan(_ directory: URL) -> [ClipItem] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries.compactMap { url in
            guard playableExtensions.contains(url.pathExtension.lowercased()) else { return nil }
            return ClipItem(url: url)
        }
    }
}
#endif
