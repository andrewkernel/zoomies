import Foundation

/// A GGUF model found on disk. Zoomies references model files where they are;
/// it never copies, moves or modifies them.
public struct LibraryModel: Identifiable, Sendable, Hashable, Codable {
    public var id: String { url.path }
    public var url: URL
    public var displayName: String
    /// Where it was found: "Folder", "Ollama", "LM Studio", "llama.cpp cache", "Hugging Face cache".
    public var source: String
    public var sizeBytes: UInt64
    public var splitParts: Int?
}

/// Finds models in the usual places, including ones other apps downloaded.
public enum ModelLibrary {
    public static func defaultFolders(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [(URL, String)] {
        [
            (home.appendingPathComponent("Models"), "Folder"),
            (home.appendingPathComponent("models"), "Folder"),
            (home.appendingPathComponent(".lmstudio/models"), "LM Studio"),
            (home.appendingPathComponent(".cache/lm-studio/models"), "LM Studio"),
            (home.appendingPathComponent("Library/Caches/llama.cpp"), "llama.cpp cache"),
            (home.appendingPathComponent(".cache/llama.cpp"), "llama.cpp cache"),
            (home.appendingPathComponent(".cache/huggingface/hub"), "Hugging Face cache"),
        ]
    }

    public static func scan(extraFolders: [URL] = [], home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [LibraryModel] {
        var out: [LibraryModel] = []
        var seen = Set<String>()
        let folders = defaultFolders(home: home) + extraFolders.map { ($0, "Folder") }
        for (dir, source) in folders {
            for m in scanFolder(dir, source: source) where seen.insert(m.url.resolvingSymlinksInPath().path).inserted {
                out.append(m)
            }
        }
        for m in ollamaModels(home: home) where seen.insert(m.url.resolvingSymlinksInPath().path).inserted {
            out.append(m)
        }
        return out.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// GGUF files up to 5 levels deep. Vision projectors (mmproj) and parts
    /// 2..N of split models are skipped: they are not loadable on their own.
    static func scanFolder(_ dir: URL, source: String) -> [LibraryModel] {
        let fm = FileManager.default
        guard let it = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [LibraryModel] = []
        for case let url as URL in it {
            if it.level > 5 { it.skipDescendants(); continue }
            let name = url.lastPathComponent
            guard name.lowercased().hasSuffix(".gguf"), !name.lowercased().contains("mmproj") else { continue }
            var parts: Int?
            if let r = name.range(of: #"-(\d{5})-of-(\d{5})\.gguf$"#, options: .regularExpression) {
                let tail = name[r].dropFirst()  // "00001-of-00003.gguf"
                guard tail.hasPrefix("00001") else { continue }
                parts = Int(tail.dropFirst(9).prefix(5))
            }
            let resolved = url.resolvingSymlinksInPath()
            let size = (try? resolved.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { UInt64($0) } ?? 0
            guard size > 1 << 20 else { continue }
            out.append(LibraryModel(url: url, displayName: (name as NSString).deletingPathExtension, source: source,
                                    sizeBytes: size, splitParts: parts))
        }
        return out
    }

    /// Ollama stores GGUF weights as content-addressed blobs; its manifests map
    /// "name:tag" to the blob. `OLLAMA_MODELS` overrides the location.
    static func ollamaModels(home: URL) -> [LibraryModel] {
        let root = ProcessInfo.processInfo.environment["OLLAMA_MODELS"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".ollama/models")
        let manifests = root.appendingPathComponent("manifests")
        let fm = FileManager.default
        guard let it = fm.enumerator(at: manifests, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out: [LibraryModel] = []
        for case let url as URL in it {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let layers = obj["layers"] as? [[String: Any]],
                  let model = layers.first(where: { ($0["mediaType"] as? String) == "application/vnd.ollama.image.model" }),
                  let digest = model["digest"] as? String else { continue }
            let blob = root.appendingPathComponent("blobs").appendingPathComponent(digest.replacingOccurrences(of: ":", with: "-"))
            guard fm.fileExists(atPath: blob.path) else { continue }
            // manifests/<registry>/<namespace>/<model>/<tag>
            let comps = url.pathComponents
            let name = comps.count >= 2 ? "\(comps[comps.count - 2]):\(comps[comps.count - 1])" : url.lastPathComponent
            let size = (model["size"] as? NSNumber)?.uint64Value
                ?? (try? fm.attributesOfItem(atPath: blob.path)[.size] as? UInt64) ?? 0
            out.append(LibraryModel(url: blob, displayName: name, source: "Ollama", sizeBytes: size, splitParts: nil))
        }
        return out
    }
}
