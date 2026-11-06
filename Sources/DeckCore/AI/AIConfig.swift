import Foundation

/// Settings for the Local AI feature: where discovery looks, where the MLX runtime
/// and downloaded models live, and the public services it talks to.
public enum AIConfig {
    // MARK: Discovery

    /// Ports that are always probed, with the server people usually run there.
    /// Other ports are probed only when a known model server process listens on them.
    public static let wellKnownPorts: [(port: Int, hint: ModelServerKind)] = [
        (11434, .ollama),
        (1234, .lmStudio),
        (8080, .mlxLM),        // mlx_lm.server and llama.cpp default
        (8000, .openAICompatible), // vLLM, oMLX, many Python servers
        (mlxDefaultPort, .mlxLM),
        (10240, .oMLX),
        (1337, .openAICompatible),  // Jan
        (4891, .openAICompatible),  // GPT4All
        (5001, .openAICompatible),  // KoboldCpp
        (52415, .openAICompatible), // exo
        (8081, .openAICompatible)
    ]

    /// Words in a listening process's command line that mark it as a model server.
    /// Matched case insensitive against `ps -o command=`.
    public static let processKeywords: [(keyword: String, kind: ModelServerKind)] = [
        ("ollama", .ollama),
        ("lm studio", .lmStudio),
        ("lmstudio", .lmStudio),
        ("llmster", .lmStudio),
        ("omlx", .oMLX),
        ("mlx_lm.server", .mlxLM),
        ("mlx_lm server", .mlxLM),
        ("mlx-lm", .mlxLM),
        ("mlx_vlm.server", .mlxLM),
        ("llama-server", .llamaCpp),
        ("llama.cpp", .llamaCpp),
        ("vllm", .vLLM),
        ("koboldcpp", .openAICompatible),
        ("localai", .openAICompatible)
    ]

    /// Time limit for one discovery probe. Local servers answer in a few milliseconds.
    public static let probeTimeout: TimeInterval = 1.5

    /// How long `ModelEndpoints.current()` reuses the last discovery.
    public static let cacheLifetime: TimeInterval = 5

    // MARK: MLX runtime

    /// Port of the MLX server Container Deck starts. Not 8080, which many dev servers use.
    public static let mlxDefaultPort = 8585
    /// Python version uv installs for mlx-lm.
    public static let mlxPythonVersion = "3.12"
    /// Package installed with `uv tool install`.
    public static let mlxPackage = "mlx-lm"
    /// Lines of server output kept in memory.
    public static let maxLogLines = 3000
    /// uv download for Apple silicon, used only when no uv is installed.
    public static let uvDownloadURL = URL(string: "https://github.com/astral-sh/uv/releases/latest/download/uv-aarch64-apple-darwin.tar.gz")!

    /// Places uv is usually installed. The copy in our own folder is checked first.
    public static let uvSearchPaths = [
        "/opt/homebrew/bin/uv",
        "/usr/local/bin/uv",
        "~/.local/bin/uv",
        "~/.cargo/bin/uv"
    ]

    /// Places Ollama's command is installed.
    public static let ollamaSearchPaths = [
        "/opt/homebrew/bin/ollama",
        "/usr/local/bin/ollama",
        "/Applications/Ollama.app/Contents/Resources/ollama"
    ]
    public static let ollamaApp = "/Applications/Ollama.app"
    public static let lmStudioApps = ["/Applications/LM Studio.app", "~/Applications/LM Studio.app"]

    // MARK: Model library

    /// Hugging Face organisation searched by the model library.
    public static let libraryAuthor = "mlx-community"
    public static let huggingFaceAPI = URL(string: "https://huggingface.co")!
    public static let searchPageSize = 30
    /// Shared Hugging Face cache. Models found here are listed too.
    public static let huggingFaceCache = "~/.cache/huggingface/hub"

    // MARK: Folders

    /// Folder inside Application Support/<bundle id>.
    public static let folderName = "AI"
    /// Environment variable that moves the AI folder (tests, separate app copies).
    public static let directoryOverrideVariable = "DECK_AI_DIR"

    /// Application Support/<bundle id>/AI.
    public static var baseDirectory: URL {
        if let override = ProcessInfo.processInfo.environment[directoryOverrideVariable], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent(AppConfig.bundleID, isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    /// Expands a leading "~".
    public static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}
