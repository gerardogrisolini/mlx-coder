import MLXFeatureKit
import MLXLocalToolsSupport

@main
struct MLXSearchToolsFeatureMain {
    static func main() async {
        await MLXFeatureRunner.run(MLXLocalFeatureTools.searchTools())
    }
}
