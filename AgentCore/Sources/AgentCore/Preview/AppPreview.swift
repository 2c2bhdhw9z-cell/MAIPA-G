import Foundation

/// A live preview of the app being built, the way Rork and VibeCode show one (owner, 11 November
/// 2026). The chat computer runs the app's dev server (Expo, Vite, Next or a plain site) behind a
/// Cloudflare quick tunnel, so the app shows inside MAIPA-G and, for an Expo app, opens in Expo Go
/// on the iPhone. Changes show as soon as they are on the computer (the dev server reloads).
///
/// The tunnel's address is public while the preview runs: anyone with the random address could
/// open the app. The preview stops by itself after two hours, or with `app_preview stop`.
public enum AppPreview {
    /// cloudflared 2026.10.7, checked against these SHA-256 sums before it runs.
    public static let cloudflaredVersion = "2026.10.7"
    static let cloudflaredSHA256 = [
        "amd64": "1f99fb518b83dec2ba8d870a7cc991d82a77e6196295a3d2754ba17ab9f91872",
        "arm64": "3df43aedc9ff291d1735b5cb576cb97e0b157488796db2e32b28aecabb445775",
    ]
    public static let port = 8081
    public static let lifetimeSeconds = 7_200
    static let folder = ".maipa-g/preview"

    /// The state line the script writes: "starting", "failed: <why>", "ready <kind> <host> <folder>"
    /// or "stopped".
    public enum State: Equatable, Sendable {
        case starting(step: String?)
        case ready(LivePreviewLink)
        case failed(String)
        case stopped
    }

