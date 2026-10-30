#!/usr/bin/env bash
# Sets up MAIPA-G's standard tool set on an Ubuntu or Debian computer, such as a Fly.io Sprite.
# MAIPA-G's own code (never the AI) downloads this file from the app's exact reviewed commit,
# checks its SHA-256 against the copy compiled into the app, and only then runs it:
#
#   curl -o ~/.maipa-g-setup.sh https://raw.githubusercontent.com/2c2bhdhw9z-cell/MAIPA-G/<commit>/docs/computer/setup.sh
#   echo "<sha256>  $HOME/.maipa-g-setup.sh" | sha256sum -c - && bash ~/.maipa-g-setup.sh
#
# It installs only what is missing, so it is safe to run again, also after it stopped part way.
# One tool failing doesn't stop the rest; failures are listed at the end. The screen gets one line
# per step and a list of every tool with its version; the full output of each step goes to
# ~/.maipa-g/setup.log. At the end it writes ~/.maipa-g/ready with the date.

if [ -z "${BASH_VERSION:-}" ]; then
  echo "Please run this with bash." >&2
  exit 1
fi

set -u

have() { command -v "$1" >/dev/null 2>&1; }

# True when the command runs and succeeds, for tools a stopped run may have left half installed.
works() { "$@" >/dev/null 2>&1; }

# A short line on the screen, even while a step's own output goes to the log.
say() { printf '%s\n' "$*" >&3; }

add_failure() { FAILED="${FAILED:+$FAILED, }$1"; }

as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a "$@"
  elif have sudo; then
    sudo -n env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a "$@"
  else
    echo "This needs root, and sudo isn't installed: $*"
    return 1
  fi
}

# fetch URL FILE: downloads over HTTPS only, and to a file first, so an installer never runs
# half downloaded.
fetch() { curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --connect-timeout 20 -o "$2" "$1"; }

