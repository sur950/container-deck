import Foundation

/// Real output for the component health checks, recorded on this Mac on 9 Nov 2026 with read
/// only commands (container 1.6.1, kubectl 1.35.0, cloudflared 2026.3.0, uv 0.9.28, Ollama 0.16.2).
/// Long help texts are cut to the lines the checks read. Lines marked "example" are not recorded:
/// they follow the format the app's parsers already read (LM Studio is not installed on this Mac).
enum HealthFixtures {
    /// `container system status`.
    static let systemStatus = """
    FIELD               VALUE
    status              running
    client.version      1.6.1
    client.build        release
    client.commit       aa8d76b44a834eee3ebf6a0bc577e376f65f6361
    server.version      1.6.1
    paths.appRoot       /Users/suresh/Library/Application Support/com.apple.container/
    containers.total    0
    containers.running  0
    images.total        1
    """

    /// `container system status` with the service stopped.
    static let systemStatusStopped = "apiserver is not running and not registered with launchd\n"

    /// Example: `container cluster --help` without Apple's cluster plugin.
    static let clusterUnsupported = "Error: Plugin 'container-cluster' not found.\n\nUsage: container <subcommand>\n  unknown command 'cluster'"

    /// `kubectl version --client -o json`.
    static let kubectlVersion = """
    {
      "clientVersion": {
        "major": "1",
        "minor": "35",
        "gitVersion": "v1.35.0",
        "gitCommit": "66452049f3d692768c39c797b21b793dce80314e",
        "gitTreeState": "clean",
        "buildDate": "2025-12-17T12:32:06Z",
        "goVersion": "go1.25.5",
        "compiler": "gc",
        "platform": "darwin/arm64"
      },
      "kustomizeVersion": "v5.7.1"
    }
    """

    /// `kubectl port-forward --help` (end).
    static let kubectlPortForwardHelp = """
      # Listen on a random port locally, forwarding to 5000 in the pod
      kubectl port-forward pod/mypod :5000

    Options:
        --address=[localhost]:
    \tAddresses to listen on (comma separated). Only accepts IP addresses or localhost as a value.

        --pod-running-timeout=1m0s:
    \tThe length of time (like 5s, 2m, or 3h, higher than zero) to wait until at least one pod is running

    Usage:
      kubectl port-forward TYPE/NAME [options] [LOCAL_PORT:]REMOTE_PORT [...[LOCAL_PORT_N:]REMOTE_PORT_N]

    Use "kubectl options" for a list of global command-line options (applies to all commands).
    """

    /// `kubectl options` (middle).
    static let kubectlOptions = """
        --context='':
    \tThe name of the kubeconfig context to use

        --kubeconfig='':
    \tPath to the kubeconfig file to use for CLI requests.

        -n, --namespace='':
    \tIf present, the namespace scope for this CLI request
    """

    /// `kubectl apply --help` (one option).
    static let kubectlApplyHelp = """
    Options:
        -f, --filename=[]:
    \tThe files that contain the configurations to apply.
    """

    /// `cloudflared tunnel --help` (cut).
    static let cloudflaredTunnelHelp = """
    NAME:
       cloudflared tunnel - Use Cloudflare Tunnel to expose private services to the Internet or to Cloudflare connected private users.

    USAGE:
       cloudflared tunnel command [command options]

    OPTIONS:
       --config value           Specifies a config file in YAML format.
       --autoupdate-freq value  Autoupdate frequency. Default is 24h0m0s. (default: 24h0m0s)
       --no-autoupdate          Disable periodic check for updates, restarting the server with the new version. (default: false) [$NO_AUTOUPDATE]
       --pidfile value                                     Write the application's PID to this file after first successful connection. [$TUNNEL_PIDFILE]
       --url URL                                           Connect to the local webserver at URL. (default: "http://localhost:8080") [$TUNNEL_URL]
       --socks5 --url                                      specify if this tunnel is running as a SOCK5 Server
    """

    /// The same help from a release that dropped `--url` (made up from the one above).
    static let cloudflaredTunnelHelpNoURL = """
    OPTIONS:
       --config value           Specifies a config file in YAML format.
       --no-autoupdate          Disable periodic check for updates. (default: false) [$NO_AUTOUPDATE]
       --hello-world            Run Hello World Server (default: false)
    """

    /// `uv tool install --help` (cut).
    static let uvToolInstallHelp = """
    Install commands provided by a Python package

    Usage: uv tool install [OPTIONS] <PACKAGE>

          --force
              Force installation of the tool
    Resolver options:
      -U, --upgrade
              Allow package upgrades, ignoring pinned versions in any existing output file. Implies
              `--refresh`
    Python options:
      -p, --python <PYTHON>      The Python interpreter to use to build the tool environment. [env:
                                 UV_PYTHON=]
    """

    static let uvVersion = "uv 0.9.28 (Homebrew 2026-01-29)\n"
    static let cloudflaredVersion = "cloudflared version 2026.3.0 (built 2026-03-06T12:53:40Z)\n"
    static let helmVersion = "v4.1.0+g4553a0a\n"

    /// Ollama `GET /api/version`, `/api/tags` (two models) and `/api/ps` (none loaded).
    static let ollamaVersion = #"{"version":"0.16.2"}"#
    static let ollamaTags = #"""
    {"models":[{"name":"qwen3:0.6b","model":"qwen3:0.6b","modified_at":"2026-11-06T03:16:43.533220427+05:30","size":522653767,"digest":"7df6b6e09427a769808717c0a93cadc4ae99ed4eb8bf5ca557c90846becea435","details":{"parent_model":"","format":"gguf","family":"qwen3","families":["qwen3"],"parameter_size":"751.63M","quantization_level":"Q4_K_M"}},{"name":"mistral:latest","model":"mistral:latest","modified_at":"2026-02-11T16:25:54.334179028+05:30","size":4372824384,"digest":"6577803aa9a036369e481d648a2baebb381ebc6e897f2bb9a766a2aa7bfbc1cf","details":{"parent_model":"","format":"gguf","family":"llama","families":["llama"],"parameter_size":"7.2B","quantization_level":"Q4_K_M"}}]}
    """#
    static let ollamaPS = #"{"models":[]}"#
    /// A new format Ollama could ship: the list moved under another key.
    static let ollamaPSChanged = #"{"running":[{"name":"qwen3:0.6b"}]}"#

    /// Example: `lms daemon status --json`, `lms server status --json` and `lms version`, in the shapes
    /// LMStudioRuntimeTests already uses.
    static let lmsDaemonRunning = #"{ "status": "running", "pid": 12345, "isDaemon": true }"#
    static let lmsDaemonStopped = #"{ "status": "not-running" }"#
    static let lmsServerStatus = #"{"running":true,"port":1234}"#
    static let lmsVersion = "lms - LM Studio CLI - v0.0.47\nCommit: 2a3e1b8\n"

    /// `claude --version` (npm install, recorded) and an example config file.
    static let claudeVersion = "2.1.318 (Claude Code)\n"
    static let claudeJSON = #"{"numStartups": 12, "mcpServers": {"fetch": {"command": "container", "args": ["run", "-i", "--rm", "mcp/fetch"]}}}"#
}
