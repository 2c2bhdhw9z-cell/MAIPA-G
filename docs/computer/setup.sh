#!/usr/bin/env bash
# Sets up MAIPA-G's standard tool set on an Ubuntu or Debian computer, such as a Fly.io Sprite.
# The AI runs it the first time it uses a chat's computer:
#
#   curl -fsSL https://raw.githubusercontent.com/2c2bhdhw9z-cell/MAIPA-G/main/docs/computer/setup.sh | bash
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

install_node() {
  if fetch https://deb.nodesource.com/setup_lts.x "$TMP_DIR/nodesource_setup.sh" &&
    as_root bash "$TMP_DIR/nodesource_setup.sh" &&
    apt_install nodejs; then
    return 0
  fi
  echo "NodeSource didn't work, so trying this release's own nodejs and npm."
  apt_install nodejs npm
}

npm_global() {
  local prefix=""
  prefix=$(npm config get prefix 2>/dev/null) || prefix=""
  if [ "$(id -u)" -eq 0 ] || { [ -n "$prefix" ] && [ -w "$prefix/lib" ] && [ -w "$prefix/bin" ]; }; then
    npm install -g "$@"
  else
    as_root "$(command -v npm)" install -g "$@"
  fi
}

install_uv() {
  fetch https://astral.sh/uv/install.sh "$TMP_DIR/uv-install.sh" &&
    env UV_NO_MODIFY_PATH=1 sh "$TMP_DIR/uv-install.sh"
}

install_rust() {
  if have rustup; then
    # rustup is there but has no working toolchain, as after a stopped run.
    rustup default stable
    return
  fi
  fetch https://sh.rustup.rs "$TMP_DIR/rustup-init.sh" &&
    sh "$TMP_DIR/rustup-init.sh" -y --no-modify-path
}

install_dotnet() {
  fetch https://dot.net/v1/dotnet-install.sh "$TMP_DIR/dotnet-install.sh" &&
    bash "$TMP_DIR/dotnet-install.sh" --channel LTS --install-dir "$HOME/.dotnet"
}

install_bun() {
  fetch https://bun.sh/install "$TMP_DIR/bun-install.sh" && bash "$TMP_DIR/bun-install.sh"
}

install_deno() {
  # With its output going to the log the installer asks nothing and leaves shell files alone.
  fetch https://deno.land/install.sh "$TMP_DIR/deno-install.sh" && sh "$TMP_DIR/deno-install.sh"
}

# swift.org's swiftly steps, without questions: set swiftly up, install the latest Swift, then
# install the system packages that Swift release asks for.
install_swift() {
  local swiftly_home="${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}"
  local swiftly="${SWIFTLY_BIN_DIR:-$swiftly_home/bin}/swiftly"
  if [ ! -x "$swiftly" ]; then
    fetch "https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz" "$TMP_DIR/swiftly.tar.gz" &&
      tar -zxf "$TMP_DIR/swiftly.tar.gz" -C "$TMP_DIR" &&
      "$TMP_DIR/swiftly" init --assume-yes --quiet-shell-followup --skip-install || return 1
  fi
  if [ -f "$swiftly_home/env.sh" ]; then
    # shellcheck disable=SC1091
    . "$swiftly_home/env.sh"
  fi
  hash -r
  rm -f "$TMP_DIR/swift-post-install.sh"
  "$swiftly" install latest --use --assume-yes --post-install-file "$TMP_DIR/swift-post-install.sh" || return 1
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
playwright|playwright|playwright --version
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
  if [ -f "$STATE_DIR/playwright-chromium" ]; then
    say "  chromium     installed for Playwright"
  else
    say "  chromium     missing (for Playwright)"
  fi
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
    run_step "Node.js LTS" install_node || add_failure "Node.js"
  fi
  if have node && ! have npm; then
    run_step "npm" apt_install npm || add_failure "npm"
  fi
  if have npm; then
    have pnpm || globals="$globals pnpm"
    have yarn || globals="$globals yarn"
    have tsc || globals="$globals typescript"
    have playwright || globals="$globals playwright"
    if [ -n "$globals" ]; then
      # shellcheck disable=SC2086 # one word per package
      run_step "npm install -g$globals" npm_global $globals || add_failure "npm:$globals"
    fi
  fi
  if have npx && [ ! -f "$STATE_DIR/playwright-chromium" ]; then
    if run_step "Playwright's Chromium" npx --yes playwright install --with-deps chromium; then
      date -u '+%Y-%m-%dT%H:%M:%SZ' >"$STATE_DIR/playwright-chromium"
    else
      add_failure "Playwright's Chromium"
    fi
  fi

  if ! works uv --version; then
    run_step "uv" install_uv || add_failure "uv"
  fi
  if have uv; then
    have ruff || run_step "ruff (uv tool install)" uv tool install ruff || add_failure "ruff"
    have pytest || run_step "pytest (uv tool install)" uv tool install pytest || add_failure "pytest"
  fi

  if ! works cargo --version; then
    run_step "Rust (rustup)" install_rust || add_failure "Rust"
  fi
  if ! works dotnet --version; then
    run_step ".NET SDK (LTS)" install_dotnet || add_failure ".NET"
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
    run_step "Swift (swiftly)" install_swift || add_failure "Swift"
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