apt_install() {
  as_root apt-get install -y --no-install-recommends \
    -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

deb_installed() { dpkg-query -W -f='${Status}\n' "$1" 2>/dev/null | grep -q 'ok installed'; }

# run_step NAME COMMAND...: runs one step with its output in the log, and shows the end of that
# output when it fails.
run_step() {
  local name=$1 start=0
  shift
  say "==> $name"
  printf '\n===== %s  %s =====\n' "$(date -u '+%H:%M:%S')" "$name" >>"$LOG"
  start=$(wc -l <"$LOG")
  if "$@" >>"$LOG" 2>&1; then
    return 0
  fi
  say "    Failed. The end of its output (all of it is in $LOG):"
  tail -n +"$((start + 1))" "$LOG" | tail -n 12 | cut -c1-200 | sed 's/^/      /' >&3
  return 1
}

# apt package : the commands that show it is already there. No command means "ask dpkg".
APT_TOOLS='
ca-certificates:
gnupg:gpg
build-essential:
gcc:gcc
g++:g++
clang:clang
cmake:cmake
make:make
ninja-build:ninja
pkg-config:pkg-config
git:git
curl:curl
wget:wget
unzip:unzip
zip:zip
jq:jq
ripgrep:rg
fd-find:fdfind fd
sqlite3:sqlite3
cloc:cloc
imagemagick:magick convert
ffmpeg:ffmpeg
python3:python3
python3-pip:pip3
python3-venv:
pipx:pipx
maven:mvn
golang-go:go
ruby-full:ruby
default-jdk:javac
elixir:elixir
php-cli:php
composer:composer
'

missing_apt_packages() {
  local package="" commands="" cmd="" found=""
  while IFS=: read -r package commands; do
    [ -n "$package" ] || continue
    found=""
    if [ -n "$commands" ]; then
      for cmd in $commands; do
        if have "$cmd"; then
          found=yes
          break
        fi
      done
    elif deb_installed "$package"; then
      found=yes
    fi
    [ -n "$found" ] || printf '%s ' "$package"
  done <<EOF
$APT_TOOLS
EOF
  # .NET needs ICU. libicu-dev pulls in whichever libicuNN this release has.
  if ! works dotnet --version && ! dpkg-query -W -f='${Status}\n' 'libicu[0-9]*' 2>/dev/null | grep -q 'ok installed'; then
    printf '%s ' libicu-dev
  fi
}

install_apt_batch() {
  as_root dpkg --configure -a || true
  as_root apt-get update -o DPkg::Lock::Timeout=300 || echo "apt-get update failed; trying the install anyway."
  apt_install "$@"
}

# ---- Reviewed exact versions (lock manifest) --------------------------------------------------
# Every program this script downloads and runs or unpacks is an exact reviewed version, checked
# against the SHA-256 (or SHA-512) recorded here before it is used. Nothing follows a moving
# "latest" or pipes an installer into a shell. Updating a tool means changing its line here, and
# MAIPA-G's own copy of this file's checksum (SystemPrompt.computerSetupSHA256), in one review.
NODE_VERSION=v26.13.0
NODE_SHA256_X64=d28a96af6c38596f6d9d97c0ee531c13d238d757742387d1928de822d959e997
NODE_SHA256_ARM64=406fe3fbde1c054adff8b297c16fdb5af6659db327c1ac8acd46b56ef1af9a92
UV_VERSION=0.13.6
UV_SHA256_X64=f29c3e94ffabd7e6f3ba521dba169a9b7ec12100bf3257087f0f24f6123f3645
UV_SHA256_ARM64=229e194255c7958d86d56e8790d969a6f74736592133f0dfd0076f754c642c1d
RUFF_VERSION=0.17.3
RUFF_SHA256_X64=2b0890f5a55900af741f133918c2656919bbf18c2ab7741b4ca8403a90e647a9
RUFF_SHA256_ARM64=3f4639152c0e42bb5938e6c23d53d527a38f3133e000102934518f90529fa299
PYTEST_VERSION=9.2.0
RUSTUP_VERSION=1.29.2
RUSTUP_SHA256_X64=5be191e8c70a5007074254cb74d78dbfdd25cd5a61c27de7b8e5410122ec24f4
RUSTUP_SHA256_ARM64=a9c168dbea81a84671c6b7a5c1795cb0eb699020110d107ddfca427bd797e697
RUST_TOOLCHAIN=1.99.1
DOTNET_VERSION=10.0.403
DOTNET_SHA512_X64=b7b3d8461cf98b07d2552ce9199702fa3ad010ac2671a5f8cd5136f7534e50f6855ba7bbb02b11494563f1d04156276a31cda1103b900e5eecd0d9473dc7b9c5
DOTNET_SHA512_ARM64=0966aa2b70f4677b8319be9df447a78a0dcd6164836425b55a68fd714f4023feb87b4cac21b9a996b79472ad54487cd0adcd2a9dfd570e2b2a1d26423a2baa9b
BUN_VERSION=bun-v1.4.4
BUN_SHA256_X64=bf8ccbfb2b0b80159e0f9a6d15c55317add8077534dbc6130a3edb52fccb395c
BUN_SHA256_ARM64=baa6bb36f51d6e58561e02bbea825038a9df454f673d6d776e8bbf86f8c7850e
DENO_VERSION=v2.9.8
DENO_SHA256_X64=e890975bc2549807bbcc0b584ffafda72cc7c93349dd99c80483dd784f6c4609
DENO_SHA256_ARM64=d49596c20b9788cf8f5d8ddf644103d4bde56ed239753f0bdb92ba9361d51905
SWIFTLY_VERSION=1.2.0
SWIFTLY_SHA256_X64=0b26b568811404374c7d7f07276b6aad4145db5d1893a45f307de6a94ca8d9c3
SWIFTLY_SHA256_ARM64=590d855e03807791f1b84aab77471bf7e31f9e3b22151972526077da296ecf96
SWIFT_VERSION=6.4.2
# npm checks each package against the registry's SHA-512 integrity for these exact versions;
# --ignore-scripts keeps package install scripts from running.
NPM_GLOBALS="pnpm@12.16.1 yarn@1.22.22 typescript@7.0.2"

# The value for this machine's CPU: pick X86_64_VALUE ARM64_VALUE.
pick() {
  case "$(uname -m)" in
    x86_64 | amd64) printf '%s' "$1" ;;
    aarch64 | arm64) printf '%s' "$2" ;;
    *) echo "No reviewed build for $(uname -m)." >&2; return 1 ;;
  esac
}

# verified_fetch URL FILE CHECKSUM: downloads, then refuses the file unless its SHA-256 (or, for
# "sha512:…", SHA-512) matches the reviewed value exactly.
verified_fetch() {
  local url=$1 file=$2 expected=$3 actual=""
  fetch "$url" "$file" || return 1
  case "$expected" in
    sha512:*) expected=${expected#sha512:}; actual=$(sha512sum "$file" | cut -d' ' -f1) ;;
    *) actual=$(sha256sum "$file" | cut -d' ' -f1) ;;
  esac
  if [ -z "$expected" ] || [ "$actual" != "$expected" ]; then
    echo "Checksum mismatch for $url (expected $expected, got $actual). Not using it."
    rm -f "$file"
    return 1
  fi
}

