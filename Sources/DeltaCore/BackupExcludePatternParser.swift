import Foundation

public enum BackupExcludePatternParser {
    public static func parse(_ text: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",\n\r")
        let patterns = text
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return unique(patterns)
    }

    public static func customPatterns(from patterns: [String]) -> [String] {
        let defaultPatterns = Set(BackupExcludePolicy.defaultMacOSExcludes)
        return unique(patterns.filter { !defaultPatterns.contains($0) })
    }

    public static func displayText(for patterns: [String]) -> String {
        customPatterns(from: patterns).joined(separator: "\n")
    }

    public static func mergingDefaults(with customPatterns: [String]) -> [String] {
        unique(BackupExcludePolicy.defaultMacOSExcludes + customPatterns)
    }

    private static func unique(_ patterns: [String]) -> [String] {
        var seenPatterns = Set<String>()
        return patterns.filter { pattern in
            seenPatterns.insert(pattern).inserted
        }
    }
}
