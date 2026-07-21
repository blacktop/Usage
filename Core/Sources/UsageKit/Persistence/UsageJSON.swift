import Foundation

/// The one JSON configuration the app, the CLI, history, and the golden schema tests all share.
///
/// Keys are sorted so encoded bytes are stable, which is what makes a schema change a loud test
/// failure instead of a silent format drift.
public enum UsageJSON {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        JSONDecoder()
    }
}
