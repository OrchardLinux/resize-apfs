import Foundation
import Darwin

/// The app without DFU: the files Dopamine unpacks on a device give its user `mobile` the
/// well-known password `alpine`, and that user may become root with `sudo`. Dopamine's own
/// interface makes the user choose another one on the first run; ours asks nothing
/// (Access/AccessBridge.m), so the helper replaces the default with a random password nobody
/// knows. Nothing here needs it: anything already running as root can set a new one (as
/// Dopamine's "Change mobile password" does), and removing Dopamine's files brings the
/// default back, which the next helper start replaces again.
///
/// Only the default is replaced: a password the user chose stays.
public enum TerminalPassword {
    static let accounts = "/var/jb/etc/master.passwd"
    static let tool = "/var/jb/usr/sbin/pw"
    /// `alpine`, as the account file of Procursus's bootstraps 1800 and 1900 holds it (the ones
    /// in Dopamine 3.0.13). A bootstrap with another salt is not recognised: see
    /// docs/updating-dopamine.md.
    static let defaults: Set<String> = [
        "$6$V7qMYJaNbVKOeh4P$iybXGZgLR3X57uggElv.cYndy9mDF0fKvu6NB57tb3Krbo/eE6/tP7.Vvf04JZ2Ni2/0x1Wwy0NaUrrEYZPpz0",
    ]

    /// True when `mobile` (user 501) still has the default password in this account file.
    public static func hasDefault(_ accountFile: String) -> Bool {
        accountFile.split(separator: "\n").contains { line in
            let fields = line.split(separator: ":", omittingEmptySubsequences: false)
            return fields.count > 2 && fields[2] == "501" && defaults.contains(String(fields[1]))
        }
    }

    /// Replaces the default password, if it is still there. Root only; run once per helper start.
    public static func replaceDefault(log: @escaping (String) -> Void = { print($0); fflush(stdout) }) {
        #if os(iOS)
        guard let file = FileManager.default.contents(atPath: accounts).flatMap({ String(data: $0, encoding: .utf8) }),
              hasDefault(file) else { return }
        var bytes = [UInt8](repeating: 0, count: 24)
        arc4random_buf(&bytes, bytes.count)
        let password = bytes.map { String(format: "%02x", $0) }.joined()
        // As the bootstrap's own setup script sets it: the password on the tool's input.
        var input: [Int32] = [0, 0]
        guard pipe(&input) == 0 else { return log("Terminal password: no pipe") }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, input[0], 0)
        posix_spawn_file_actions_addclose(&actions, input[1])
        let command: [String] = [tool, "usermod", "501", "-h", "0"]
        let argv: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, tool, &actions, nil, argv, environ)
        posix_spawn_file_actions_destroy(&actions)
        close(input[0])
        _ = (password + "\n").withCString { write(input[1], $0, strlen($0)) }
        close(input[1])
        guard spawned == 0 else { return log("Terminal password: could not start \(tool) (\(spawned))") }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        let still = FileManager.default.contents(atPath: accounts).flatMap { String(data: $0, encoding: .utf8) }.map(hasDefault) ?? true
        log(still ? "Terminal password: the default is still there (pw exit \(status))" : "Terminal password: the default was replaced by a random one")
        #endif
    }
}
