import Foundation
import ParallaxKit

/// build-depth: derive a depth track from a side-by-side stereo movie.
///
/// See DepthBuilder for what the matcher does and, more importantly, what it does not
/// do. The printed confidence is the honest headline number: it is the fraction of
/// pixels that produced a match the cost threshold accepted.

let usage = """
build-depth - derive a depth track from a side-by-side stereo movie

USAGE
  parallax-build-depth <stereo.mov> --output <clip.scpak> [options]

OPTIONS
  -o, --output <path>       Bundle directory to write depth into. Required.
      --layout <name>       left-right or top-bottom. Default left-right.
      --downsample <n>      Match at 1/n resolution. Default 4.
      --block <n>           Matching window half-width in samples. Default 1.
      --max-disparity <f>   Search range as a fraction of the eye width. Default 0.04.
      --threshold <f>       Normalised cost above which a match is rejected. Default 0.16.
      --track <name>        Depth track file name. Default depth.mov.
  -h, --help                Show this message.

NOTES
  Depth is written as a greyscale movie at the eye size, where white is near. If the
  bundle already has metadata, its depthTrack field is updated in place.

  This is a CPU block matcher: no sub-pixel refinement, no left-right consistency, no
  semi-global pass. Expect holes on textureless and reflective surfaces. The point of
  this pass is to produce a measurable depth signal and to report how reliable it is.
"""

struct Options {
    var input: URL
    var output: URL
    var depth = DepthBuilderOptions()
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

func parse(_ arguments: [String]) throws -> Options? {
    var input: URL?
    var output: URL?
    var depth = DepthBuilderOptions()

    var index = 0
    while index < arguments.count {
        let argument = arguments[index]

        func value() throws -> String {
            index += 1
            guard index < arguments.count else { throw CliError.missingValue(argument) }
            return arguments[index]
        }

        func number() throws -> Float {
            let raw = try value()
            guard let parsed = Float(raw) else { throw CliError.badNumber(raw) }
            return parsed
        }

        switch argument {
        case "-h", "--help":
            return nil
        case "-o", "--output":
            output = URL(fileURLWithPath: try value())
        case "--layout":
            let raw = try value()
            guard let parsed = SideBySide.Layout(rawValue: raw), parsed != .none else {
                throw CliError.badValue(argument, raw)
            }
            depth.layout = parsed
        case "--downsample":
            depth.downsample = Int(try number())
        case "--block":
            depth.blockRadius = Int(try number())
        case "--max-disparity":
            depth.maxDisparityFraction = try number()
        case "--threshold":
            depth.matchThreshold = try number()
        case "--track":
            depth.depthTrackName = try value()
        default:
            if argument.hasPrefix("-") { throw CliError.unknownOption(argument) }
            input = URL(fileURLWithPath: argument)
        }

        index += 1
    }

    guard let input else { throw CliError.missingInput }
    guard let output else { throw CliError.missingOutput }
    return Options(input: input, output: output, depth: depth)
}

let arguments = Array(CommandLine.arguments.dropFirst())

do {
    guard let options = try parse(arguments) else {
        print(usage)
        exit(0)
    }

    let result = try await DepthBuilder.build(
        fromStereoMovieAt: options.input,
        to: options.output,
        options: options.depth
    )

    let width = Int(result.size.width)
    let height = Int(result.size.height)
    let percent = String(format: "%.1f", result.averageConfidence * 100)
    print("wrote \(options.output.appendingPathComponent(options.depth.depthTrackName).path)")
    print("  frames      \(result.frameCount)")
    print("  size        \(width)x\(height)")
    print("  confidence  \(percent)% of pixels matched")
    if result.averageConfidence < 0.4 {
        print("  warning: most pixels had no confident match; treat this depth track as experimental")
    }
} catch {
    FileHandle.standardError.write(Data("build-depth: \(error)\n".utf8))
    FileHandle.standardError.write(Data("try --help\n".utf8))
    exit(1)
}

