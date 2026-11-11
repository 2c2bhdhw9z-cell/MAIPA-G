import Foundation

/// The phone's side of running work on the chat computer: install MAIPAGRunner there, hand it a
/// run, read its state, steer it and stop it. Every command is MAIPA-G's own code, run through the
/// computer connector's command tool; the model never chooses any of it.
public struct VMControl: Sendable {
    public let computer: ComputerControl
    /// Bytes per piece when a file crosses the command tool (base64 makes them a third bigger). A
    /// single command can't be much longer than 128 KB on Linux.
    public static let chunkBytes = 45_000
    /// Bytes per piece when reading a state back: smaller, as a connector may cap what one
    /// command's output can be.
    public static let readBytes = 30_000

    public init(computer: ComputerControl) { self.computer = computer }

    public enum Failure: LocalizedError, Sendable, CustomStringConvertible, Equatable {
        case badID, badRevision, noRunner, unexpected(String)
        public var description: String {
            switch self {
            case .badID: return "That isn't a run MAIPA-G started."
            case .badRevision: return "This build has no reviewed commit, so the runner can't be installed on the computer."
            case .noRunner: return "MAIPA-G's runner isn't installed on the computer yet."
            case .unexpected(let detail): return "The computer answered unexpectedly: \(detail.prefix(300))"
            }
        }
        public var errorDescription: String? { description }
    }

