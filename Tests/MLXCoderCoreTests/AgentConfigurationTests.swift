import Foundation
@testable import MLXCoderCore
import Testing

@Suite
struct AgentConfigurationTests {
    @Test
    func toolSelectionKeysKeepCoreAndFeaturePackagesDistinct() throws {
        let items = TerminalChat.toolSelectionItems(
            featureStatuses: [
                featureStatus(
                    id: "mlx-search-tools",
                    source: .bundled,
                    tools: ["search.glob", "search.grep"]
                ),
                featureStatus(
                    id: "mlx-git-tools",
                    source: .bundled,
                    tools: ["git.status"]
                )
            ]
        )

        let selectedKeys = try TerminalChat.parseToolSelection(
            "shell files text search git",
            items: items
        )
        let allowedToolNames = TerminalToolSelectionCatalog.allowedToolNames(
            for: selectedKeys,
            items: items
        )

        #expect(allowedToolNames.contains("local.exec"))
        #expect(allowedToolNames.contains("local.readFile"))
        #expect(allowedToolNames.contains("text.wc"))
        #expect(!allowedToolNames.contains("feature.list"))
        #expect(allowedToolNames.contains("search.grep"))
        #expect(allowedToolNames.contains("git.status"))
    }

    @Test
    func defaultAgentProfilesEnableCoreAndFeaturePackageTools() {
        let profile = AgentProfile(
            id: "default",
            name: "Default",
            tools: AgentProfileStore.defaultToolNames
        )
        let allowedToolNames = profile.allowedToolNames()

        #expect(allowedToolNames.contains("local.exec"))
        #expect(allowedToolNames.contains("local.readFile"))
        #expect(allowedToolNames.contains("search.grep"))
        #expect(allowedToolNames.contains("text.wc"))
        #expect(!allowedToolNames.contains("feature.list"))
    }

    @Test
    func groupedModelTitlesOmitRedundantProviderFallback() throws {
        let providerID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let fallbackTitleModel = AgentSettingsModelManifestFactory.remoteAPIModel(
            title: nil,
            modelID: "mlx-community/qwen3",
            providerID: providerID,
            providerName: "mlx-server",
            baseURL: "http://127.0.0.1:8080/v1",
            chatEndpoint: .responses,
            configuredContextWindowLimit: nil,
            generationParameterOverrides: nil,
            thinkingSupport: nil
        )
        let titledModel = AgentSettingsModelManifestFactory.remoteAPIModel(
            title: "Qwen3 Local",
            modelID: "mlx-community/qwen3-local",
            providerID: providerID,
            providerName: "mlx-server",
            baseURL: "http://127.0.0.1:8080/v1",
            chatEndpoint: .responses,
            configuredContextWindowLimit: nil,
            generationParameterOverrides: nil,
            thinkingSupport: nil
        )

        let group = try #require(
            AgentModelCatalogPresentation.groupedByProvider([fallbackTitleModel, titledModel])
                .first { $0.title == "mlx-server" }
        )

