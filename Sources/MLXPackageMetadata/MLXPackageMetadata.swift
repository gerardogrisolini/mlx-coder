//
//  MLXPackageMetadata.swift
//  mlx-server
//

public enum MLXPackageMetadata {
    public static let packageName = "mlx-server"
    public static let serverExecutableName = "mlx-server"
    public static let coderExecutableName = "mlx-coder"
    public static let version = "0.2.6"

    public static func versionDescription(for executableName: String) -> String {
        "\(executableName) \(version)"
    }
}