    public static func parse(state: String, progress: String) -> State {
        let line = state.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        if line.hasPrefix("failed:") { return .failed(String(line.dropFirst("failed:".count)).trimmingCharacters(in: .whitespaces)) }
        if line == "stopped" { return .stopped }
        let parts = line.split(separator: " ").map(String.init)
        if parts.count >= 3, parts[0] == "ready" {
            let kind = parts[1], host = parts[2], folder = parts.count > 3 ? parts[3] : "."
            guard host.hasSuffix(".trycloudflare.com"), host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }) else {
                return .failed("The tunnel gave an address MAIPA-G doesn't trust.")
            }
            return .ready(LivePreviewLink(webURL: "https://\(host)", expoGoURL: kind == "expo" ? "exps://\(host):8443" : nil, kind: kind, folder: folder))
        }
        let step = progress.split(whereSeparator: \.isNewline).last { $0.hasPrefix("==> ") }.map { String($0.dropFirst(4)) }
        return .starting(step: step)
    }

    static func isSafeFolder(_ value: String) -> Bool {
        value.isEmpty || value == "." || ComputerControl.isSafeRelativePath(value)
    }

    /// Runs in the background on the computer: `app-preview.sh <repo folder> [app folder]`.
    static let script = #"""
    #!/bin/bash
    set -u
    p="$1"; want="${2:-}"
    d="$HOME/.maipa-g/preview"; mkdir -p "$d"
    : > "$d/progress.log"
    log() { echo "==> $*" >> "$d/progress.log"; }
    fail() { echo "failed: $*" > "$d/state"; log "$*"; exit 1; }
    echo starting > "$d/state"
    . "$HOME/.maipa-g/env.sh" 2>/dev/null || true
    export PATH="$HOME/.local/bin:$PATH" EXPO_NO_TELEMETRY=1 BROWSER=none
    alive() { [ -n "$1" ] && [ -r "/proc/$1/stat" ] && [ "$(sed 's/.*) //' "/proc/$1/stat" | cut -d' ' -f1)" != Z ]; }
    # An earlier preview stops first, so the port is free.
    for f in server tunnel awake; do
      pid=$(cat "$d/$f.pid" 2>/dev/null | tr -dc 0-9); rm -f "$d/$f.pid"
      [ -n "$pid" ] && { kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null; } || true
    done
    sleep 1
    cd "$p" 2>/dev/null || fail "The repo isn't on the computer at $p."
    pick() {
      if [ -n "$want" ] && [ "$want" != . ]; then echo "$want"; return; fi
      for c in . app mobile apps/mobile apps/app native expo client; do
        [ -f "$c/package.json" ] && grep -q '"expo"' "$c/package.json" && { echo "$c"; return; }
      done
      for c in $(git ls-files 2>/dev/null | grep -E '(^|/)package\.json$' | grep -v node_modules | head -n 60); do
        grep -q '"expo"' "$c" && { dirname "$c"; return; }
      done
      [ -f package.json ] && { echo .; return; }
      for c in web site app frontend client; do [ -f "$c/package.json" ] && { echo "$c"; return; }; done
      [ -f index.html ] && { echo .; return; }
      for c in public docs site dist build; do [ -f "$c/index.html" ] && { echo "$c"; return; }; done
      echo ""
    }
    rel=$(pick)
    [ -n "$rel" ] || fail "No app or website was found in this repo (no package.json or index.html)."
    cd "$p/$rel" 2>/dev/null || fail "There's no folder $rel in the repo."
    kind=static
    if [ -f package.json ]; then
      if grep -q '"expo"' package.json; then kind=expo
      elif grep -q '"vite"' package.json; then kind=vite
      elif grep -q '"next"' package.json; then kind=next
      else kind=npm; fi
    fi
    log "Found a $kind app in $rel"
    pm=npm
    [ -f pnpm-lock.yaml ] && pm=pnpm
    [ -f yarn.lock ] && pm=yarn
    { [ -f bun.lockb ] || [ -f bun.lock ]; } && pm=bun
    if [ "$kind" != static ] && [ ! -d node_modules ]; then
      log "Installing the app's packages with $pm (the first time takes a few minutes)"
      case $pm in
        pnpm) pnpm install > "$d/install.log" 2>&1 ;;
        yarn) yarn install > "$d/install.log" 2>&1 ;;
        bun) bun install > "$d/install.log" 2>&1 ;;
        *) npm install --no-audit --no-fund > "$d/install.log" 2>&1 ;;
      esac || fail "Installing the app's packages failed; the log is ~/.maipa-g/preview/install.log."
    fi
    if [ "$kind" = expo ]; then
      missing=""
      for dep in react-native-web react-dom @expo/metro-runtime; do [ -d "node_modules/$dep" ] || missing="$missing $dep"; done
      if [ -n "$missing" ]; then
        log "Adding web support so the app shows inside MAIPA-G"
        npx --yes expo install $missing >> "$d/install.log" 2>&1 || log "Web support couldn't be added; Expo Go still works"
      fi
    fi
    cf="$HOME/.maipa-g/bin/cloudflared-@VERSION@"
    if [ ! -x "$cf" ]; then
      log "Downloading the preview tunnel (cloudflared @VERSION@)"
      mkdir -p "$HOME/.maipa-g/bin"
      case $(uname -m) in
        x86_64) a=amd64; sum=@AMD64@ ;;
        aarch64|arm64) a=arm64; sum=@ARM64@ ;;
        *) fail "There's no preview tunnel for this computer's processor ($(uname -m))." ;;
      esac
      curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "$cf.part" "https://github.com/cloudflare/cloudflared/releases/download/@VERSION@/cloudflared-linux-$a" || fail "Couldn't download the preview tunnel."
      echo "$sum  $cf.part" | sha256sum -c - > /dev/null 2>&1 || { rm -f "$cf.part"; fail "The downloaded tunnel didn't match its checksum, so it wasn't used."; }
      chmod 755 "$cf.part" && mv -f "$cf.part" "$cf"
    fi
    port=""
    for candidate in $(seq @PORT@ $((@PORT@ + 18))); do
      (exec 3<>"/dev/tcp/127.0.0.1/$candidate") 2>/dev/null || { port=$candidate; break; }
    done
    [ -n "$port" ] || fail "Every port from @PORT@ up is in use on the computer."
    log "Opening the preview tunnel"
    setsid nohup "$cf" tunnel --no-autoupdate --url "http://localhost:$port" > "$d/tunnel.log" 2>&1 < /dev/null &
    echo $! > "$d/tunnel.pid"
    host=""
    for i in $(seq 1 60); do
      host=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$d/tunnel.log" | head -n 1 | sed 's#https://##')
      [ -n "$host" ] && break
      sleep 1
    done
    [ -n "$host" ] || fail "The preview tunnel didn't open; the log is ~/.maipa-g/preview/tunnel.log."
    log "Starting the $kind dev server"
    case $kind in
      expo) EXPO_PACKAGER_PROXY_URL="https://$host:8443" setsid nohup npx expo start --port "$port" > "$d/server.log" 2>&1 < /dev/null & ;;
      vite) __VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS=".trycloudflare.com" setsid nohup npx vite --port "$port" --strictPort --host 0.0.0.0 > "$d/server.log" 2>&1 < /dev/null & ;;
      next) setsid nohup npx next dev -p "$port" -H 0.0.0.0 > "$d/server.log" 2>&1 < /dev/null & ;;
      npm) PORT="$port" HOST=0.0.0.0 setsid nohup npm run dev > "$d/server.log" 2>&1 < /dev/null & ;;
      static) setsid nohup python3 -m http.server "$port" --bind 127.0.0.1 > "$d/server.log" 2>&1 < /dev/null & ;;
    esac
    echo $! > "$d/server.pid"
    up=""
    for i in $(seq 1 240); do
      curl -fs -o /dev/null --max-time 5 "http://localhost:$port/" && { up=yes; break; }
      alive "$(cat "$d/server.pid")" || break
      sleep 1
    done
    [ -n "$up" ] || fail "The dev server didn't start: $(tail -n 3 "$d/server.log" 2>/dev/null | tr '\n' ' ' | cut -c1-300)"
    echo "ready $kind $host $rel" > "$d/state"
    log "Preview ready"
    # Keeps the computer awake while the preview runs (docs.fly.io/sprites/keeping-sprites-running),
    # then stops the preview after @LIFETIME@ seconds.
    (
      sock=/.sprite/api.sock; task=maipa-g-preview
      hold() {
        curl -fsS --max-time 15 --unix-socket "$sock" -H 'Content-Type: application/json' "$@" > /dev/null 2>&1 && return 0
        sudo -n curl -fsS --max-time 15 --unix-socket "$sock" -H 'Content-Type: application/json' "$@" > /dev/null 2>&1
      }
      renew() { hold -X PUT "http://sprite/v1/tasks/$task" -d '{ "expire": "5m" }' || hold -X POST "http://sprite/v1/tasks" -d "{ \"name\": \"$task\", \"expire\": \"5m\" }"; }
      stop_at=$(( $(date +%s) + @LIFETIME@ ))
      while [ "$(date +%s)" -lt "$stop_at" ] && alive "$(cat "$d/server.pid" 2>/dev/null)"; do renew || true; sleep 60; done
      hold -X DELETE "http://sprite/v1/tasks/$task" || true
      for f in server tunnel; do pid=$(cat "$d/$f.pid" 2>/dev/null | tr -dc 0-9); [ -n "$pid" ] && { kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null; }; done
      echo stopped > "$d/state"
    ) < /dev/null > /dev/null 2>&1 &
    echo $! > "$d/awake.pid"
    """#
        .replacingOccurrences(of: "@VERSION@", with: cloudflaredVersion)
        .replacingOccurrences(of: "@AMD64@", with: cloudflaredSHA256["amd64"]!)
        .replacingOccurrences(of: "@ARM64@", with: cloudflaredSHA256["arm64"]!)
        .replacingOccurrences(of: "@PORT@", with: String(port))
        .replacingOccurrences(of: "@LIFETIME@", with: String(lifetimeSeconds))

    static let statusScript = #"d="$HOME/.maipa-g/preview"; echo "maipa-g-state: $(head -n 1 "$d/state" 2>/dev/null || echo none)"; tail -n 3 "$d/progress.log" 2>/dev/null; echo "---"; tail -n 25 "$d/server.log" 2>/dev/null | cut -c1-300"#

    static let stopScript = #"""
    d="$HOME/.maipa-g/preview"
    for f in awake server tunnel script; do
      pid=$(cat "$d/$f.pid" 2>/dev/null | tr -dc 0-9); rm -f "$d/$f.pid"
      [ -n "$pid" ] && { kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null; } || true
    done
    curl -fsS --max-time 10 --unix-socket /.sprite/api.sock -X DELETE http://sprite/v1/tasks/maipa-g-preview > /dev/null 2>&1 || true
    echo stopped > "$d/state"
    echo maipa-g-preview-stopped
    """#
}

extension ComputerControl {
    /// Starts the preview script in the background and returns straight away.
    func startPreview(repoHome: String, folder: String?) async throws {
        guard Self.isSafeRelativePath(repoHome) else { throw Failure.commandFailed("Unsafe checkout path \(repoHome)") }
        guard AppPreview.isSafeFolder(folder ?? "") else { throw Failure.commandFailed("Unsafe app folder \(folder ?? "")") }
        try await writeFile(Data(AppPreview.script.utf8), toHomePath: "\(AppPreview.folder)/app-preview.sh")
        let output = try await run("""
        d="$HOME/\(AppPreview.folder)"; echo starting > "$d/state"; : > "$d/progress.log"
        if [ -d /proc/$$/fd ]; then
          for fd in /proc/$$/fd/*; do fd=${fd##*/}; case "$fd" in 0|1|2) ;; *) eval "exec $fd>&-" 2>/dev/null || true ;; esac; done
        fi
        setsid nohup bash "$d/app-preview.sh" "$HOME/\(repoHome)" \(Self.shellQuote(folder ?? "")) > "$d/script.log" 2>&1 < /dev/null &
        echo $! > "$d/script.pid"
        echo maipa-g-preview-started
        """)
        guard output.contains("maipa-g-preview-started") else { throw Failure.commandFailed(output) }
    }

    func previewStatus() async throws -> (state: AppPreview.State, log: String) {
        let output = Self.plainOutput(try await run(AppPreview.statusScript))
        let stateLine = Self.note("maipa-g-state", in: output) ?? "none"
        let state = stateLine == "none" ? AppPreview.State.stopped : AppPreview.parse(state: stateLine, progress: output)
        let log = output.components(separatedBy: "---").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (state, log)
    }
}

/// Lets the AI show the app it is building, live, while it works.
public struct AppPreviewTool: AgentTool {
    public let name = "app_preview"
    let control: ComputerControl
    let repoHome: String
    /// Puts the repo and the phone-staged changes on the computer first.
    let prepare: @Sendable () async throws -> Void
    let pollEvery: TimeInterval
    let waitUpTo: TimeInterval

    public init(control: ComputerControl, repoHome: String, prepare: @escaping @Sendable () async throws -> Void, pollEvery: TimeInterval = 3, waitUpTo: TimeInterval = 600) {
        self.control = control
        self.repoHome = repoHome
        self.prepare = prepare
        self.pollEvery = pollEvery
        self.waitUpTo = waitUpTo
    }

    public var spec: ToolSpec {
        ToolSpec(name: name, description: "Show the app being built, live, the way Rork and VibeCode do: runs the repo's Expo app (or Vite, Next or plain website) on the chat computer and gives a preview the person opens in MAIPA-G, plus an Expo Go link for Expo apps. Start it when you've made something they can look at, without being asked. It reloads by itself: after more edits, call sync_staged_to_computer and the preview updates. status shows the dev server's latest output (use it to find errors); stop ends it.", parameters: [
            "type": "object",
            "properties": [
                "operation": ["type": "string", "enum": ["start", "status", "stop"]],
                "folder": ["type": "string", "description": "Optional: the app's folder in the repo, when it isn't found by itself."],
            ],
            "required": ["operation"],
            "additionalProperties": false,
        ])
    }

    public var bringsOutsideContent: Bool { true }

    public func runningSummary(for arguments: JSONValue) -> String {
        switch arguments["operation"]?.stringValue {
        case "status": "Checking the preview…"
        case "stop": "Stopping the preview…"
        default: "Starting the live preview…"
        }
    }

    static func describe(_ link: LivePreviewLink) -> String {
        var text = "The live preview is running: \(link.webURL)"
        if let expo = link.expoGoURL { text += " (in Expo Go: \(expo))" }
        text += ". The person sees an Open preview card in the chat\(link.expoGoURL == nil ? "" : " with Open in Expo Go") — tell them it's there in one short line; don't paste the addresses. It updates by itself when changes reach the computer (sync_staged_to_computer), and stops by itself after two hours."
        return text
    }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        switch arguments["operation"]?.stringValue ?? "start" {
        case "status":
            let (state, log) = try await control.previewStatus()
            switch state {
            case .ready(let link):
                return ToolOutput(forModel: Self.describe(link) + "\nLatest dev server output:\n" + ConnectorOutputLimit.cap(log), summary: "The preview is running", livePreview: link)
            case .starting(let step):
                return ToolOutput(forModel: "The preview is still starting\(step.map { ": \($0)" } ?? "").", summary: "The preview is starting")
            case .failed(let why):
                return ToolOutput(forModel: "The preview failed: \(why)\nDev server output:\n\(ConnectorOutputLimit.cap(log))", summary: "The preview failed", isError: true)
            case .stopped:
                return ToolOutput(forModel: "No preview is running.", summary: "No preview running")
            }
        case "stop":
            _ = try await control.run(AppPreview.stopScript)
            return ToolOutput(forModel: "The preview is stopped and its address is closed.", summary: "Stopped the preview")
        case "start":
            let folder = arguments.optionalString("folder")?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard AppPreview.isSafeFolder(folder ?? "") else { throw ToolInputError("folder must be a folder inside the repo, such as app or apps/mobile.") }
            progress("Putting the latest changes on the computer…")
            try await prepare()
            try await control.startPreview(repoHome: repoHome, folder: folder)
            let started = Date()
            var lastStep = ""
            while Date().timeIntervalSince(started) < waitUpTo {
                try await Task.sleep(nanoseconds: UInt64(pollEvery * 1_000_000_000))
                let (state, log) = try await control.previewStatus()
                switch state {
                case .ready(let link):
                    return ToolOutput(forModel: Self.describe(link), summary: link.expoGoURL == nil ? "Live preview ready" : "Live preview ready · Expo Go", detail: link.webURL, livePreview: link)
                case .failed(let why):
                    throw ToolInputError("The preview didn't start: \(why)\(log.isEmpty ? "" : "\nDev server output:\n" + ConnectorOutputLimit.cap(log))")
                case .starting(let step):
                    if let step, step != lastStep { lastStep = step; progress(step + "…") }
                case .stopped:
                    break
                }
            }
            return ToolOutput(forModel: "The preview is still starting after \(Int(waitUpTo / 60)) minutes (\(lastStep)). Check again with app_preview status.", summary: "The preview is still starting")
        default:
            throw ToolInputError("operation must be start, status or stop.")
        }
    }
}