install_node() {
  local arch sum dir tool
  arch=$(pick x64 arm64) && sum=$(pick "$NODE_SHA256_X64" "$NODE_SHA256_ARM64") || return 1
  verified_fetch "https://nodejs.org/dist/$NODE_VERSION/node-$NODE_VERSION-linux-$arch.tar.xz" "$TMP_DIR/node.tar.xz" "$sum" || return 1
  dir="$HOME/.local/node-$NODE_VERSION"
  rm -rf "$dir" && mkdir -p "$dir" "$HOME/.local/bin" &&
    tar -xJf "$TMP_DIR/node.tar.xz" -C "$dir" --strip-components=1 || return 1
  for tool in node npm npx; do ln -sf "$dir/bin/$tool" "$HOME/.local/bin/$tool"; done
}

npm_global() {
  local prefix=""
  prefix=$(npm config get prefix 2>/dev/null) || prefix=""
  if [ "$(id -u)" -eq 0 ] || { [ -n "$prefix" ] && [ -w "$prefix/lib" ] && [ -w "$prefix/bin" ]; }; then
    npm install -g --ignore-scripts --no-audit --no-fund "$@"
  else
    as_root "$(command -v npm)" install -g --ignore-scripts --no-audit --no-fund "$@"
  fi
}

# install_binary_tarball NAME URL CHECKSUM BINARY...: unpacks reviewed binaries into ~/.local/bin.
install_binary_tarball() {
  local name=$1 url=$2 sum=$3 binary="" found=""
  shift 3
  verified_fetch "$url" "$TMP_DIR/$name.tar.gz" "$sum" || return 1
  rm -rf "$TMP_DIR/$name" && mkdir -p "$TMP_DIR/$name" "$HOME/.local/bin" &&
    tar -xzf "$TMP_DIR/$name.tar.gz" -C "$TMP_DIR/$name" || return 1
  for binary in "$@"; do
    found=$(find "$TMP_DIR/$name" -type f -name "$binary" -perm -u+x | head -n 1)
    [ -n "$found" ] || { echo "$binary is missing from $url"; return 1; }
    install -m 0755 "$found" "$HOME/.local/bin/$binary" || return 1
  done
}

install_uv() {
  local triple
  triple=$(pick x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu) || return 1
  install_binary_tarball uv "https://github.com/astral-sh/uv/releases/download/$UV_VERSION/uv-$triple.tar.gz" \
    "$(pick "$UV_SHA256_X64" "$UV_SHA256_ARM64")" uv uvx
}

install_ruff() {
  local triple
  triple=$(pick x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu) || return 1
  install_binary_tarball ruff "https://github.com/astral-sh/ruff/releases/download/$RUFF_VERSION/ruff-$triple.tar.gz" \
    "$(pick "$RUFF_SHA256_X64" "$RUFF_SHA256_ARM64")" ruff
}

install_rust() {
  if have rustup; then
    # rustup is there but has no working toolchain, as after a stopped run.
    rustup default "$RUST_TOOLCHAIN"
    return
  fi
  local triple
  triple=$(pick x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu) || return 1
  verified_fetch "https://static.rust-lang.org/rustup/archive/$RUSTUP_VERSION/$triple/rustup-init" "$TMP_DIR/rustup-init" \
    "$(pick "$RUSTUP_SHA256_X64" "$RUSTUP_SHA256_ARM64")" || return 1
  chmod +x "$TMP_DIR/rustup-init" &&
    # rustup checks every toolchain component against the release manifest's hashes.
    "$TMP_DIR/rustup-init" -y --no-modify-path --profile minimal --default-toolchain "$RUST_TOOLCHAIN"
}

install_dotnet() {
  local arch
  arch=$(pick x64 arm64) || return 1
  verified_fetch "https://builds.dotnet.microsoft.com/dotnet/Sdk/$DOTNET_VERSION/dotnet-sdk-$DOTNET_VERSION-linux-$arch.tar.gz" "$TMP_DIR/dotnet.tar.gz" \
    "sha512:$(pick "$DOTNET_SHA512_X64" "$DOTNET_SHA512_ARM64")" || return 1
  mkdir -p "$HOME/.dotnet" && tar -xzf "$TMP_DIR/dotnet.tar.gz" -C "$HOME/.dotnet"
}

