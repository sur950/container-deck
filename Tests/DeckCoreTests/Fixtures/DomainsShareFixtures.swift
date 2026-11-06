import Foundation

// Real output of the official ngrok agent 3.39.13 (darwin arm64, from bin.equinox.io), run on this
// Mac on 6 Nov 2026 with an empty HOME so nothing was read or written, and no account:
// `ngrok http 127.0.0.1:9 --log stdout --log-format json`. JSON log lines go to stdout,
// the human message to stderr. Exit code 1 in every case.
enum DomainsShareFixtures {
    /// No authtoken at all (ERR_NGROK_4018), stdout.
    static let ngrokNoAuthtokenStdout = #"""
    {"t":"2026-11-06T10:31:06+0530","lvl":"info","msg":"no configuration paths supplied"}
    {"t":"2026-11-06T10:31:06+0530","lvl":"info","msg":"ignoring default config path","path":"/tmp/ngrok-real-home/Library/Application Support/ngrok/ngrok.yml","err":"stat /tmp/ngrok-real-home/Library/Application Support/ngrok/ngrok.yml: no such file or directory"}
    {"t":"2026-11-06T10:31:06+0530","lvl":"info","msg":"FIPS 140 mode","enabled":false}
    {"t":"2026-11-06T10:31:06+0530","lvl":"info","msg":"starting web service","obj":"web","addr":"127.0.0.1:4040","allow_hosts":null}
    {"t":"2026-11-06T10:31:07+0530","lvl":"eror","msg":"failed to reconnect session","obj":"tunnels.session","err":"authentication failed: This ngrok session is not authenticated. ngrok requires an account and a valid credential to start a session.\n\nSign up for an account: https://dashboard.ngrok.com/signup\nGet your credential: https://dashboard.ngrok.com/get-started/your-authtoken\r\n\r\nERR_NGROK_4018\r\n"}
    {"t":"2026-11-06T10:31:07+0530","lvl":"eror","msg":"session closing","obj":"tunnels.session","err":"authentication failed: This ngrok session is not authenticated. ngrok requires an account and a valid credential to start a session.\n\nSign up for an account: https://dashboard.ngrok.com/signup\nGet your credential: https://dashboard.ngrok.com/get-started/your-authtoken\r\n\r\nERR_NGROK_4018\r\n"}
    {"t":"2026-11-06T10:31:07+0530","lvl":"info","msg":"INFO received stop request obj=app stopReq=\"{err:{Remote:true Inner:{Inner:0x18fcb31501c0}} restart:false}\""}
    {"t":"2026-11-06T10:31:07+0530","lvl":"info","msg":"ERROR terminating with error obj=app err=\"authentication failed: This ngrok session is not authenticated. ngrok requires an account and a valid credential to start a session.\\n\\nSign up for an account: https://dashboard.ngrok.com/signup\\nGet your credential: https://dashboard.ngrok.com/get-started/your-authtoken\\r\\n\\r\\nERR_NGROK_4018\\r\\n\""}
    {"t":"2026-11-06T10:31:07+0530","lvl":"crit","msg":"command failed","err":"authentication failed: This ngrok session is not authenticated. ngrok requires an account and a valid credential to start a session.\n\nSign up for an account: https://dashboard.ngrok.com/signup\nGet your credential: https://dashboard.ngrok.com/get-started/your-authtoken\r\n\r\nERR_NGROK_4018\r\n"}
    {"t":"2026-11-06T10:31:07+0530","lvl":"info","msg":"no more state changes","obj":"tunnels.session"}
    {"t":"2026-11-06T10:31:07+0530","lvl":"warn","msg":"failed to check for update","obj":"updater","err":"Post \"https://update.ngrok-agent.com/check\": context canceled"}
    """#
    /// No authtoken at all (ERR_NGROK_4018), stderr.
    static let ngrokNoAuthtokenStderr = #"""
    ERROR:  authentication failed: This ngrok session is not authenticated. ngrok requires an account and a valid credential to start a session.
    ERROR:  
    ERROR:  Sign up for an account: https://dashboard.ngrok.com/signup
    ERROR:  Get your credential: https://dashboard.ngrok.com/get-started/your-authtoken
    ERROR:  
    ERROR:  ERR_NGROK_4018
    ERROR:  https://ngrok.com/docs/errors/err_ngrok_4018
    ERROR:  
    """#
    /// NGROK_AUTHTOKEN set to a malformed value (ERR_NGROK_105), stderr.
    static let ngrokMalformedTokenStderr = #"""
    ERROR:  authentication failed: The authtoken you specified does not look like a proper ngrok authtoken.
    ERROR:  Instructions to install your authtoken are on your ngrok dashboard:
    ERROR:  https://dashboard.ngrok.com/get-started/your-authtoken
    ERROR:  
    ERROR:  ERR_NGROK_105
    ERROR:  https://ngrok.com/docs/errors/err_ngrok_105
    ERROR:  
    """#
    /// Same run, the eror and crit JSON lines from stdout.
    static let ngrokMalformedTokenStdoutErrors = #"""
    {"t":"2026-11-06T10:31:16+0530","lvl":"eror","msg":"failed to reconnect session","obj":"tunnels.session","err":"authentication failed: The authtoken you specified does not look like a proper ngrok authtoken.\nInstructions to install your authtoken are on your ngrok dashboard:\nhttps://dashboard.ngrok.com/get-started/your-authtoken\r\n\r\nERR_NGROK_105\r\n"}
    {"t":"2026-11-06T10:31:16+0530","lvl":"eror","msg":"session closing","obj":"tunnels.session","err":"authentication failed: The authtoken you specified does not look like a proper ngrok authtoken.\nInstructions to install your authtoken are on your ngrok dashboard:\nhttps://dashboard.ngrok.com/get-started/your-authtoken\r\n\r\nERR_NGROK_105\r\n"}
    {"t":"2026-11-06T10:31:16+0530","lvl":"crit","msg":"command failed","err":"authentication failed: The authtoken you specified does not look like a proper ngrok authtoken.\nInstructions to install your authtoken are on your ngrok dashboard:\nhttps://dashboard.ngrok.com/get-started/your-authtoken\r\n\r\nERR_NGROK_105\r\n"}
    """#
    /// NGROK_AUTHTOKEN well formed but not a real token (ERR_NGROK_107), stderr.
    static let ngrokRevokedTokenStderr = #"""
    ERROR:  authentication failed: The authtoken you specified is properly formed, but it is invalid.
    ERROR:  This usually happens when:
    ERROR:      - You reset your authtoken
    ERROR:      - Your authtoken was for a team account that you were removed from
    ERROR:      - You are using ngrok link and this credential was explicitly revoked
    ERROR:  Go to your ngrok dashboard and double check that your authtoken is correct:
    ERROR:  https://dashboard.ngrok.com/get-started/your-authtoken
    ERROR:  
    ERROR:  ERR_NGROK_107
    ERROR:  https://ngrok.com/docs/errors/err_ngrok_107
    ERROR:  
    """#
    /// Same agent, port 4040 taken by another program: it moved its web service to 4041.
    static let ngrokWebServiceMoved = #"{"t":"2026-11-06T10:31:28+0530","lvl":"info","msg":"starting web service","obj":"web","addr":"127.0.0.1:4041","allow_hosts":null}"#
}
