import Foundation

#if os(Linux)
/// A fail-closed bubblewrap boundary for downloaded stdio connectors. It exposes the system
/// runtime read-only plus one private writable folder, no checkout, runner home, Docker socket,
/// host processes, or network namespace.
enum ConnectorSandbox {
    struct Invocation: Sendable {
        var executable: String
        var arguments: [String]
    }

    static func invocation(command: [String], directory: URL) throws -> Invocation {
        let bwrap = "/usr/bin/bwrap"
        guard FileManager.default.isExecutableFile(atPath: bwrap) else {
            throw ToolInputError("This runner cannot safely start downloaded connectors because bubblewrap is unavailable.")
        }
        guard !command.isEmpty else { throw ToolInputError("The connector command is empty.") }
        let root = directory.standardizedFileURL.path
        var arguments = [
            "--die-with-parent", "--new-session", "--unshare-all",
            "--proc", "/proc", "--dev", "/dev",
            "--ro-bind", "/usr", "/usr",
            "--bind", root, root,
            "--tmpfs", "/tmp",
            "--dir", "/home", "--dir", "/home/connector",
            "--chdir", root,
            "--setenv", "HOME", "/home/connector",
            "--setenv", "TMPDIR", "/tmp",
            "--setenv", "PATH", "/usr/local/bin:/usr/bin:/bin",
        ]
        for path in ["/bin", "/lib", "/lib64"] where FileManager.default.fileExists(atPath: path) {
            arguments += ["--ro-bind", path, path]
        }
        arguments += [
            "--", "/usr/bin/prlimit",
            "--nproc=64", "--nofile=256", "--as=2147483648", "--cpu=300", "--fsize=268435456",
            "--", "/usr/bin/env",
        ] + command
        return Invocation(executable: bwrap, arguments: arguments)
    }
}
#endif