# install_binary_zip NAME URL CHECKSUM BINARY DESTINATION
install_binary_zip() {
  local name=$1 url=$2 sum=$3 binary=$4 destination=$5 found=""
  verified_fetch "$url" "$TMP_DIR/$name.zip" "$sum" || return 1
  rm -rf "$TMP_DIR/$name" && mkdir -p "$TMP_DIR/$name" "$destination" &&
    unzip -q -o "$TMP_DIR/$name.zip" -d "$TMP_DIR/$name" || return 1
  found=$(find "$TMP_DIR/$name" -type f -name "$binary" | head -n 1)
  [ -n "$found" ] || { echo "$binary is missing from $url"; return 1; }
  install -m 0755 "$found" "$destination/$binary"
}

install_bun() {
  local arch
  arch=$(pick x64 aarch64) || return 1
  install_binary_zip bun "https://github.com/oven-sh/bun/releases/download/$BUN_VERSION/bun-linux-$arch.zip" \
    "$(pick "$BUN_SHA256_X64" "$BUN_SHA256_ARM64")" bun "$HOME/.bun/bin"
}

install_deno() {
  local arch
  arch=$(pick x86_64 aarch64) || return 1
  install_binary_zip deno "https://github.com/denoland/deno/releases/download/$DENO_VERSION/deno-$arch-unknown-linux-gnu.zip" \
    "$(pick "$DENO_SHA256_X64" "$DENO_SHA256_ARM64")" deno "$HOME/.deno/bin"
}

# swift.org's swiftly steps, without questions: set up the reviewed swiftly, install the reviewed
# Swift release (swiftly checks the toolchain's PGP signature), then the system packages it lists.
install_swift() {
  local swiftly_home="${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}"
  local swiftly="${SWIFTLY_BIN_DIR:-$swiftly_home/bin}/swiftly"
  if [ ! -x "$swiftly" ]; then
    verified_fetch "https://download.swift.org/swiftly/linux/swiftly-$SWIFTLY_VERSION-$(uname -m).tar.gz" "$TMP_DIR/swiftly.tar.gz" \
      "$(pick "$SWIFTLY_SHA256_X64" "$SWIFTLY_SHA256_ARM64")" &&
      tar -zxf "$TMP_DIR/swiftly.tar.gz" -C "$TMP_DIR" &&
      "$TMP_DIR/swiftly" init --assume-yes --quiet-shell-followup --skip-install || return 1
  fi
  if [ -f "$swiftly_home/env.sh" ]; then
    # shellcheck disable=SC1091
    . "$swiftly_home/env.sh"
  fi
  hash -r
  rm -f "$TMP_DIR/swift-post-install.sh"
  "$swiftly" install "$SWIFT_VERSION" --use --assume-yes --post-install-file "$TMP_DIR/swift-post-install.sh" || return 1
  if [ -s "$TMP_DIR/swift-post-install.sh" ]; then
    as_root bash "$TMP_DIR/swift-post-install.sh" || return 1
  fi
}

write_env_file() {
  cat >"$STATE_DIR/env.sh" <<'EOF'
# Written by MAIPA-G's computer setup (docs/computer/setup.sh): puts the tools it installs on PATH.
for maipa_g_dir in "$HOME/.local/bin" "$HOME/.cargo/bin" "$HOME/.dotnet" "$HOME/.dotnet/tools" "$HOME/.bun/bin" \
  "$HOME/.deno/bin" "$HOME/go/bin" "/usr/local/go/bin" "${SWIFTLY_BIN_DIR:-$HOME/.local/share/swiftly/bin}"; do
  case ":$PATH:" in
    *":$maipa_g_dir:"*) ;;
    *) if [ -d "$maipa_g_dir" ]; then PATH="$maipa_g_dir:$PATH"; fi ;;
  esac
done
unset maipa_g_dir
export PATH
if [ -x "$HOME/.dotnet/dotnet" ]; then export DOTNET_ROOT="$HOME/.dotnet"; fi
EOF
}

