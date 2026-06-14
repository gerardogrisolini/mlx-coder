//
//  MLXServerSetupRunner+ModelLoading.swift
//  mlx-coder
//

import Foundation
import MLXServerCore

extension MLXServerSetupRunner {
    static func configureModelLoading(
        _ settings: MLXServerSettings
    ) throws -> MLXServerSettings {
        let loadOneModelAtATime = try promptYesNo(
            "Load only one model at a time?",
            defaultValue: settings.loadOneModelAtATime
        )
        return try settingsByUpdating(settings, loadOneModelAtATime: loadOneModelAtATime)
    }

}
