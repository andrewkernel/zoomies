import Foundation
import Testing
@testable import ZoomiesKit

@Suite struct SplitModelTests {
    func part(_ i: Int, of n: Int, tensors: [(String, [UInt64])]) -> Data {
        var b = i == 1 ? GGUFBuilder.tinyLlama() : GGUFBuilder()
        if i == 1 { b.tensors.removeAll() }
        b.u32("split.count", UInt32(n))
        b.u32("split.no", UInt32(i - 1))
        for (name, dims) in tensors { b.tensor(name, dims, type: 0) }
        return b.build()
    }

    @Test func allPartsAreCounted() throws {
        let dir = tempDir()
        try part(1, of: 2, tensors: [("a", [64, 100])]).write(to: dir.appendingPathComponent("m-00001-of-00002.gguf"))
        try part(2, of: 2, tensors: [("b", [64, 300])]).write(to: dir.appendingPathComponent("m-00002-of-00002.gguf"))
        let one = try ModelInspector.inspect(dir.appendingPathComponent("m-00001-of-00002.gguf"))
        #expect(one.splitCount == 2)
        #expect(one.parameterCount == 64 * 400)     // both parts, not just the first
        #expect(one.weightBytes == 64 * 400 * 4)    // F32
        #expect(one.name == "Tiny Test Llama")
    }

    @Test func missingPartIsAnError() throws {
        let dir = tempDir()
        try part(1, of: 3, tensors: [("a", [64, 100])]).write(to: dir.appendingPathComponent("m-00001-of-00003.gguf"))
        #expect(throws: GGUFError.self) { try ModelInspector.inspect(dir.appendingPathComponent("m-00001-of-00003.gguf")) }
    }
}

@Suite struct ModelLibraryTests {
    @Test func findsModelsAcrossFoldersAndOllama() throws {
        let home = tempDir()
        let fm = FileManager.default
        let models = home.appendingPathComponent("Models/sub")
        try fm.createDirectory(at: models, withIntermediateDirectories: true)
        let big = Data(count: 2 << 20)
        try big.write(to: models.appendingPathComponent("qwen-7b-q4_k_m.gguf"))
        try big.write(to: models.appendingPathComponent("big-00001-of-00002.gguf"))
        try big.write(to: models.appendingPathComponent("big-00002-of-00002.gguf"))   // skipped: not loadable alone
        try big.write(to: models.appendingPathComponent("mmproj-qwen-vl.gguf"))       // skipped: vision projector
        try Data(count: 10).write(to: models.appendingPathComponent("tiny.gguf"))     // skipped: not a real model

        // Ollama: manifest -> blob
        let blobs = home.appendingPathComponent(".ollama/models/blobs")
        let manifestDir = home.appendingPathComponent(".ollama/models/manifests/registry.ollama.ai/library/llama3.2")
        try fm.createDirectory(at: blobs, withIntermediateDirectories: true)
        try fm.createDirectory(at: manifestDir, withIntermediateDirectories: true)
        try big.write(to: blobs.appendingPathComponent("sha256-abc123"))
        try #"{"layers":[{"mediaType":"application/vnd.ollama.image.model","digest":"sha256:abc123","size":2097152}]}"#
            .write(to: manifestDir.appendingPathComponent("3b"), atomically: true, encoding: .utf8)

        let found = ModelLibrary.scan(home: home)
        #expect(Set(found.map(\.displayName)) == ["big-00001-of-00002", "llama3.2:3b", "qwen-7b-q4_k_m"])
        #expect(found.first { $0.displayName == "big-00001-of-00002" }?.splitParts == 2)
        #expect(found.first { $0.source == "Ollama" }?.url.lastPathComponent == "sha256-abc123")
    }
}