# Adds one line to ~/.profile and ~/.bashrc that loads env.sh, unless it is already there.
add_env_to_profiles() {
  local file=""
  for file in "$HOME/.profile" "$HOME/.bashrc"; do
    if [ -f "$file" ] && grep -qF '.maipa-g/env.sh' "$file"; then
      continue
    fi
    # shellcheck disable=SC2016 # $HOME is written as is, for the shell that reads the file
    printf '\n# Added by MAIPA-G: tools from docs/computer/setup.sh\nif [ -f "$HOME/.maipa-g/env.sh" ]; then . "$HOME/.maipa-g/env.sh"; fi\n' >>"$file" || return 1
  done
}

# label | commands that show it is installed | how to ask its version
# shellcheck disable=SC2016 # each check runs later in its own bash
TOOL_VERSIONS='
gcc|gcc|gcc --version
g++|g++|g++ --version
clang|clang|clang --version
cmake|cmake|cmake --version
make|make|make --version
ninja|ninja|ninja --version
pkg-config|pkg-config|pkg-config --version
git|git|git --version
curl|curl|curl --version
wget|wget|wget --version
unzip|unzip|unzip -v
zip|zip|zip -v | sed -n 2p
jq|jq|jq --version
ripgrep|rg|rg --version
fd|fd fdfind|if command -v fd >/dev/null; then fd --version; else fdfind --version; fi
sqlite3|sqlite3|sqlite3 --version
cloc|cloc|cloc --version
imagemagick|magick convert|if command -v magick >/dev/null; then magick -version; else convert -version; fi
ffmpeg|ffmpeg|ffmpeg -version
python3|python3|python3 --version
pip|python3|python3 -m pip --version
venv|python3|d=$(mktemp -d) && python3 -m venv "$d/v" && echo "python3 -m venv works"; s=$?; rm -rf "$d"; exit $s
pipx|pipx|pipx --version
uv|uv|uv --version
ruff|ruff|ruff --version
pytest|pytest|pytest --version
node|node|node --version
npm|npm|npm --version
pnpm|pnpm|pnpm --version
yarn|yarn|yarn --version
typescript|tsc|tsc --version
go|go|go version
rust|rustc|rustc --version
cargo|cargo|cargo --version
ruby|ruby|ruby --version
java|javac|javac -version
maven|mvn|mvn --version
elixir|elixir|elixir --version | grep Elixir
php|php|php --version
composer|composer|composer --version
dotnet|dotnet|dotnet --version
bun|bun|bun --version
deno|deno|deno --version
swift|swift|swift --version
'

first_line() { sed -n '/[^[:space:]]/{p;q;}' | cut -c1-100; }

report_versions() {
  local label="" commands="" probe="" cmd="" found="" out="" status=0
  say ""
  say "Tools:"
  while IFS='|' read -r label commands probe; do
    [ -n "$label" ] || continue
    found=""
    for cmd in $commands; do
      if have "$cmd"; then
        found=yes
        break
      fi
    done
    if [ -z "$found" ]; then
      out="missing"
    else
      if have timeout; then
        out=$(timeout 60 bash -o pipefail -c "$probe" 2>&1 </dev/null)
      else
        out=$(bash -o pipefail -c "$probe" 2>&1 </dev/null)
      fi
      status=$?
      if [ "$status" -eq 0 ] && [ -n "$out" ]; then
        out=$(printf '%s\n' "$out" | first_line)
      else
        out="installed, but its version check failed: $(printf '%s\n' "$out" | first_line)"
      fi
    fi
    say "$(printf '  %-12s %s' "$label" "$out")"
  done <<EOF
$TOOL_VERSIONS
EOF
}

