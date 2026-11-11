// What both apps, Mac and iPhone, share besides the engine: the models offered, where they are kept, the window's
// words (L), and reading sound out of a file.

import AVFoundation
import Foundation

// The English text is the key; ru and uk come from lang/, picked by macOS from the system language.
// Wording of macOS's own terms (Open at Login, Quit, Privacy & Security) is copied from its .loctable files.
func L(_ s: String) -> String { NSLocalizedString(s, comment: "") }

struct ASRModel {
    let id: String, title: String, languages: [String], file: String, revision: String, sha256: String, size: Int64
    var url: URL { URL(string: "https://huggingface.co/handy-computer/\(id)-gguf/resolve/\(revision)/\(file)")! }
    var path: URL { modelsFolder.appendingPathComponent(file) }
    var isHere: Bool { FileManager.default.fileExists(atPath: path.path) }
}

func sizeText(_ bytes: Int64) -> String {
    (bytes / 1_000_000).formatted(.number.locale(Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en"))) + " " + L("MB")
}

// The best model of each maker for dictation, named in plain words, biggest first: what a person
// sees is the name, the size and whether it is here. Language codes are the models' own general.languages.
let models: [ASRModel] = [
    ASRModel(id: "Qwen3-ASR-1.7B", title: "Qwen",
             languages: "zh en yue ar de fr es pt id it ko ru th vi ja tr hi ms nl sv da fi pl cs fil fa el ro hu mk".split(separator: " ").map(String.init),
             file: "Qwen3-ASR-1.7B-Q8_0.gguf",
             revision: "92282af1610a2db19d66f2bef1e260f5deca782d",
             sha256: "9a0d81792dfea2d5f278b8a63deb3ea6e02139ce42c2301f32ea19c4f77526b7", size: 2185030624),
    ASRModel(id: "whisper-large-v3-turbo", title: "Whisper",
             languages: "af am ar as az ba be bg bn bo br bs ca cs cy da de el en es et eu fa fi fo fr gl gu haw ha he hi hr ht hu hy id is it ja jw ka kk km kn ko la lb ln lo lt lv mg mi mk ml mn mr ms mt my ne nl nn no oc pa pl ps pt ro ru sa sd si sk sl sn so sq sr su sv sw ta te tg th tk tl tr tt uk ur uz vi yi yo yue zh".split(separator: " ").map(String.init),
             file: "whisper-large-v3-turbo-Q8_0.gguf",
             revision: "5eaf945c7978e564bae5b28a5b1639dd93c2bfb1",
             sha256: "b2e30cc286bc9f3aba4db9099fc7403543497c05ce7100d0d83091ddfd25a183", size: 886381760),
    ASRModel(id: "parakeet-ultra", title: "Parakeet",
             languages: [],   // it takes a language hint and ignores it: wrong hints changed nothing in 5 of 5 tests, it always detects
             file: "parakeet-ultra-Q8_0.gguf",
             revision: "39eeb55181f0d354fd934f06e92fd8d5037fed8e",
             sha256: "007a59761e9258779f189df396b50d12b83bb5b79e66df4b955c230d2f2a0a59", size: 740363168),
]

// ~/Library/Application Support/STT/models: plain files, easy to find and to delete by hand. It appears only with the first
// download and goes with the last delete. The name comes from the bundle so a test build keeps to its own folder.
let appFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "STT", isDirectory: true)
let modelsFolder = appFolder.appendingPathComponent("models", isDirectory: true)

// Any file AVFoundation can open, video included: the first audio track as 16 kHz mono.
func readMedia(_ url: URL) throws -> [Float] {
    let asset = AVURLAsset(url: url)
    guard let track = asset.tracks(withMediaType: .audio).first else { throw Failure.noSound }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
    ])
    reader.add(output)
    guard reader.startReading() else { throw reader.error ?? Failure.noSound }
    var samples: [Float] = []
    while let buffer = output.copyNextSampleBuffer() {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
        let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
        let start = samples.count
        samples.append(contentsOf: repeatElement(0, count: count))
        samples.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size, destination: $0.baseAddress! + start * MemoryLayout<Float>.size) }
    }
    if reader.status == .failed { throw reader.error ?? Failure.noSound }
    return samples
}

