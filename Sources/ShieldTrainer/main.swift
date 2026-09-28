import Foundation
import CreateML
import CoreML
import NaturalLanguage
import ShieldCore

// Trains Tier 1: a Core ML text classifier that runs locally on every draft.
//
// Two sources, deliberately. A public toxicity corpus teaches explicit abuse
// at scale; a curated set teaches the things that corpus cannot — relational
// aggression with no flagged words, blunt-but-fine disagreement, and the
// writer's own pain, which must never read as outward harm.
//
//   Tools/train.sh          downloads the corpus and runs this
//   build/ShieldTier1.mlmodelc   is what the app loads

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let dataDir = root.appendingPathComponent("data")
let buildDir = root.appendingPathComponent("build")
let corpusURL = dataDir.appendingPathComponent("labeled_data.csv")

func log(_ s: String) { print("  \(s)") }

// MARK: - A CSV reader that survives quoted fields and embedded newlines.

func parseCSV(_ text: String) -> [[String]] {
    var rows: [[String]] = []
    var field = ""
    var row: [String] = []
    var inQuotes = false
    var iterator = text.makeIterator()
    var pending: Character? = nil

    while let c = pending ?? iterator.next() {
        pending = nil
        if inQuotes {
            if c == "\"" {
                if let next = iterator.next() {
                    if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                } else { inQuotes = false }
            } else { field.append(c) }
        } else {
            switch c {
            case "\"": inQuotes = true
            case ",": row.append(field); field = ""
            case "\n": row.append(field); field = ""; rows.append(row); row = []
            case "\r": break
            default: field.append(c)
            }
        }
    }
    if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
    return rows
}

// MARK: - Cleaning

let urlPattern = try! NSRegularExpression(pattern: "https?://\\S+")
let mentionPattern = try! NSRegularExpression(pattern: "@\\w+")
let entityPattern = try! NSRegularExpression(pattern: "&[a-z]+;|&#\\d+;")

func clean(_ raw: String) -> String {
    var s = raw
    for p in [urlPattern, mentionPattern, entityPattern] {
        s = p.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
    }
    s = s.replacingOccurrences(of: "RT ", with: " ")
    // Inference normalises the same way, so training must too.
    return Normalizer.normalize(s).plain.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Load

print("\nShield Tier 1 trainer")

var texts: [String] = []
var labels: [String] = []

if FileManager.default.fileExists(atPath: corpusURL.path),
   let raw = try? String(contentsOf: corpusURL, encoding: .utf8) {
    let rows = parseCSV(raw)
    guard let header = rows.first else { fatalError("empty corpus") }
    let classIdx = header.firstIndex(of: "class") ?? 5
    let tweetIdx = header.firstIndex(of: "tweet") ?? 6

    var harmful: [String] = []
    var ok: [String] = []
    for row in rows.dropFirst() where row.count > max(classIdx, tweetIdx) {
        let text = clean(row[tweetIdx])
        guard text.split(separator: " ").count >= 3, text.count <= 300 else { continue }
        switch row[classIdx] {
        case "0", "1": harmful.append(text)   // hate speech, offensive language
        case "2": ok.append(text)             // neither
        default: break
        }
    }
    // The corpus is ~77% offensive; left alone the model simply votes harmful.
    harmful.shuffle(); ok.shuffle()
    let n = min(harmful.count, max(ok.count * 2, 2000))
    texts += harmful.prefix(n); labels += Array(repeating: "harmful", count: min(n, harmful.count))
    texts += ok; labels += Array(repeating: "ok", count: ok.count)
    log("corpus: \(min(n, harmful.count)) harmful, \(ok.count) ok")
} else {
    log("no corpus at data/labeled_data.csv — training on curated rows only")
}

// MARK: - Curated rows

struct Augment: Decodable {
    struct Row: Decodable { var text: String; var label: String }
    var rows: [Row]
}

let augURL = root.appendingPathComponent("Sources/ShieldCore/Resources/train-augment.json")
if let data = try? Data(contentsOf: augURL),
   let aug = try? JSONDecoder().decode(Augment.self, from: data) {
    // Repeated so a thousand curated rows are not drowned by ten thousand tweets.
    let repeats = texts.isEmpty ? 1 : 6
    for _ in 0..<repeats {
        for r in aug.rows {
            texts.append(Normalizer.normalize(r.text).plain)
            labels.append(r.label)
        }
    }
    log("curated: \(aug.rows.count) rows × \(repeats)")
} else {
    log("no curated rows found at \(augURL.lastPathComponent)")
}

guard texts.count > 100 else { fatalError("not enough training data") }

// MARK: - Split and train

var indices = Array(texts.indices)
indices.shuffle()
let cut = Int(Double(indices.count) * 0.85)
let trainIdx = indices[..<cut]
let testIdx = indices[cut...]

let trainTable = try MLDataTable(dictionary: [
    "text": trainIdx.map { texts[$0] },
    "label": trainIdx.map { labels[$0] },
])
let testTable = try MLDataTable(dictionary: [
    "text": testIdx.map { texts[$0] },
    "label": testIdx.map { labels[$0] },
])

log("training on \(trainIdx.count) rows, holding out \(testIdx.count)")

let classifier = try MLTextClassifier(trainingData: trainTable,
                                      textColumn: "text",
                                      labelColumn: "label")

let evaluation = classifier.evaluation(on: testTable, textColumn: "text", labelColumn: "label")
let accuracy = (1.0 - evaluation.classificationError) * 100
log(String(format: "held-out accuracy: %.1f%%", accuracy))

// MARK: - Write

try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
let modelURL = buildDir.appendingPathComponent("ShieldTier1.mlmodel")
try? FileManager.default.removeItem(at: modelURL)
try classifier.write(to: modelURL)

// coremlcompiler ships with Xcode, which this machine does not have. CoreML
// exposes the same compiler at runtime, so compile it here.
let compiled = try MLModel.compileModel(at: modelURL)
let dest = buildDir.appendingPathComponent("ShieldTier1.mlmodelc")
try? FileManager.default.removeItem(at: dest)
try FileManager.default.moveItem(at: compiled, to: dest)

log("wrote \(dest.path)")

// MARK: - A quick look at what it learned

let probes = [
    "you are a worthless pathetic loser",
    "nobody asked",
    "this is really good for someone like you",
    "i really do not agree with this at all",
    "thanks so much for covering for me today",
    "i hate myself and i feel worthless",
]
if let ml = try? MLModel(contentsOf: dest),
   let nl = try? NLModel(mlModel: ml) {
    print("\n  probes")
    for p in probes {
        let h = nl.predictedLabelHypotheses(for: Normalizer.normalize(p).plain, maximumCount: 2)
        print(String(format: "    %.2f  %@", h["harmful"] ?? 0, p))
    }
}
print("")
