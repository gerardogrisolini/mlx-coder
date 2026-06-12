//
//  MLXPackageMetadata.swift
//  mlx-server
//

public enum MLXPackageMetadata {
    public static let packageName = "mlx-coder"
    public static let coderExecutableName = "mlx-coder"
    public static let serverExecutableName = "mlx-server"
    public static let version = "0.3.3"

    public static func versionDescription(for executableName: String) -> String {
        "\(executableName) \(version)"
    }
}
