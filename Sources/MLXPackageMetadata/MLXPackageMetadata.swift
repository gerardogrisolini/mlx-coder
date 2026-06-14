//
//  MLXPackageMetadata.swift
//  mlx-coder
//

public enum MLXPackageMetadata {
    public static let packageName = "mlx-coder"
    public static let coderExecutableName = "mlx-coder"
    public static let localMLXModeName = "mlx-coder --mlx"
    public static let version = "0.3.10"

    public static func versionDescription(for executableName: String) -> String {
        "\(executableName) \(version)"
    }
}
