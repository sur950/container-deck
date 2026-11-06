import Foundation

// Recorded on this Mac, 5 Nov 2026.
enum DomainsFixtures {
    /// First bytes curl 8 (macOS, LibreSSL) sent to https://web.localhost:19999 (TLS ClientHello).
    static let curlClientHelloHex = "160301013e0100013a03033d7e8626513f5d4be53d7279e908fc0d8e5368620d12df3e1a623a61b7009285209ed9bad141f5e0afc662b3c87d1886eeb2a6c80a1b01eca4a518763a06f657b20062130313021301cca9cca8ccaac030c02cc028c024c014c00a009f006b0039ff8500c400880081009d003d003500c00084c02fc02bc027c023c013c009009e0067003300be0045009c003c002f00ba0041c011c00700050004c012c0080016000a00ff0100008f002b0009080304030303020301003300260024001d0020ab3114b5431bad39f42d2724ee9534f2d30c982f3e72c65b8648ae90f6fedc4800000012001000000d7765622e6c6f63616c686f7374000b00020100000a000a0008001d001700180019000d00180016080606010603080505010503080404010403020102030010000e000c02683208687474702f312e31"

    /// `curl https://api.github.com/repos/cloudflare/cloudflared/releases/latest`, trimmed to the fields we read.
    static let cloudflaredRelease = #"""
    {
      "tag_name": "2026.10.7",
      "name": "2026.10.7",
      "assets": [
        {
          "name": "cloudflared-darwin-amd64.tgz",
          "size": 21834416,
          "digest": "sha256:02f3edfd87684dd5b705607688e4eb4b323f6e777b81e7b3a85af556aa356848",
          "browser_download_url": "https://github.com/cloudflare/cloudflared/releases/download/2026.10.7/cloudflared-darwin-amd64.tgz"
        },
        {
          "name": "cloudflared-darwin-arm64.tgz",
          "size": 19847161,
          "digest": "sha256:3586ccf397e98e5f437e60e7c307ca6ac463e110580503af8bb8e6f9ebf831bd",
          "browser_download_url": "https://github.com/cloudflare/cloudflared/releases/download/2026.10.7/cloudflared-darwin-arm64.tgz"
        }
      ]
    }
    """#

    /// Recorded output of `cloudflared tunnel --no-autoupdate --url http://192.168.65.2:80`
    /// (cloudflared 2026.3.0, 5 Nov 2026), up to the link. The tunnel was stopped right after.
    static let cloudflaredQuickTunnel = """
    2026-11-05T17:12:38Z INF Thank you for trying Cloudflare Tunnel. Doing so, without a Cloudflare account, is a quick way to experiment and try it out. However, be aware that these account-less Tunnels have no uptime guarantee, are subject to the Cloudflare Online Services Terms of Use (https://www.cloudflare.com/website-terms/), and Cloudflare reserves the right to investigate your use of Tunnels for violations of such terms. If you intend to use Tunnels in production you should use a pre-created named tunnel by following: https://developers.cloudflare.com/cloudflare-one/connections/connect-apps
    2026-11-05T17:12:38Z INF Requesting new quick Tunnel on trycloudflare.com...
    2026-11-05T17:12:44Z INF +--------------------------------------------------------------------------------------------+
    2026-11-05T17:12:44Z INF |  Your quick Tunnel has been created! Visit it at (it may take some time to be reachable):  |
    2026-11-05T17:12:44Z INF |  https://chelsea-treating-airline-chan.trycloudflare.com                                   |
    2026-11-05T17:12:44Z INF +--------------------------------------------------------------------------------------------+
    """
    static let cloudflaredQuickTunnelURL = "https://chelsea-treating-airline-chan.trycloudflare.com"

    /// Shape of one `ngrok http 192.168.65.2:80 --log stdout --log-format json` line (ngrok 3 log format).
    /// A success line needs an ngrok account, so this one is written by hand from that format. The real
    /// failure output of ngrok 3.39.13 is recorded in DomainsShareFixtures.
    static let ngrokStarted = #"{"addr":"http://192.168.65.2:80","lvl":"info","msg":"started tunnel","name":"command_line","obj":"tunnels","t":"2026-11-05T17:21:00.1+00:00","url":"https://ab12-34-56.ngrok-free.app"}"#

    /// /etc/resolver/containerization.host.container.internal as written by container 1.6.1
    /// (`container system dns create host.container.internal --localhost 203.0.113.113`).
    static let hostAliasResolver = """
    domain host.container.internal
    search host.container.internal
    nameserver 127.0.0.1
    port 1053
    options localhost:203.0.113.113
    """

    /// /etc/resolver/containerization.test as written by `container system dns create test`.
    static let plainResolver = """
    domain test
    search test
    nameserver 127.0.0.1
    port 2053

    """
}