        #expect(fallbackTitleModel.displayTitle == "mlx-server - mlx-community/qwen3")
        #expect(AgentModelCatalogPresentation.modelTitle(for: fallbackTitleModel) == "mlx-community/qwen3")
        #expect(AgentModelCatalogPresentation.modelTitle(for: fallbackTitleModel, in: group) == "mlx-community/qwen3")
        #expect(AgentModelCatalogPresentation.modelTitle(for: titledModel, in: group) == "Qwen3 Local")
    }

    @Test
    func defaultAgentProfilesUseFocusedToolSelections() throws {
        let profiles = Dictionary(
            uniqueKeysWithValues: AgentProfileStore.defaultProfiles().map { ($0.name, $0) }
        )
        let xcodeKey = TerminalToolSelectionCatalog.featurePackageKey(id: "mlx-xcode-tools")
        let figmaKey = TerminalToolSelectionCatalog.featurePackageKey(id: "mlx-figma-tools")
        let webKey = TerminalToolSelectionCatalog.featurePackageKey(id: "mlx-web-tools")
        let featureBuilderKey = TerminalToolSelectionCatalog.featureBuilderKey
        let defaultProfile = try #require(profiles["Default"])
        let bugfixProfile = try #require(profiles["Bugfix"])
        let builderProfile = try #require(profiles["Builder"])
        let featureProfile = try #require(profiles["Feature"])
        let reviewProfile = try #require(profiles["Review"])
        let researchProfile = try #require(profiles["Research"])
        let refactorProfile = try #require(profiles["Refactor"])

        for profile in profiles.values {
            #expect(!profile.tools.contains(xcodeKey))
            #expect(!profile.tools.contains(figmaKey))
            #expect(profile.tools.contains("files"))
            #expect(profile.tools.contains("text"))
            #expect(profile.tools.contains("memory"))
        }

        for profile in profiles.values {
            #expect(!profile.tools.contains(featureBuilderKey))
        }

        #expect(defaultProfile.tools.contains(webKey))
        #expect(builderProfile.tools.contains(webKey))
        #expect(featureProfile.tools.contains(webKey))
        #expect(researchProfile.tools.contains(webKey))
        #expect(!bugfixProfile.tools.contains(webKey))
        #expect(!reviewProfile.tools.contains(webKey))
        #expect(!refactorProfile.tools.contains(webKey))
    }

    @Test
    func agentSelectionDetailsExplainProfileDifferences() throws {
        let profiles = Dictionary(
            uniqueKeysWithValues: AgentProfileStore.defaultProfiles().map { ($0.name, $0) }
        )

        #expect(TerminalChat.agentSelectionDetail(try #require(profiles["Default"])).contains("General coding"))
        #expect(TerminalChat.agentSelectionDetail(try #require(profiles["Bugfix"])).contains("Focused bug fixes"))
        #expect(TerminalChat.agentSelectionDetail(try #require(profiles["Builder"])).contains("Create, build"))
        #expect(TerminalChat.agentSelectionDetail(try #require(profiles["Feature"])).contains("Build complete product features"))
        #expect(TerminalChat.agentSelectionDetail(try #require(profiles["Review"])).contains("Code review only"))
        #expect(TerminalChat.agentSelectionDetail(try #require(profiles["Research"])).contains("Research"))
        #expect(TerminalChat.agentSelectionDetail(try #require(profiles["Refactor"])).contains("Behavior-preserving"))

        let customAgent = AgentProfile(
            id: "custom",
            name: "Custom",
            tools: [
                "shell",
                TerminalToolSelectionCatalog.featurePackageKey(id: "mlx-git-tools"),
                "custom.tool"
            ],
            modelID: "mlx-community/custom"
        )
        let customDetail = TerminalChat.agentSelectionDetail(customAgent)

        #expect(customDetail.contains("Tools: shell, git, 1 custom"))
        #expect(customDetail.contains("model: mlx-community/custom"))
        #expect(!customDetail.contains("feature:mlx-git-tools"))
    }

    @Test
    func toolSelectionCatalogListsBundledAndGeneratedFeaturePackagesTogether() throws {
        let items = TerminalChat.toolSelectionItems(
            featureStatuses: [
                featureStatus(
                    id: "mlx-git-tools",
                    source: .bundled,
                    tools: ["git.status", "git.log"]
                ),
                featureStatus(
                    id: "live-git-branch",
                    displayName: "Live Git Branch",
                    source: .generated,
                    tools: ["live.git_current_branch"]
                )
            ]
        )

        #expect(!items.map(\.title).contains("Feature Builder"))
        #expect(items.map(\.title).contains("Git"))
        #expect(items.map(\.title).contains("Live Git Branch"))

        let selectedKeys = try TerminalChat.parseToolSelection(
            "git live-git-branch",
            items: items
        )
        let allowedToolNames = TerminalToolSelectionCatalog.allowedToolNames(
            for: selectedKeys,
            items: items
        )

        #expect(selectedKeys.contains(TerminalToolSelectionCatalog.featurePackageKey(id: "mlx-git-tools")))
        #expect(selectedKeys.contains(TerminalToolSelectionCatalog.featurePackageKey(id: "live-git-branch")))
        #expect(allowedToolNames.contains("git.status"))
        #expect(allowedToolNames.contains("live.git_current_branch"))
    }

    @Test
    func featureBuilderIsIntrinsicToBuilderAgentAndNotSelectable() throws {
        let items = TerminalChat.toolSelectionItems(
            featureStatuses: [
                featureStatus(
                    id: "mlx-web-tools",
                    source: .bundled,
                    tools: ["web.search"]
                ),
                featureStatus(
                    id: "generated-clock",
                    source: .generated,
                    tools: ["clock.now"]
                )
            ]
        )

        do {
            _ = try TerminalChat.parseToolSelection("feature-builder", items: items)
            Issue.record("Expected feature-builder to be unavailable in /tools.")
        } catch TerminalToolSelectionError.unknownToken(let token) {
            #expect(token == "feature-builder")
        } catch {
            Issue.record("Expected unknown token error, got \(error).")
        }

        let builderAgent = AgentProfile(
            id: AgentProfileStore.builderAgentID.uuidString,
            name: AgentProfileStore.builderAgentName,
            tools: []
        )
        let customAgent = AgentProfile(
            id: "custom",
            name: "Custom",
            tools: ["feature.list", "feature-builder"]
        )
        let builderAllowedToolNames = builderAgent.allowedToolNames()
        let customAllowedToolNames = customAgent.allowedToolNames()

        #expect(builderAllowedToolNames.contains("feature.list"))
        #expect(builderAllowedToolNames.contains("feature.enable"))
        #expect(builderAllowedToolNames.contains("feature.disable"))
        #expect(builderAllowedToolNames.contains("feature.delete"))
        #expect(builderAllowedToolNames.contains("feature.scaffold"))
        #expect(!builderAllowedToolNames.contains("web.search"))
        #expect(!builderAllowedToolNames.contains("clock.now"))
        #expect(!builderAllowedToolNames.contains(SwiftFeatureRuntime.featurePackageToolsAllowedName))
        #expect(customAllowedToolNames.isEmpty)
    }

    @Test
    func appSessionToolOverridesKeepBuilderIntrinsicTools() {
        let builderAgent = AgentProfile(
            id: AgentProfileStore.builderAgentID.uuidString,
            name: AgentProfileStore.builderAgentName,
            tools: []
        )
        let customAgent = AgentProfile(
            id: "custom",
            name: "Custom",
            tools: []
        )

        let builderAllowedToolNames = AgentCoreAppSessionFactory.resolvedAllowedToolNames(
            selectedToolKeys: ["shell"],
            explicitAllowedToolNames: nil,
            selectedAgent: builderAgent
        )
        let customAllowedToolNames = AgentCoreAppSessionFactory.resolvedAllowedToolNames(
            selectedToolKeys: ["shell"],
            explicitAllowedToolNames: nil,
            selectedAgent: customAgent
        )

        #expect(builderAllowedToolNames?.contains("local.exec") == true)
        #expect(builderAllowedToolNames?.contains("feature.list") == true)
        #expect(builderAllowedToolNames?.contains("feature.scaffold") == true)
        #expect(customAllowedToolNames?.contains("local.exec") == true)
        #expect(customAllowedToolNames?.contains("feature.list") == false)
    }

    @Test
    func agentProfileSaveRemovesFeatureBuilderToolReferences() {
        let builderAgent = AgentProfile(
            id: AgentProfileStore.builderAgentID.uuidString,
            name: AgentProfileStore.builderAgentName,
            tools: ["shell", "feature.list", "feature-builder", "shell"]
        )
        let customAgent = AgentProfile(
            id: "custom",
            name: "Custom",
            tools: ["files", TerminalToolSelectionCatalog.featureBuilderKey, "feature.build"]
        )

        let normalizedAgents = AgentProfileStore.normalizedAgentsForSave([
            builderAgent,
            customAgent
        ])
        let normalizedBuilder = normalizedAgents[0]
        let normalizedCustom = normalizedAgents[1]

        #expect(normalizedBuilder.tools == ["shell"])
        #expect(normalizedCustom.tools == ["files"])
    }

    @Test
    func activeToolRenderingHidesIntrinsicFeatureManagementTools() {
        let items = TerminalChat.toolSelectionItems(featureStatuses: [])
        let rendered = TerminalChat.renderActiveTools(
            ["local.exec", "feature.list", "feature.build"],
            items: items,
            selectedKeys: ["shell"]
        )
        let hiddenOnly = TerminalChat.renderActiveTools(
            ["feature.list", "feature.build"],
            items: items,
            selectedKeys: []
        )

        #expect(rendered == "Active tools: Shell (1)\n")
        #expect(hiddenOnly == "Active tools: none\n")
    }

    @Test
    func featureCommandWarnsWhenBuilderIsNotActive() {
        #expect(TerminalChat.featureCommandRequiresActiveBuilder(rawArguments: ""))
        #expect(TerminalChat.featureCommandRequiresActiveBuilder(rawArguments: "reload"))
        #expect(TerminalChat.featureCommandRequiresActiveBuilder(rawArguments: "enable git"))
        #expect(TerminalChat.featureCommandRequiresActiveBuilder(rawArguments: "delete test1"))
        #expect(TerminalChat.featureCommandRequiresActiveBuilder(rawArguments: "list"))
        #expect(TerminalChat.featureCommandRequiresActiveBuilder(rawArguments: "status"))
        #expect(TerminalChat.renderFeatureBuilderInactiveWarning().contains("Builder agent"))
        #expect(!TerminalChat.renderFeatureBuilderInactiveWarning().contains("/tools"))
    }

    @Test
    func savedSessionCommandTreatsSaveAsActiveSessionUpdate() {
        #expect(TerminalChat.savedSessionCommandAction(rawArguments: "") == .list)
        #expect(TerminalChat.savedSessionCommandAction(rawArguments: "delete") == .delete)
        #expect(TerminalChat.savedSessionCommandAction(rawArguments: " save ") == .saveActive)
        #expect(
            TerminalChat.savedSessionCommandAction(rawArguments: "daily checkpoint")
                == .saveNamed("daily checkpoint")
        )
    }

    @Test
    func featureWizardOutputsHumanReadableStatusInsteadOfJSON() {
        let scaffoldOutput = """
        {
          "directoryPath" : "/tmp/features/test1",
          "id" : "test1",
          "manifestPath" : "/tmp/features/test1/feature.json",
          "packagePath" : "/tmp/features/test1/Package.swift",
          "sourcePath" : "/tmp/features/test1/Sources/Test1/main.swift",
          "toolName" : "test1.run"
        }
        """
        let validationOutput = """
        {
          "errors" : [],
          "executablePath" : "/tmp/features/test1/.build/release/test1",
          "id" : "test1",
          "manifestPath" : "/tmp/features/test1/feature.json",
          "ok" : true,
          "tools" : [
            "test1.run"
          ],
          "warnings" : [
            "Executable has not been built yet: /tmp/features/test1/.build/release/test1"
          ]
        }
        """
        let buildOutput = """
        {
          "command" : [
            "swift",
            "build"
          ],
          "executablePath" : "/tmp/features/test1/.build/release/test1",
          "exitCode" : 0,
          "id" : "test1",
          "ok" : true,
          "stderr" : "",
          "stdout" : "Building for production...",
          "timedOut" : false,
          "workingDirectory" : "/tmp/features/test1"
        }
        """
        let failedBuildOutput = """
        {
          "command" : [
            "swift",
            "build"
          ],
          "executablePath" : "/tmp/features/test1/.build/release/test1",
          "exitCode" : 1,
          "id" : "test1",
          "ok" : false,
          "stderr" : "compile error",
          "stdout" : "",
          "timedOut" : false,
          "workingDirectory" : "/tmp/features/test1"
        }
        """
        let deleteOutput = """
        {
          "directoryPath" : "/tmp/features/test1",
          "id" : "test1",
          "manifestPath" : "/tmp/features/test1/feature.json",
          "ok" : true,
          "removed" : true,
          "wasEnabled" : false
        }
        """

        let scaffoldRendered = TerminalChat.renderFeatureManagementToolOutput(
            name: "feature.scaffold",
            output: scaffoldOutput
        )
        let validationRendered = TerminalChat.renderFeatureManagementToolOutput(
            name: "feature.validate",
            output: validationOutput
        )
        let buildRendered = TerminalChat.renderFeatureManagementToolOutput(
            name: "feature.build",
            output: buildOutput
        )
        let deleteRendered = TerminalChat.renderFeatureManagementToolOutput(
            name: "feature.delete",
            output: deleteOutput
        )
        let completion = TerminalChat.renderFeatureWizardCompletion(
            id: "test1",
            built: true,
            enabled: false,
            selected: false
        )

        #expect(scaffoldRendered.contains("Created Swift feature 'test1'."))
        #expect(scaffoldRendered.contains("Tool: test1.run"))
        #expect(!scaffoldRendered.contains("{"))
        #expect(validationRendered.contains("Validated Swift feature 'test1'."))
        #expect(!validationRendered.contains("Executable has not been built yet"))
        #expect(buildRendered.contains("Built Swift feature 'test1'."))
        #expect(!buildRendered.contains("stdout"))
        #expect(deleteRendered.contains("Deleted Swift feature 'test1'."))
        #expect(!deleteRendered.contains("{"))
        #expect(completion.contains("not active yet"))
        #expect(TerminalChat.featureManagementToolSucceeded(name: "feature.build", output: buildOutput))
        #expect(!TerminalChat.featureManagementToolSucceeded(name: "feature.build", output: failedBuildOutput))
    }

    @Test
    func featureImplementationPromptCarriesScaffoldContextAndRequirements() {
        let prompt = TerminalChat.featureImplementationPrompt(
            id: "test1",
            displayName: "Test1",
            directoryPath: "/tmp/features/test1",
            manifestPath: "/tmp/features/test1/feature.json",
            sourcePath: "/tmp/features/test1/Sources/Test1/main.swift",
            toolName: "test1.run",
            requirements: "Return the current git branch as JSON."
        )
        let draftPrompt = TerminalChat.featureImplementationPrompt(
            id: "test1",
            displayName: "Test1",
            directoryPath: "/tmp/features/test1",
            manifestPath: "/tmp/features/test1/feature.json",
            sourcePath: "/tmp/features/test1/Sources/Test1/main.swift",
            toolName: "test1.run",
            requirements: nil
        )

        #expect(prompt.contains("/tmp/features/test1/Sources/Test1/main.swift"))
        #expect(prompt.contains("test1.run"))
        #expect(prompt.contains("Return the current git branch as JSON."))
        #expect(prompt.contains("feature.validate"))
        #expect(prompt.contains("feature.build"))
        #expect(draftPrompt.hasSuffix("Goal / requirements:"))
    }

    @Test
    func runtimeDiscoveredFeaturePackagesDoNotCountPrefixesAsTools() throws {
        let items = TerminalChat.toolSelectionItems(
            featureStatuses: [
                featureStatus(
                    id: "mlx-xcode-tools",
                    source: .bundled,
                    tools: [],
                    toolNamePrefixes: ["xcode."],
                    discoversToolsAtRuntime: true
                ),
                featureStatus(
                    id: "mlx-figma-tools",
                    source: .bundled,
                    tools: ["figma.get_code", "figma.get_variable_defs"],
                    toolNamePrefixes: ["figma."],
                    discoversToolsAtRuntime: true
                )
            ]
        )

        let xcodeItem = try #require(items.first { $0.title == "Xcode" })
        let figmaItem = try #require(items.first { $0.title == "Figma" })
        let xcodeDetail = try #require(xcodeItem.detail)
        let figmaDetail = try #require(figmaItem.detail)

        #expect(xcodeDetail.contains("discovers tools at runtime"))
        #expect(!xcodeDetail.contains("1 tool: xcode."))
        #expect(figmaDetail.contains("2 tools: figma.get_code, figma.get_variable_defs"))
    }

    @Test
    func toolSelectionCatalogHidesDisabledFeaturePackages() {
        let items = TerminalChat.toolSelectionItems(
            featureStatuses: [
                featureStatus(
                    id: "enabled-clock",
                    displayName: "Enabled Clock",
                    source: .generated,
                    tools: ["clock.now"]
                ),
                featureStatus(
                    id: "disabled-clock",
                    displayName: "Disabled Clock",
                    source: .generated,
                    tools: ["clock.disabled"],
                    enabled: false
                )
            ]
        )

        #expect(items.map(\.title).contains("Enabled Clock"))
        #expect(!items.map(\.title).contains("Disabled Clock"))
    }

    @Test
    func featureListShowsBundledAndGeneratedPackagesIncludingDisabled() throws {
        let statuses = [
            featureStatus(
                id: "mlx-xcode-tools",
                source: .bundled,
                tools: [],
                toolNamePrefixes: ["xcode."],
                discoversToolsAtRuntime: true,
                enabled: false
            ),
            featureStatus(
                id: "custom-linear",
                displayName: "Linear",
                source: .generated,
                tools: ["linear.issue.list"]
            )
        ]

        let rendered = TerminalChat.renderFeatureStatusList(statuses)

        #expect(rendered.contains("Xcode [mlx-xcode-tools] - disabled, bundled, discovers tools at runtime"))
        #expect(rendered.contains("Linear [custom-linear] - enabled, generated, 1 tool: linear.issue.list"))
        #expect(rendered.contains("Use /feature enable <id|name|#>, /feature disable <id|name|#>, or /feature delete <id|name|#>."))
        #expect(try TerminalChat.resolvedFeatureID("xcode", statuses: statuses) == "mlx-xcode-tools")
        #expect(try TerminalChat.resolvedFeatureID("Linear", statuses: statuses) == "custom-linear")
    }

    @Test
    func activeToolRenderingCountsUndiscoveredRuntimePackagesAsZero() throws {
        let items = TerminalChat.toolSelectionItems(
            featureStatuses: [
                featureStatus(
                    id: "mlx-figma-tools",
                    source: .bundled,
                    tools: [],
                    toolNamePrefixes: ["figma."],
                    discoversToolsAtRuntime: true
                )
            ]
        )
        let selectedKeys = try TerminalChat.parseToolSelection("figma", items: items)
        let allowedToolNames = TerminalToolSelectionCatalog.allowedToolNames(
            for: selectedKeys,
            items: items
        )
        let rendered = TerminalChat.renderActiveTools(
            Array(allowedToolNames),
            items: items,
            selectedKeys: selectedKeys
        )

        #expect(rendered.contains("Figma (0)"))
        #expect(!rendered.contains("Figma (1)"))
        #expect(rendered.hasPrefix("Active tools: Figma (0)"))
        #expect(!rendered.contains("\n  Figma"))
    }

    @Test
    func discoveredMCPDescriptorsAreRenderedInsideFeaturePackage() throws {
        let items = TerminalChat.toolSelectionItems(
            featureStatuses: [
                featureStatus(
                    id: "mlx-xcode-tools",
                    source: .bundled,
                    tools: [],
                    toolNamePrefixes: ["xcode."],
                    discoversToolsAtRuntime: true
                )
            ],
            additionalDescriptors: [
                DirectToolDescriptor(
                    name: "xcode.BuildProject",
                    description: "Xcode: build project",
                    inputSchema: "{}"
                )
            ]
        )
        let xcodeItem = try #require(items.first { $0.title == "Xcode" })
        let selectedKeys = try TerminalChat.parseToolSelection("xcode", items: items)
        let allowedToolNames = TerminalToolSelectionCatalog.allowedToolNames(
            for: selectedKeys,
            items: items
        )
        let rendered = TerminalChat.renderActiveTools(
            Array(allowedToolNames),
            items: items,
            selectedKeys: selectedKeys
        )

        #expect(xcodeItem.detail?.contains("1 tool: xcode.BuildProject") == true)
        #expect(allowedToolNames.contains("xcode.BuildProject"))
        #expect(rendered.contains("Xcode (1)"))
        #expect(!rendered.contains("xcode.BuildProject"))
        #expect(rendered.hasPrefix("Active tools: Xcode (1)"))
    }

    @Test
    func defaultAgentInstructionsDescribeDynamicFeatureWorkflow() {
        let instructions = MLXSystemPromptBuilder.defaultAgentInstructions()

        #expect(instructions.contains("Dynamic Swift feature workflow:"))
        #expect(instructions.contains("feature.scaffold"))
        #expect(instructions.contains("feature.validate"))
        #expect(instructions.contains("feature.build"))
        #expect(instructions.contains("feature.enable"))
        #expect(instructions.contains("feature.reload"))
        #expect(instructions.contains("feature.install"))
        #expect(instructions.contains("feature.delete"))
        #expect(instructions.contains("Swift tools 6.3"))
        #expect(instructions.contains("core runtime behavior"))
        #expect(instructions.contains("`local.*` file tools"))
        #expect(instructions.contains("`text.*` tools"))
    }

    @Test
    func hostedConfigurationCanReloadAgentProfilesFromStore() throws {
        let configuration = try AgentConfiguration(
            hostedModelID: "mlx-community/test",
            availableAgents: AgentProfileStore.defaultProfiles(),
            cacheAgentProfiles: false,
            workingDirectory: URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        )

        #expect(configuration.selectedAgent?.displayName == AgentProfileStore.defaultAgentName)
        #expect(configuration.hostedAgentProfiles == nil)
    }

    @Test
    func hostedEffectiveModelUsesHostedManifestInsteadOfCoderSettings() {
        let provider = AgentRemoteProvider(
            name: "mlx-server",
            baseURL: "http://127.0.0.1",
            modelID: "mlx-community/server-model"
        )
        let hostedManifest = AgentSettingsManifest(
            models: [
                AgentSettingsModelManifest(
                    kind: .remoteAPI,
                    modelID: "mlx-community/server-model",
                    provider: provider
                )
            ],
            selectedModelID: "mlx-community/server-model"
        )
        let agent = AgentProfile(
            id: UUID().uuidString,
            name: "Remote default",
            tools: [],
            modelID: "remoteapi:provider:mlx-community/server-model"
        )

        let effectiveModelID = TerminalChat.effectiveModelID(
            selectedAgent: agent,
            manualModelIDOverride: nil,
            manifest: hostedManifest
        )

        #expect(effectiveModelID == "mlx-community/server-model")
    }

    @Test
    func terminalSessionConfigurationUsesStableProjectCacheKeyByDefault() throws {
        let workingDirectory = URL(
            fileURLWithPath: "/tmp/mlx-coder-cache-project",
            isDirectory: true
        )
        let configuration = try AgentConfiguration(
            hostedModelID: "mlx-community/test",
            availableAgents: AgentProfileStore.defaultProfiles(),
            workingDirectory: workingDirectory
        )
        let terminal = TerminalChat(
            configuration: configuration,
            stdinIsTerminal: false
        )

        let sessionConfiguration = terminal.currentSessionConfiguration(
            allowedToolNames: []
        )

        #expect(
            sessionConfiguration.cacheKey
                == AgentKVCachePersistencePolicy.terminalDiskCacheKey(
                    workingDirectoryPath: workingDirectory.path
                )
        )
    }

    @Test
    func terminalSessionConfigurationPreservesLoadedCacheKey() throws {
        let workingDirectory = URL(
            fileURLWithPath: "/tmp/mlx-coder-cache-project",
            isDirectory: true
        )
        let configuration = try AgentConfiguration(
            hostedModelID: "mlx-community/test",
            availableAgents: AgentProfileStore.defaultProfiles(),
            workingDirectory: workingDirectory
        )
        let terminal = TerminalChat(
            configuration: configuration,
            stdinIsTerminal: false
        )
        terminal.activeSessionCacheKey = "terminal:/tmp/mlx-coder-cache-project:session:plan"

        let sessionConfiguration = terminal.currentSessionConfiguration(
            allowedToolNames: []
        )

        #expect(
            sessionConfiguration.cacheKey
                == "terminal:/tmp/mlx-coder-cache-project:session:plan"
        )
    }

    private func featureStatus(
        id: String,
        displayName: String? = nil,
        source: SwiftFeatureBundleSource,
        tools: [String],
        toolNamePrefixes: [String] = [],
        discoversToolsAtRuntime: Bool = false,
        enabled: Bool = true,
        available: Bool = true
    ) -> SwiftFeatureStatus {
        SwiftFeatureStatus(
            id: id,
            displayName: displayName,
            description: nil,
            source: source,
            enabled: enabled,
            available: available,
            executablePath: "/tmp/\(id)",
            manifestPath: nil,
            tools: tools,
            toolNamePrefixes: toolNamePrefixes,
            toolNameAliases: [],
            discoversToolsAtRuntime: discoversToolsAtRuntime,
            build: nil,
            generated: nil,
            issue: nil
        )
    }
}
