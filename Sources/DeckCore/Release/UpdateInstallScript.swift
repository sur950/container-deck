import Foundation

/// Writes the small shell script that swaps the app bundle after the app quits.
///
/// Steps: wait for the old process to exit, copy the new app next to the old one with
/// `ditto`, remove quarantine (the app is not notarized, so a quarantined copy would be blocked), move the old app aside as a backup, move the new one in,
/// open it, and delete the backup once the new version is running. Any failure puts the
/// old app back and opens it again.
public struct UpdateInstallScript: Sendable, Equatable {
    /// Process id of the running app. The script waits until it is gone.
    public var pid: Int32
    /// The verified new app, in a temporary folder.
    public var newApp: String
    /// The app bundle to replace, for example "/Applications/Container Deck.app".
    public var target: String
    /// Temporary folder to delete at the end (holds the download and `newApp`).
    public var workDir: String
    /// Log file the script appends to.
    public var logFile: String
    /// Seconds to wait for the old app to quit.
    public var quitTimeout: Int
    /// Seconds to wait for the new app to show up before rolling back.
    public var launchTimeout: Int

    public init(pid: Int32, newApp: String, target: String, workDir: String, logFile: String,
                quitTimeout: Int = 120, launchTimeout: Int = 30) {
        self.pid = pid
        self.newApp = newApp
        self.target = target
        self.workDir = workDir
        self.logFile = logFile
        self.quitTimeout = quitTimeout
        self.launchTimeout = launchTimeout
    }

    /// Sibling of the target the new copy is staged in. Hidden, same volume, so `mv` is a rename.
    public var stagePath: String { Self.sibling(of: target, suffix: "update-new") }
    /// Sibling the old app is kept in until the new one runs.
    public var backupPath: String { Self.sibling(of: target, suffix: "update-old") }

    static func sibling(of path: String, suffix: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        return (parent as NSString).appendingPathComponent(".\(name).\(suffix)")
    }

    /// Single quotes for /bin/sh. Safe for spaces, quotes, dollar signs and backticks.
    public static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public var contents: String {
        let q = Self.shellQuote
        // Loops count half second steps.
        let quitSteps = max(1, quitTimeout * 2)
        let launchSteps = max(1, launchTimeout * 2)
        return """
        #!/bin/sh
        # \(AppConfig.appName) updater. Written by the app, runs once after it quits.
        PID=\(pid)
        NEW_APP=\(q(newApp))
        TARGET=\(q(target))
        STAGE=\(q(stagePath))
        BACKUP=\(q(backupPath))
        WORK=\(q(workDir))
        LOG=\(q(logFile))
        EXE_PREFIX="$TARGET/Contents/MacOS/"

        log() { echo "$(/bin/date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }
        finish() { /bin/rm -rf "$WORK"; log "done ($1)"; exit "$1"; }
        reopen_old() { /usr/bin/open "$TARGET" >> "$LOG" 2>&1; }

        log "update to $TARGET: waiting for process $PID to quit"
        n=0
        while /bin/kill -0 "$PID" 2>/dev/null; do
          n=$((n + 1))
          if [ "$n" -ge \(quitSteps) ]; then log "the app did not quit, giving up"; finish 1; fi
          /bin/sleep 0.5
        done

        if [ ! -d "$NEW_APP" ]; then log "new app missing: $NEW_APP"; reopen_old; finish 1; fi

        /bin/rm -rf "$STAGE"
        if ! /usr/bin/ditto "$NEW_APP" "$STAGE" >> "$LOG" 2>&1; then
          log "copy failed"; /bin/rm -rf "$STAGE"; reopen_old; finish 1
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$STAGE" 2>/dev/null

        /bin/rm -rf "$BACKUP"
        if ! /bin/mv "$TARGET" "$BACKUP" >> "$LOG" 2>&1; then
          log "could not move the old app aside"; /bin/rm -rf "$STAGE"; reopen_old; finish 1
        fi
        if ! /bin/mv "$STAGE" "$TARGET" >> "$LOG" 2>&1; then
          log "could not move the new app in, restoring"
          /bin/mv "$BACKUP" "$TARGET"; /bin/rm -rf "$STAGE"; reopen_old; finish 1
        fi
        /usr/bin/touch "$TARGET"
        # Not notarized: clear quarantine on the installed app too, so Gatekeeper does not block the relaunch.
        /usr/bin/xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null

        rollback() {
          log "rolling back: $1"
          /bin/rm -rf "$STAGE"
          /bin/mv "$TARGET" "$STAGE" && /bin/mv "$BACKUP" "$TARGET"
          /bin/rm -rf "$STAGE"
          reopen_old
          finish 1
        }

        # The running app shows up in ps under the target path, or its resolved form (/tmp is /private/tmp).
        REAL_PREFIX="$(cd "$TARGET" 2>/dev/null && /bin/pwd -P)/Contents/MacOS/"
        if ! /usr/bin/open "$TARGET" >> "$LOG" 2>&1; then rollback "open failed"; fi
        n=0
        while [ "$n" -lt \(launchSteps) ]; do
          if /bin/ps -axww -o command= | P="$EXE_PREFIX" Q="$REAL_PREFIX" /usr/bin/awk 'BEGIN { f = 1 } index($0, ENVIRON["P"]) > 0 || index($0, ENVIRON["Q"]) > 0 { f = 0 } END { exit f }'; then
            /bin/rm -rf "$BACKUP"
            log "new version is running"
            finish 0
          fi
          n=$((n + 1))
          /bin/sleep 0.5
        done
        rollback "the new version did not start"

        """
    }
}
