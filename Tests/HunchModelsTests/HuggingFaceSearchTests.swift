import Foundation
import Testing
@testable import HunchModels
import HunchCore

@Suite struct HuggingFaceSearchTests {
    private let hash = String(repeating: "ab", count: 32)

    @Test func searchURL() {
        let url = HuggingFaceSearch.searchURL(query: "  qwen3 1.7b ")
        #expect(url?.host == "huggingface.co")
        #expect(url?.path == "/api/models")
        let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.contains(URLQueryItem(name: "search", value: "qwen3 1.7b")))
        #expect(items.contains(URLQueryItem(name: "filter", value: "gguf")))
        #expect(HuggingFaceSearch.searchURL(query: "   ") == nil)
    }

    @Test func treeURLRejectsUnsafeRepos() {
        #expect(HuggingFaceSearch.treeURL(repo: "owner/name")?.path == "/api/models/owner/name/tree/main")
        #expect(HuggingFaceSearch.treeURL(repo: "owner/../x") == nil)
        #expect(HuggingFaceSearch.treeURL(repo: "justname") == nil)
        #expect(HuggingFaceSearch.treeURL(repo: "../name") == nil)
    }

    @Test func reposKeepTextModelsOnly() throws {
        let json = """
        [{"id":"a/speech","downloads":9,"likes":1,"pipeline_tag":"automatic-speech-recognition"},
         {"id":"b/text","downloads":5,"likes":2,"pipeline_tag":"text-generation"},
         {"id":"c/untagged"},
         {"id":"d/vision","pipeline_tag":"image-text-to-text","likes":3}]
        """
        let repos = try HuggingFaceSearch.repos(from: Data(json.utf8))
        #expect(repos.map(\.id) == ["b/text", "c/untagged", "d/vision"])
        #expect(repos[0].downloads == 5 && repos[0].likes == 2)
        #expect(repos[1].downloads == 0)
    }

    @Test func filesKeepTopLevelSingleGGUFs() throws {
        let json = """
        [{"type":"file","path":".gitattributes","size":10},
         {"type":"file","path":"big.Q8_0.gguf","size":900,"lfs":{"oid":"\(hash)","size":900}},
         {"type":"file","path":"small-Q4_K_M.gguf","size":300,"lfs":{"oid":"\(hash.uppercased())","size":300}},
         {"type":"file","path":"nolfs.gguf","size":5},
         {"type":"file","path":"mmproj-f16.gguf","size":50,"lfs":{"oid":"\(hash)","size":50}},
         {"type":"file","path":"m-Q4_K_M-00001-of-00002.gguf","size":50,"lfs":{"oid":"\(hash)","size":50}},
         {"type":"file","path":"Q4/inside.gguf","size":50,"lfs":{"oid":"\(hash)","size":50}},
         {"type":"directory","path":"Q4"},
         {"type":"file","path":"badhash.gguf","size":50,"lfs":{"oid":"xyz","size":50}},
         {"type":"file","path":"readme.md","size":50,"lfs":{"oid":"\(hash)","size":50}}]
        """
        let files = try HuggingFaceSearch.files(from: Data(json.utf8))
        #expect(files.map(\.fileName) == ["small-Q4_K_M.gguf", "big.Q8_0.gguf"])
        #expect(files[0].sha256 == hash)
        #expect(files[0].byteSize == 300)
    }

    @Test func badJSONThrows() {
        #expect(throws: (any Error).self) { try HuggingFaceSearch.files(from: Data("{".utf8)) }
    }

    @Test func quantizationFromFileName() {
        func q(_ name: String) -> String? { HFFile(fileName: name, byteSize: 1, sha256: "").quantization }
        #expect(q("Qwen3-1.7B.i1-Q4_K_M.gguf") == "Q4_K_M")
        #expect(q("model-q8_0.gguf") == "Q8_0")
        #expect(q("gemma.IQ2_XS.gguf") == "IQ2_XS")
        #expect(q("llama-f16.gguf") == "F16")
        #expect(q("plain.gguf") == nil)
    }

    @Test func pickedModelGoesToItsCategory() {
        let file = HFFile(fileName: "Some-Model.Q4_K_M.gguf", byteSize: 42, sha256: hash)
        let writing = CatalogModel.huggingFace(repo: "owner/repo", file: file, use: .writing)
        #expect(writing.use == .writing)
        #expect(writing.displayName == "Some-Model.Q4_K_M")
        #expect(writing.quantization == "Q4_K_M")
        #expect(DownloadPlan.url(for: writing)?.path == "/owner/repo/resolve/main/Some-Model.Q4_K_M.gguf")
        #expect(CatalogModel.huggingFace(repo: "owner/repo", file: file, use: .autocomplete).use == .autocomplete)
    }
}
