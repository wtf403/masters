import Foundation
import ParallaxKit

/// package-clip: turn a movie into a .scpak clip bundle.
///
/// Accepts flat video, or side-by-side stereo which is split into one eye, and writes
/// the colour track plus the metadata the renderer needs. Authoring is offline, so the
/// tool re-encodes rather than copying frames through.

let usage = """
package-clip - build a .scpak clip bundle from a movie

USAGE
  parallax-package-clip <input.mov> --output <clip.scpak> [options]

OPTIONS
  -o, --output <path>       Bundle directory to write. Required.
      --layout <name>       auto, left-right, top-bottom, or none. Default auto.
      --eye <name>          left or right. Which eye becomes the colour track.
                            Default left.
      --fov <degrees>       Horizontal field of view. Default 60.
      --baseline <metres>   Stereo baseline. Default 0.065.
      --near <metres>       Near plane. Default 0.25.
      --far <metres>        Far plane. Default 8.
      --clamp <fraction>    Maximum parallax as a fraction of the screen. Default 0.03.
      --distance <metres>   Recommended viewing distance. Default 0.5.
  -h, --help                Show this message.

NOTES
  Layout auto uses the frame aspect ratio. A left-right pair is about twice as wide as
  the nominal aspect and a top-bottom pair about half, which is loose enough to catch
  the usual 32:9 and 8:9 packed frames and can always be overridden.
"""

struct Options {
    var input: URL
    var output: URL
    var packaging = ClipPackagerOptions()
}

func parse(_ arguments: [String]) throws -> Options? {
    var input: URL?
    var output: URL?
    var packaging = ClipPackagerOptions()
    var layout: SideBySide.Layout?

    var index = 0
    while index < arguments.count {
        let argument = arguments[index]

        func value() throws -> String {
            index += 1
            guard index < arguments.count else {
                throw CliError.missingValue(argument)
            }
            return arguments[index]
        }

        switch argument {
        case "-h", "--help":
            return nil
        case "-o", "--output":
            output = URL(fileURLWithPath: try value())
        case "--layout":
            let raw = try value()
            guard let parsed = SideBySide.Layout(rawValue: raw) else {
                throw CliError.badValue(argument, raw)
            }
            layout = parsed
        case "--eye":
            let raw = try value()
            guard let parsed = ClipEye(rawValue: raw) else {
                throw CliError.badValue(argument, raw)
            }
            packaging.eye = parsed
        case "--fov":
            packaging.horizontalFieldOfView = try number(try value())
        case "--baseline":
            packaging.baseline = try number(try value())
        case "--near":
            packaging.nearPlane = try number(try value())
        case "--far":
            packaging.farPlane = try number(try value())
        case "--clamp":
            packaging.parallaxClamp = try number(try value())
        case "--distance":
            packaging.recommendedViewingDistance = try number(try value())
        default:
            if argument.hasPrefix("-") {
                throw CliError.unknownOption(argument)
            }
            input = URL(fileURLWithPath: argument)
        }

        index += 1
    }

    guard let input else { throw CliError.missingInput }
    guard let output else { throw CliError.missingOutput }

    // Default to auto: the packager resolves it once it has loaded the frame size.
    packaging.layout = layout ?? .auto

    var options = Options(input: input, output: output)
    options.packaging = packaging
    return options
}

func number(_ raw: String) throws -> Float {
    guard let value = Float(raw) else { throw CliError.badNumber(raw) }
    return value
}

enum CliError: Error, CustomStringConvertible {
    case missingValue(String)
    case badValue(String, String)
    case badNumber(String)
    case unknownOption(String)
    case missingInput
    case missingOutput

    var description: String {
        switch self {
        case .missingValue(let option): return "option \(option) needs a value"
        case .badValue(let option, let value): return "\(option) does not accept \(value)"
        case .badNumber(let raw): return "\(raw) is not a number"
        case .unknownOption(let option): return "unknown option \(option)"
        case .missingInput: return "no input file given"
        case .missingOutput: return "no output bundle given"
        }
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())

do {
    guard let options = try parse(arguments) else {
        print(usage)
        exit(0)
    }

    let result = try await ClipPackager.package(
        input: options.input,
        to: options.output,
        options: options.packaging
    )

    let width = Int(result.presentationSize.width)
    let height = Int(result.presentationSize.height)
    print("wrote \(options.output.path)")
    print("  layout        \(result.layout.rawValue)")
    print("  frames        \(result.frameCount)")
    print("  size          \(width)x\(height)")
    print("  codec         \(result.codec)")
    print("  baseline      \(result.metadata.baseline) m")
    print("  field of view \(result.metadata.horizontalFieldOfView) degrees")
} catch {
    FileHandle.standardError.write(Data("package-clip: \(error)\n".utf8))
    FileHandle.standardError.write(Data("try --help\n".utf8))
    exit(1)
}