    public static func isRevision(_ value: String) -> Bool {
        value.count == 40 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    // MARK: Installing the runner

    public enum RunnerState: Equatable, Sendable {
        case ready
        case installing(step: String?)
        case failed(String)
    }

    /// Checks the runner for this app build, and starts installing it in the background when it
    /// isn't there: the reviewed release download first, built with Swift on the computer when
    /// that doesn't run there.
    public func ensureRunner(revision: String) async throws -> RunnerState {
        let output = ComputerControl.plainOutput(try await computer.run(try Self.ensureRunnerScript(revision: revision)))
        return Self.runnerState(output)
    }

    static func runnerState(_ output: String) -> RunnerState {
        if output.contains("maipa-g-runner-ready") { return .ready }
        if let failed = ComputerControl.note("maipa-g-runner-failed", in: output) { return .failed(failed) }
        if output.contains("maipa-g-runner-installing") { return .installing(step: ComputerControl.note("maipa-g-runner-step", in: output)) }
        return .failed(String(output.prefix(300)))
    }

    static func runnerFolder(_ revision: String) -> String { "\(VMRun.runnerRoot)/\(revision)" }

    static func ensureRunnerScript(revision: String) throws -> String {
        guard isRevision(revision) else { throw Failure.badRevision }
        return """
        set -u
        d="$HOME/\(runnerFolder(revision))"
        mkdir -p "$d"
        probe() { [ -x "$d/run.sh" ] && "$d/run.sh" --probe 2>/dev/null | grep -q maipag-runner-ok; }
        installing() { p=$(cat "$d/install.pid" 2>/dev/null); [ -n "$p" ] && tr '\\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q 'install\\.sh'; }
        if [ -f "$d/ready" ] && probe; then echo maipa-g-runner-ready; exit 0; fi
        if installing; then
          echo maipa-g-runner-installing
          grep '^==> ' "$d/install.log" 2>/dev/null | tail -n 1 | cut -c1-160 | sed 's/^==> /maipa-g-runner-step: /'
          exit 0
        fi
        if [ -f "$d/failed" ] && [ $(( $(date +%s) - $(stat -c %Y "$d/failed" 2>/dev/null || echo 0) )) -lt 600 ]; then
          echo "maipa-g-runner-failed: $(tail -n 1 "$d/failed" | cut -c1-300)"; exit 0
        fi
        rm -f "$d/failed" "$d/ready"
        cat > "$d/install.sh" <<'MAIPA_G_INSTALL'
        \(installScript)
        MAIPA_G_INSTALL
        if [ -d /proc/$$/fd ]; then
          for fd in /proc/$$/fd/*; do fd=${fd##*/}; case "$fd" in 0|1|2) ;; *) eval "exec $fd>&-" 2>/dev/null || true ;; esac; done
        fi
        if command -v setsid >/dev/null 2>&1; then
          setsid nohup bash "$d/install.sh" '\(revision)' > "$d/install.log" 2>&1 < /dev/null &
        else
          nohup bash "$d/install.sh" '\(revision)' > "$d/install.log" 2>&1 < /dev/null &
        fi
        echo $! > "$d/install.pid"
        echo maipa-g-runner-installing
        echo "maipa-g-runner-step: Starting"
        """
    }

    /// Installs the runner for one revision. Runs in the background on the computer.
    static let installScript = #"""
    set -uo pipefail
    rev="$1"
    d="$HOME/.maipa-g/runner/$rev"
    echo $$ > "$d/install.pid"
    . "$HOME/.maipa-g/env.sh" 2>/dev/null || true
    export PATH="$HOME/.local/share/swiftly/bin:$HOME/.local/bin:$PATH"
    fail() { echo "$1" > "$d/failed"; echo "==> $1"; exit 1; }
    libs() { command -v swift >/dev/null 2>&1 || return 0; swift -print-target-info 2>/dev/null | tr -d '\n' | sed -n 's/.*"runtimeLibraryPaths"[^[]*\[[^"]*"\([^"]*\)".*/\1/p'; }
    write_wrapper() {
      lib=$(libs)
      {
        echo '#!/bin/bash'
        [ -n "$lib" ] && echo "export LD_LIBRARY_PATH=\"$lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}\""
        echo "exec \"$d/bin/MAIPAGRunner\" \"\$@\""
      } > "$d/run.sh"
      chmod 0755 "$d/run.sh"
    }
    probe() { "$d/run.sh" --probe 2>/dev/null | grep -q maipag-runner-ok; }
    mkdir -p "$d/bin" "$d/scripts"
    curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "$d/scripts/check-ipa.py" "https://raw.githubusercontent.com/2c2bhdhw9z-cell/MAIPA-G/$rev/scripts/check-ipa.py" 2>/dev/null || rm -f "$d/scripts/check-ipa.py"
    if [ "$(uname -m)" = x86_64 ]; then
      echo "==> Downloading MAIPA-G's runner for this app build"
      base="https://github.com/2c2bhdhw9z-cell/MAIPA-G/releases/download/runner-$rev"
      tmp=$(mktemp -d)
      if curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "$tmp/MAIPAGRunner-linux-x86_64.tar.gz" "$base/MAIPAGRunner-linux-x86_64.tar.gz" &&
         curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "$tmp/sum" "$base/MAIPAGRunner-linux-x86_64.tar.gz.sha256" &&
         (cd "$tmp" && sha256sum -c sum >/dev/null) &&
         tar -C "$tmp" -xzf "$tmp/MAIPAGRunner-linux-x86_64.tar.gz" MAIPAGRunner; then
        install -m 0755 "$tmp/MAIPAGRunner" "$d/bin/MAIPAGRunner"
        write_wrapper
        if probe; then rm -rf "$tmp"; touch "$d/ready"; echo "==> Runner ready"; exit 0; fi
        echo "==> The downloaded runner doesn't start with this computer's Swift, so it is built here instead"
      fi
      rm -rf "$tmp"
    fi
    command -v swift >/dev/null 2>&1 || fail "Swift isn't on this computer yet, so MAIPA-G's runner can't be built. Let MAIPA-G's tool setup finish first."
    echo "==> Building MAIPA-G's runner with Swift on this computer (the first build takes a while)"
    src="$HOME/.maipa-g/runner/src"
    mkdir -p "$src" && cd "$src" || fail "Couldn't make $src."
    [ -d .git ] || git init -q
    git remote remove origin >/dev/null 2>&1 || true
    git remote add origin https://github.com/2c2bhdhw9z-cell/MAIPA-G.git
    git fetch -q --depth 1 origin "$rev" || fail "Couldn't download MAIPA-G's source at $rev."
    git checkout -q --force --detach FETCH_HEAD || fail "Couldn't check out MAIPA-G's source."
    [ "$(git rev-parse HEAD)" = "$rev" ] || fail "The source didn't match this app build."
    swift build -c release --package-path AgentCore --product MAIPAGRunner || fail "Building the runner failed; the log is ~/.maipa-g/runner/$rev/install.log."
    install -m 0755 AgentCore/.build/release/MAIPAGRunner "$d/bin/MAIPAGRunner"
    write_wrapper
    probe || fail "The runner was built but doesn't start."
    touch "$d/ready"
    echo "==> Runner ready"
    """#

    // MARK: Handing over a run

    public enum Mode: String, Sendable { case turn, job }

    /// Puts the request and the keys on the computer and starts the runner. The keys go to a file
    /// only the computer's user can read (made under umask 077), which the runner deletes as soon
    /// as it has read them.
    public func start(id: String, mode: Mode, revision: String, request: Data, secrets: VMSecrets) async throws {
        guard VMRun.isRunID(id) else { throw Failure.badID }
        guard Self.isRevision(revision) else { throw Failure.badRevision }
        try await upload(request, to: "\(VMRun.folder(id))/request.json.gz")
        try await upload(try VMCoding.pack(secrets), to: "\(VMRun.folder(id))/secrets.json.gz")
        let output = ComputerControl.plainOutput(try await computer.run(Self.launchScript(id: id, mode: mode, revision: revision)))
        if output.contains("maipa-g-no-runner") { throw Failure.noRunner }
        guard output.contains("maipa-g-run-started") else { throw Failure.unexpected(output) }
    }

    /// Writes a file in pieces small enough for one command each.
    public func upload(_ data: Data, to homeRelativePath: String) async throws {
        guard ComputerControl.isSafeRelativePath(homeRelativePath) else { throw Failure.badID }
        for script in Self.uploadScripts(data, to: homeRelativePath) {
            let output = ComputerControl.plainOutput(try await computer.run(script))
            guard output.contains("maipa-g-upload-ok") else { throw Failure.unexpected(output) }
        }
    }

    static func uploadScripts(_ data: Data, to path: String) -> [String] {
        let file = "\"$HOME/\(path)\""
        var pieces: [Data] = []
        var offset = 0
        repeat {
            let end = min(offset + chunkBytes, data.count)
            pieces.append(data.subdata(in: offset..<end))
            offset = end
        } while offset < data.count
        return pieces.enumerated().map { index, piece in
            var script = "set -eu\numask 077\n"
            if index == 0 { script += "mkdir -p \"$(dirname \(file))\"\n: > \(file).part\n" }
            script += "base64 -d >> \(file).part <<'MAIPA_G_DATA'\n\(piece.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed]))\nMAIPA_G_DATA\n"
            if index == pieces.count - 1 { script += "mv -f \(file).part \(file)\n" }
            script += "echo maipa-g-upload-ok\n"
            return script
        }
    }

    static func launchScript(id: String, mode: Mode, revision: String) -> String {
        """
        set -eu
        umask 077
        d="$HOME/\(VMRun.folder(id))"
        r="$HOME/\(runnerFolder(revision))/run.sh"
        [ -x "$r" ] && [ -f "$HOME/\(runnerFolder(revision))/ready" ] || { echo maipa-g-no-runner; exit 0; }
        mkdir -p "$d/steer"
        cat > "$d/launch.sh" <<'MAIPA_G_LAUNCH'
        \(launchBody)
        MAIPA_G_LAUNCH
        if [ -d /proc/$$/fd ]; then
          for fd in /proc/$$/fd/*; do fd=${fd##*/}; case "$fd" in 0|1|2) ;; *) eval "exec $fd>&-" 2>/dev/null || true ;; esac; done
        fi
        if command -v setsid >/dev/null 2>&1; then
          setsid nohup bash "$d/launch.sh" "$r" \(mode.rawValue) "$d" > "$d/runner.log" 2>&1 < /dev/null &
        else
          nohup bash "$d/launch.sh" "$r" \(mode.rawValue) "$d" > "$d/runner.log" 2>&1 < /dev/null &
        fi
        echo $! > "$d/runner.pid"
        echo maipa-g-run-started
        """
    }

    /// Runs the runner and holds the Sprite awake while it works, the way the tool setup does
    /// (docs.fly.io/sprites/keeping-sprites-running): a 5-minute task renewed every minute and
    /// removed at the end. It runs out by itself if everything is killed, and the hold ends after
    /// 12 hours in any case. `awake` says whether the hold worked, so the app can say so.
    static let launchBody = #"""
    r="$1"; mode="$2"; d="$3"
    sock=/.sprite/api.sock
    task="maipa-g-$(basename "$d")"
    sprite_task() {
      curl -fsS --max-time 15 --unix-socket "$sock" -H 'Content-Type: application/json' "$@" >/dev/null 2>&1 && return 0
      sudo -n curl -fsS --max-time 15 --unix-socket "$sock" -H 'Content-Type: application/json' "$@" >/dev/null 2>&1
    }
    sprite_env_curl() {
      for b in /.sprite/bin/sprite-env "$(command -v sprite-env 2>/dev/null)"; do
        [ -n "$b" ] && [ -x "$b" ] && "$b" curl -fsS -H 'Content-Type: application/json' "$@" >/dev/null 2>&1 && return 0
      done
      return 1
    }
    renew() {
      sprite_task -X PUT "http://sprite/v1/tasks/$task" -d '{ "expire": "5m" }' && return 0
      sprite_task -X POST "http://sprite/v1/tasks" -d "{ \"name\": \"$task\", \"expire\": \"5m\" }" && return 0
      sprite_env_curl -X PUT "/v1/tasks/$task" -d '{ "expire": "5m" }' && return 0
      sprite_env_curl -X POST "/v1/tasks" -d "{ \"name\": \"$task\", \"expire\": \"5m\" }"
    }
    hold=""
    if [ -S "$sock" ] || [ -x /.sprite/bin/sprite-env ]; then
      if renew; then
        echo on > "$d/awake"
        ( stop_at=$(( $(date +%s) + 43200 )); while sleep 60 && [ "$(date +%s)" -lt "$stop_at" ]; do renew || true; done ) </dev/null >/dev/null 2>&1 &
        hold=$!
      else
        echo off > "$d/awake"
      fi
    else
      echo none > "$d/awake"
    fi
    "$r" "$mode" "$d"
    code=$?
    [ -n "$hold" ] && kill "$hold" 2>/dev/null
    sprite_task -X DELETE "http://sprite/v1/tasks/$task" || sprite_env_curl -X DELETE "/v1/tasks/$task" || true
    echo "maipa-g-runner-exit $code"
    exit $code
    """#

    // MARK: Following a run

    public struct Poll: Sendable, Equatable {
        /// The newest state number, 0 before the first.
        public var seq: Int
        public var runnerAlive: Bool
        /// "on" (held awake), "off" (couldn't be), "none" (not a Sprite) or "unknown".
        public var awake: String
        public var state: VMTurnState?
        /// The run's folder is gone (cleaned up, or the machine was replaced).
        public var missing: Bool
    }

    /// The run's newest state, when it is newer than `after`.
    public func poll(id: String, after: Int) async throws -> Poll {
        guard VMRun.isRunID(id) else { throw Failure.badID }
        let output = ComputerControl.plainOutput(try await computer.run(Self.pollScript(id: id, after: after)))
        var poll = try Self.parsePoll(output)
        guard !poll.missing, poll.seq > after, let size = Self.number(after: "maipa-g-size", in: output), size > 0 else { return poll }
        var data = Self.base64Payload(in: output) ?? Data()
        while data.count < size {
            let more = ComputerControl.plainOutput(try await computer.run(Self.readScript(id: id, seq: poll.seq, offset: data.count)))
            guard let piece = Self.base64Payload(in: more), !piece.isEmpty else { break }
            data.append(piece)
        }
        guard data.count == size else { return poll }
        poll.state = try VMCoding.unpack(VMTurnState.self, from: data)
        return poll
    }

    static func pollScript(id: String, after: Int) -> String {
        """
        d="$HOME/\(VMRun.folder(id))"
        [ -d "$d" ] || { echo "maipa-g-poll-missing"; exit 0; }
        s=$(cat "$d/seq" 2>/dev/null | tr -dc 0-9); s=${s:-0}
        p=$(cat "$d/runner.pid" 2>/dev/null | tr -dc 0-9)
        alive=0
        if [ -n "$p" ] && [ -r "/proc/$p/stat" ] && [ "$(sed 's/.*) //' "/proc/$p/stat" | cut -d' ' -f1)" != Z ]; then alive=1; fi
        echo "maipa-g-poll $s $alive $(cat "$d/awake" 2>/dev/null || echo unknown)"
        if [ "$s" -gt \(after) ]; then
          f="$d/state/$s.json.gz"
          echo "maipa-g-size $(stat -c %s "$f" 2>/dev/null || echo 0)"
          echo "maipa-g-data $(head -c \(readBytes) "$f" 2>/dev/null | base64 -w0)"
        fi
        """
    }

    static func readScript(id: String, seq: Int, offset: Int) -> String {
        readScript(path: "\(VMRun.folder(id))/state/\(seq).json.gz", offset: offset)
    }

    static func readScript(path: String, offset: Int) -> String {
        "f=\"$HOME/\(path)\"; echo \"maipa-g-size $(stat -c %s \"$f\" 2>/dev/null || echo 0)\"; echo \"maipa-g-data $(tail -c +\(offset + 1) \"$f\" 2>/dev/null | head -c \(readBytes) | base64 -w0)\""
    }

    /// The staged files the runner wrote as `version`; nil if that version is already gone.
    public func readStaged(id: String, version: Int) async throws -> [CheckpointFile]? {
        guard VMRun.isRunID(id) else { throw Failure.badID }
        let path = "\(VMRun.folder(id))/staged/\(version).json.gz"
        let first = ComputerControl.plainOutput(try await computer.run(Self.readScript(path: path, offset: 0)))
        guard let size = Self.number(after: "maipa-g-size", in: first), size > 0 else { return nil }
        var data = Self.base64Payload(in: first) ?? Data()
        while data.count < size {
            let more = ComputerControl.plainOutput(try await computer.run(Self.readScript(path: path, offset: data.count)))
            guard let piece = Self.base64Payload(in: more), !piece.isEmpty else { return nil }
            data.append(piece)
        }
        guard data.count == size else { return nil }
        return try VMCoding.unpack([CheckpointFile].self, from: data)
    }

    static func parsePoll(_ output: String) throws -> Poll {
        if output.contains("maipa-g-poll-missing") { return Poll(seq: 0, runnerAlive: false, awake: "unknown", state: nil, missing: true) }
        guard let line = output.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("maipa-g-poll ") }) else { throw Failure.unexpected(output) }
        let parts = line.split(separator: " ")
        guard parts.count >= 3, let seq = Int(parts[1]) else { throw Failure.unexpected(output) }
        return Poll(seq: seq, runnerAlive: parts[2] == "1", awake: parts.count > 3 ? String(parts[3]) : "unknown", state: nil, missing: false)
    }

    static func number(after marker: String, in output: String) -> Int? {
        output.split(whereSeparator: \.isNewline).first { $0.hasPrefix(marker + " ") }.flatMap { Int($0.dropFirst(marker.count + 1).trimmingCharacters(in: .whitespaces)) }
    }

    static func base64Payload(in output: String) -> Data? {
        guard let line = output.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("maipa-g-data") }) else { return nil }
        let text = line.dropFirst("maipa-g-data".count).trimmingCharacters(in: .whitespaces)
        return Data(base64Encoded: text)
    }

    // MARK: Steering, stopping, tidying

    public func steer(id: String, text: String) async throws {
        guard VMRun.isRunID(id) else { throw Failure.badID }
        let name = String(format: "%013.0f", Date().timeIntervalSince1970 * 1000) + "-" + UUID().uuidString.prefix(8).lowercased()
        let output = ComputerControl.plainOutput(try await computer.run("""
        set -eu
        d="$HOME/\(VMRun.folder(id))/steer"
        mkdir -p "$d"
        base64 -d > "$d/\(name).part" <<'MAIPA_G_DATA'
        \(Data(text.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed]))
        MAIPA_G_DATA
        mv -f "$d/\(name).part" "$d/\(name).txt"
        echo maipa-g-steer-ok
        """))
        guard output.contains("maipa-g-steer-ok") else { throw Failure.unexpected(output) }
    }

    /// Asks the runner to stop the gentle way (it finishes writing its state), and ends its whole
    /// process group if it hasn't gone after a few seconds.
    public func stop(id: String) async throws {
        guard VMRun.isRunID(id) else { throw Failure.badID }
        _ = try await computer.run(Self.stopScript(id: id))
    }

    static func stopScript(id: String) -> String {
        """
        d="$HOME/\(VMRun.folder(id))"
        [ -d "$d" ] || { echo maipa-g-stopped; exit 0; }
        touch "$d/stop"
        p=$(cat "$d/runner.pid" 2>/dev/null | tr -dc 0-9)
        alive() { [ -n "$p" ] && [ -r "/proc/$p/stat" ] && [ "$(sed 's/.*) //' "/proc/$p/stat" | cut -d' ' -f1)" != Z ]; }
        i=0; while alive && [ $i -lt 60 ]; do sleep 0.1; i=$((i + 1)); done
        if alive; then kill -TERM -- "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null || true; sleep 1; fi
        if alive; then kill -KILL -- "-$p" 2>/dev/null || kill -KILL "$p" 2>/dev/null || true; fi
        echo maipa-g-stopped
        """
    }

    /// A fresh GitHub token for a long run; the runner takes and deletes it on its next use.
    public func handOverToken(id: String, token: String) async throws {
        try await upload(try VMCoding.pack(VMSecrets(openRouterKey: nil, githubToken: token)), to: "\(VMRun.folder(id))/token-refresh.json.gz")
    }

    /// Removes a finished run's folder (its keys were already deleted when it started).
    public func remove(id: String) async throws {
        guard VMRun.isRunID(id) else { throw Failure.badID }
        _ = try await computer.run("rm -rf \"$HOME/\(VMRun.folder(id))\"; echo maipa-g-removed")
    }
}