main() {
  : "${HOME:=$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)}"
  : "${HOME:=/tmp}"
  export HOME
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 COMPOSER_ALLOW_SUPERUSER=1 COREPACK_ENABLE_DOWNLOAD_PROMPT=0
  # The folders this script installs into come first; the usual system folders are added at the
  # end in case this shell's PATH is bare.
  PATH="$HOME/.local/bin:$HOME/.cargo/bin:$HOME/.dotnet:$HOME/.dotnet/tools:$HOME/.bun/bin:$HOME/.deno/bin:$HOME/go/bin:/usr/local/go/bin:${SWIFTLY_BIN_DIR:-$HOME/.local/share/swiftly/bin}:${PATH:-}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  export PATH

  STATE_DIR="$HOME/.maipa-g"
  LOG="$STATE_DIR/setup.log"
  FAILED=""
  if ! mkdir -p "$STATE_DIR"; then
    echo "Couldn't make $STATE_DIR." >&2
    return 1
  fi
  : >"$LOG"
  TMP_DIR=$(mktemp -d 2>/dev/null) || TMP_DIR="/tmp/maipa-g-setup.$$"
  mkdir -p "$TMP_DIR"
  trap 'rm -rf "$TMP_DIR"' EXIT
  exec 3>&1

  say "Setting up this computer for MAIPA-G. Step details go to $LOG."

  # PATH first, so even a run that stops part way leaves the tools it got usable.
  write_env_file || add_failure "$STATE_DIR/env.sh"
  add_env_to_profiles || add_failure "PATH lines in ~/.profile and ~/.bashrc"

  local missing="" package="" globals=""
  if have apt-get && have dpkg-query; then
    missing=$(missing_apt_packages)
    if [ -n "$missing" ]; then
      # shellcheck disable=SC2086 # one word per package
      if ! run_step "apt-get install ${missing% }" install_apt_batch $missing; then
        say "    Trying them one at a time."
        for package in $missing; do
          run_step "apt-get install $package" apt_install "$package" || add_failure "$package"
        done
      fi
    fi
  else
    say "==> No apt-get here, so the system packages are skipped. This script is for Ubuntu and Debian."
    add_failure "system packages (no apt-get)"
  fi
  if ! have fd && have fdfind; then
    mkdir -p "$HOME/.local/bin" && ln -sf "$(command -v fdfind)" "$HOME/.local/bin/fd"
  fi

  if ! have node; then
    run_step "Node.js $NODE_VERSION" install_node || add_failure "Node.js"
  fi
  if have node && ! have npm; then
    run_step "npm" apt_install npm || add_failure "npm"
  fi
  if have npm; then
    local spec=""
    for spec in $NPM_GLOBALS; do
      case "$spec" in
        pnpm@*) have pnpm || globals="$globals $spec" ;;
        yarn@*) have yarn || globals="$globals $spec" ;;
        typescript@*) have tsc || globals="$globals $spec" ;;
      esac
    done
    if [ -n "$globals" ]; then
      # shellcheck disable=SC2086 # one word per package
      run_step "npm install -g$globals" npm_global $globals || add_failure "npm:$globals"
    fi
  fi
  # Playwright's browsers come from a download Playwright doesn't checksum, so this script no
  # longer installs them. Install Playwright in a project with its lockfile when a test needs it.

  if ! works uv --version; then
    run_step "uv" install_uv || add_failure "uv"
  fi
  if ! works ruff --version; then
    run_step "ruff $RUFF_VERSION" install_ruff || add_failure "ruff"
  fi
  if have uv; then
    # uv checks every wheel against the package index's SHA-256 for this exact version.
    have pytest || run_step "pytest $PYTEST_VERSION (uv tool install)" uv tool install "pytest==$PYTEST_VERSION" || add_failure "pytest"
  fi

  if ! works cargo --version; then
    run_step "Rust $RUST_TOOLCHAIN (rustup $RUSTUP_VERSION)" install_rust || add_failure "Rust"
  fi
  if ! works dotnet --version; then
    run_step ".NET SDK $DOTNET_VERSION" install_dotnet || add_failure ".NET"
  fi
  if [ -x "$HOME/.dotnet/dotnet" ]; then
    export DOTNET_ROOT="$HOME/.dotnet"
  fi
  if ! works bun --version; then
    run_step "Bun" install_bun || add_failure "Bun"
  fi
  if ! works deno --version; then
    run_step "Deno" install_deno || add_failure "Deno"
  fi
  if ! works swift --version; then
    run_step "Swift $SWIFT_VERSION (swiftly $SWIFTLY_VERSION)" install_swift || add_failure "Swift"
  fi
  hash -r

  report_versions

  {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
    if [ -n "$FAILED" ]; then
      printf 'failed: %s\n' "$FAILED"
    fi
  } >"$STATE_DIR/ready"

  say ""
  if [ -n "$FAILED" ]; then
    say "Finished, but these didn't install: $FAILED. The details are in $LOG."
  else
    say "Finished. Everything is installed."
  fi
  say "Wrote $STATE_DIR/ready. New login and interactive shells find the tools through ~/.profile and ~/.bashrc;"
  say "in any other shell, run . \$HOME/.maipa-g/env.sh first."
  return 0
}

# main reads from /dev/null, so nothing it starts can swallow the rest of this script when it
# arrives through a pipe, and nothing can wait for an answer that never comes.
main "$@" </dev/null
