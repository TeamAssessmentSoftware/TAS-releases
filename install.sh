#!/bin/sh
set -eu

repo="TeamAssessmentSoftware/TAS-releases"
base=${TAS_BASE_URL:-"https://github.com/$repo/releases/latest/download"}
earlier=wintas

say() { printf '%s\n' "$*"; }
die() { printf 'TAS install: %s\n' "$*" >&2; exit 1; }

action=install
mode=auto
for arg in "$@"; do
  case "$arg" in
    --uninstall) action=uninstall ;;
    --user) mode=user ;;
    -h|--help)
      say "Usage: install.sh [--user] [--uninstall]"
      say "Installs the latest TAS on Linux or macOS."
      say "On Linux it installs the .deb, .rpm or pacman package with your package manager, which also"
      say "installs the libraries TAS needs and opens its TAK network ports in the firewall."
      say "--user installs into ~/.local without sudo instead (no firewall rules)."
      exit 0 ;;
    *) die "unknown option $arg" ;;
  esac
done

fetch() {
  if command -v curl >/dev/null 2>&1; then
    curl -fSL --retry 3 --progress-bar -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -q --show-progress -O "$2" "$1"
  else
    die "curl or wget is needed"
  fi
}

sums() {
  [ -f "$tmp/SHA256SUMS" ] || fetch "$base/SHA256SUMS" "$tmp/SHA256SUMS" 2>/dev/null || die "could not download the release list from $base"
}

pick() {
  sums
  grep -E -e "[ *]tas-[0-9.]+-$1\$" "$tmp/SHA256SUMS" | head -n 1 | awk '{print $2}' | tr -d '*'
}

download() {
  asset=$1
  say "Downloading $asset"
  fetch "$base/$asset" "$tmp/$asset"
  line=$(grep -E -e "[ *]$asset\$" "$tmp/SHA256SUMS" | head -n 1)
  want=$(printf '%s' "${line%% *}" | tr 'A-F' 'a-f')
  if command -v sha256sum >/dev/null 2>&1; then
    got=$(sha256sum "$tmp/$asset" | cut -d' ' -f1)
  else
    got=$(shasum -a 256 "$tmp/$asset" | cut -d' ' -f1)
  fi
  [ -n "$want" ] && [ "$want" = "$got" ] || die "checksum mismatch for $asset"
}

tmp=$(mktemp -d 2>/dev/null || mktemp -d -t tas)
trap 'rm -rf "$tmp"' EXIT INT TERM

as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  elif command -v doas >/dev/null 2>&1; then
    doas "$@"
  else
    return 1
  fi
}

can_root() {
  [ "$(id -u)" -eq 0 ] || command -v sudo >/dev/null 2>&1 || command -v doas >/dev/null 2>&1
}

package_manager() {
  for pm in apt-get dnf yum zypper pacman; do
    if command -v "$pm" >/dev/null 2>&1; then
      printf '%s\n' "$pm"
      return
    fi
  done
}

installed() {
  if command -v dpkg-query >/dev/null 2>&1 && [ "$(dpkg-query -W -f '${Status}' "$1" 2>/dev/null || true)" = "install ok installed" ]; then
    return 0
  fi
  if command -v rpm >/dev/null 2>&1 && rpm -q "$1" >/dev/null 2>&1; then
    return 0
  fi
  if command -v pacman >/dev/null 2>&1 && pacman -Q "$1" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

remove_package() {
  name=$1
  installed "$name" || return 0
  say "Removing the $name package"
  if command -v apt-get >/dev/null 2>&1 && command -v dpkg-query >/dev/null 2>&1 && dpkg-query -W "$name" >/dev/null 2>&1; then
    as_root apt-get remove -y "$name"
  elif command -v pacman >/dev/null 2>&1 && pacman -Q "$name" >/dev/null 2>&1; then
    as_root pacman -R --noconfirm "$name"
  elif command -v zypper >/dev/null 2>&1; then
    as_root zypper --non-interactive remove "$name"
  elif command -v dnf >/dev/null 2>&1; then
    as_root dnf remove -y "$name"
  elif command -v yum >/dev/null 2>&1; then
    as_root yum remove -y "$name"
  else
    as_root rpm -e "$name"
  fi
}

install_package() {
  pm=$1
  case "$pm" in
    apt-get) asset=$(pick 'linux-amd64\.deb') ;;
    dnf|yum|zypper) asset=$(pick 'linux-x86_64\.rpm') ;;
    pacman) asset=$(pick 'linux-x64\.pacman') ;;
  esac
  [ -n "$asset" ] || return 1
  download "$asset"
  chmod 644 "$tmp/$asset"
  chmod 755 "$tmp"
  remove_package "$earlier"
  say "Installing $asset with $pm"
  case "$pm" in
    apt-get) as_root apt-get install -y "$tmp/$asset" ;;
    dnf|yum) as_root "$pm" install -y "$tmp/$asset" ;;
    zypper) as_root zypper --non-interactive install --allow-unsigned-rpm "$tmp/$asset" ;;
    pacman) as_root pacman -U --noconfirm --needed "$tmp/$asset" ;;
  esac
}

