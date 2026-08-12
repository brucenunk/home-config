import AVFoundation
import Foundation

// Ownership boundary:
// - This helper owns only macOS microphone permission and WAV capture.
// - It writes one caller-provided audio file, writes a ready file once capture
//   has actually started, stops when maxDuration elapses or the caller-created
//   stop file appears, then exits.
// - It does not know about Pi sessions, transcripts, editor state, model config,
//   API keys, or network transcription.

func fail(_ message: String, _ code: Int32 = 1) -> Never {
    if let data = (message + "\n").data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
    exit(code)
}

let usage = """
usage: josip --output <output.wav> --max-duration <seconds> --stop-file <path> --ready-file <path>
"""

struct Options {
    var outputPath: String?
    var maxDuration: Double?
    var stopFilePath: String?
    var readyFilePath: String?
}

func parseOptions(_ args: [String]) -> Options {
    var options = Options()
    var index = 1

    while index < args.count {
        let arg = args[index]
        if arg == "--help" || arg == "-h" {
            print(usage, terminator: "")
            exit(0)
        }

        guard index + 1 < args.count else {
            fail("missing value for \(arg)\n\(usage)", 64)
        }
        let value = args[index + 1]

        switch arg {
        case "--output":
            options.outputPath = value
        case "--max-duration":
            guard let duration = Double(value) else {
                fail("--max-duration must be a number", 64)
            }
            options.maxDuration = duration
        case "--stop-file":
            options.stopFilePath = value
        case "--ready-file":
            options.readyFilePath = value
        default:
            fail("unknown option: \(arg)\n\(usage)", 64)
        }

        index += 2
    }

    return options
}

let options = parseOptions(CommandLine.arguments)

guard let outputPath = options.outputPath,
      let requestedDuration = options.maxDuration,
      let stopFilePath = options.stopFilePath,
      let readyFilePath = options.readyFilePath else {
    fail(usage, 64)
}

let outputURL = URL(fileURLWithPath: outputPath)
let hardMaxDuration = 90.0

if requestedDuration <= 0 || requestedDuration > hardMaxDuration {
    fail("--max-duration must be greater than 0 and no more than \(Int(hardMaxDuration))", 64)
}
let maxDuration = requestedDuration

let permissionSemaphore = DispatchSemaphore(value: 0)
var permissionGranted = false
var permissionResolved = false

AVCaptureDevice.requestAccess(for: .audio) { granted in
    permissionGranted = granted
    permissionResolved = true
    permissionSemaphore.signal()
}

let permissionDeadline = Date().addingTimeInterval(30)
while !permissionResolved && Date() < permissionDeadline {
    if FileManager.default.fileExists(atPath: stopFilePath) {
        exit(130)
    }
    _ = permissionSemaphore.wait(timeout: .now() + 0.1)
}

if !permissionResolved {
    fail("timed out waiting for microphone permission", 13)
}

if !permissionGranted {
    fail("microphone permission was denied", 13)
}

let settings: [String: Any] = [
    AVFormatIDKey: Int(kAudioFormatLinearPCM),
    AVSampleRateKey: 16000.0,
    AVNumberOfChannelsKey: 1,
    AVLinearPCMBitDepthKey: 16,
    AVLinearPCMIsFloatKey: false,
    AVLinearPCMIsBigEndianKey: false
]

do {
    let recorder = try AVAudioRecorder(url: outputURL, settings: settings)
    recorder.prepareToRecord()

    if !recorder.record() {
        fail("failed to start recording", 1)
    }

    FileManager.default.createFile(atPath: readyFilePath, contents: Data(), attributes: nil)

    let deadline = Date().addingTimeInterval(maxDuration)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: stopFilePath) {
            break
        }
        Thread.sleep(forTimeInterval: 0.05)
    }

    recorder.stop()
} catch {
    fail("recording failed: \(error)", 1)
}
