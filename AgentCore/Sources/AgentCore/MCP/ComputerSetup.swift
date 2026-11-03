import Foundation

public enum ComputerSetup {
    public static let scriptURLBase = "https://raw.githubusercontent.com/2c2bhdhw9z-cell/MAIPA-G"
    public static let scriptSHA256 = "e3f2eb89d310046376a6cfa7ca3326581e9011b18867e9fdd1dfe43b1392a565"
    public static func scriptURL(revision: String) -> String? {
        guard revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else { return nil }
        return "\(scriptURLBase)/\(revision)/docs/computer/setup.sh"
    }
}