user_files() {
  data=${XDG_DATA_HOME:-$HOME/.local/share}
  bin=$HOME/.local/bin
  opt=$HOME/.local/opt/tas
  desktop=$data/applications/tas.desktop
  icon=$data/icons/hicolor/256x256/apps/tas.png
}

remove_user_files() {
  user_files
  rm -rf "$opt"
  rm -f "$bin/tas" "$desktop" "$icon"
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$data/applications" >/dev/null 2>&1 || true
}

install_user() {
  user_files
  asset=$(pick 'linux-x86_64\.tar\.gz')
  [ -n "$asset" ] || die "this release has no Linux tarball"
  download "$asset"
  mkdir -p "$tmp/unpacked"
  tar -xzf "$tmp/$asset" -C "$tmp/unpacked"
  [ -x "$tmp/unpacked/TAS/tas" ] || die "$asset does not hold TAS/tas"
  remove_user_files
  user_files
  mkdir -p "$(dirname "$opt")" "$bin" "$data/applications" "$(dirname "$icon")"
  mv "$tmp/unpacked/TAS" "$opt"
  ln -sf "$opt/tas" "$bin/tas"
  cp "$opt/tas.png" "$icon"
  sed -e "s#^Exec=.*#Exec=$opt/tas %f#" -e "s#^TryExec=.*##" "$opt/tas.desktop" > "$desktop"
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$data/applications" >/dev/null 2>&1 || true
  command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t "$data/icons/hicolor" >/dev/null 2>&1 || true
  say "TAS installed in $opt. Open it from your app menu, or run: $bin/tas"
  say "This install does not open the TAK network ports in your firewall; the package install does."
  case ":$PATH:" in
    *":$bin:"*) ;;
    *) say "Add $bin to your PATH to run tas from a terminal." ;;
  esac
}

install_linux() {
  case "$(uname -m)" in
    x86_64|amd64) ;;
    *) die "TAS is built for 64-bit Intel and AMD (x86_64) Linux only, and this is $(uname -m)" ;;
  esac
  if [ "$action" = uninstall ]; then
    remove_package tas
    remove_package "$earlier"
    remove_user_files
    say "TAS removed. Your settings and data stay in ~/.config and ~/.local/share under Team Assessment Software."
    return
  fi
  if [ "$mode" = auto ] && can_root; then
    pm=$(package_manager)
    if [ -n "$pm" ]; then
      if install_package "$pm"; then
        remove_user_files
        say "TAS installed. Open it from your app menu, or run: tas"
        return
      fi
      say "Installing the $pm package failed, so TAS goes into ~/.local instead."
    fi
  fi
  install_user
}

install_macos() {
  if [ "$action" = uninstall ]; then
    rm -rf /Applications/TAS.app "$HOME/Applications/TAS.app" /Applications/WinTAS.app "$HOME/Applications/WinTAS.app"
    say "TAS removed."
    return
  fi
  if [ "$(uname -m)" = arm64 ] && ! /usr/bin/pgrep -q oahd; then
    say "TAS is an Intel app, so this Mac needs Rosetta 2. Installing it."
    softwareupdate --install-rosetta --agree-to-license || die "Rosetta 2 did not install; run: softwareupdate --install-rosetta"
  fi
  asset=$(pick 'macos-x86_64\.tar\.gz')
  [ -n "$asset" ] || die "this release has no macOS build"
  download "$asset"
  mkdir -p "$tmp/app"
  tar -xzf "$tmp/$asset" -C "$tmp/app"
  [ -d "$tmp/app/TAS.app" ] || die "$asset does not hold TAS.app"
  dest=/Applications
  if [ ! -w "$dest" ]; then
    dest=$HOME/Applications
    mkdir -p "$dest"
  fi
  rm -rf "$dest/TAS.app" "$dest/WinTAS.app"
  ditto "$tmp/app/TAS.app" "$dest/TAS.app"
  xattr -dr com.apple.quarantine "$dest/TAS.app" 2>/dev/null || true
  say "TAS installed in $dest. Open it from Launchpad or Applications."
}

case "$(uname -s)" in
  Linux) install_linux ;;
  Darwin) install_macos ;;
  *) die "this script is for Linux and macOS; on Windows use install.ps1" ;;
esac
