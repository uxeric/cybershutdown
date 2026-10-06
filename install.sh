#!/usr/bin/env bash
# cshutdown installer: installs the `cshutdown` command for the current user.
#
#   curl -fsSL https://raw.githubusercontent.com/uxeric/cybershutdown/HEAD/install.sh | bash
#   ./install.sh                 # from a checkout: installs that checkout
#   ./install.sh --uninstall     # removes cshutdown, its menu item and launcher entry
#
# Settings (environment variables):
#   CSHUTDOWN_REPO        GitHub owner/name to download from  (default: uxeric/cybershutdown)
#   CSHUTDOWN_REF         branch or tag to install            (default: the repo's default branch)
#   CSHUTDOWN_PREFIX      install prefix                      (default: ~/.local, so cshutdown goes in ~/.local/bin)
#   CSHUTDOWN_SOURCE_DIR  install from this directory instead of downloading
#   CSHUTDOWN_NO_OMARCHY=1  skip the Omarchy integration (System menu item, app launcher entry)

set -euo pipefail

REPO="${CSHUTDOWN_REPO:-uxeric/cybershutdown}"
REF="${CSHUTDOWN_REF:-HEAD}"
PREFIX="${CSHUTDOWN_PREFIX:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"
BIN="$BIN_DIR/cshutdown"
MENU_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/extensions/omarchy-menu.jsonc"
MENU_ID="system.cshutdown"
LAUNCHER_NAME="Cyber Shutdown"
MIN_PYTHON="3.8"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    YEL=$'\e[38;2;252;238;10m' RED=$'\e[38;2;255;0;60m' CYAN=$'\e[38;2;0;240;255m'
    GHOST=$'\e[38;2;106;106;120m' BOLD=$'\e[1m' RESET=$'\e[0m'
else
    YEL="" RED="" CYAN="" GHOST="" BOLD="" RESET=""
fi

step() { printf '%s▸%s %s\n' "$YEL" "$RESET" "$*"; }
ok() { printf '  %s■%s %s\n' "$CYAN" "$RESET" "$*"; }
warn() { printf '  %s!%s %s\n' "$YEL" "$RESET" "$*" >&2; }
die() { printf '%s✗ %s%s\n' "$RED" "$*" "$RESET" >&2; exit 1; }

banner() {
    printf '\n%s%s' "$RED" "$BOLD"
    printf '  ▄▀▀ █▀▀ █▄█ █ █ ▀█▀ █▀▄ ▄▀▄ █   █ █▄ █\n'
    printf '%s  ▀▄▄ ▄▄█ █ █ ▀▄▀  █  █▄▀ ▀▄▀ ▀▄▀▄▀ █ ▀█%s\n\n' "$YEL" "$RESET"
    printf '  %sRELIC//OS emergency shutdown protocol · installer%s\n\n' "$GHOST" "$RESET"
}

is_omarchy() {
    [[ -z "${CSHUTDOWN_NO_OMARCHY:-}" ]] && command -v omarchy-tui-install > /dev/null
}

ensure_python() {
    command -v python3 > /dev/null || die "cshutdown needs Python $MIN_PYTHON or newer. Install it with: sudo pacman -S python"
    python3 -c "import sys; sys.exit(sys.version_info < tuple(map(int, '$MIN_PYTHON'.split('.'))))" \
        || die "cshutdown needs Python $MIN_PYTHON or newer (found $(python3 -V 2>&1))."
    ok "$(python3 -V 2>&1), standard library only"
}

is_checkout() {
    [[ -f "$1/cshutdown" && -f "$1/install.sh" ]] && grep -q '^"""cshutdown:' "$1/cshutdown"
}

find_source() {
    if [[ -n "${CSHUTDOWN_SOURCE_DIR:-}" ]]; then
        is_checkout "$CSHUTDOWN_SOURCE_DIR" || die "CSHUTDOWN_SOURCE_DIR=$CSHUTDOWN_SOURCE_DIR is not a cshutdown checkout."
        SOURCE="$CSHUTDOWN_SOURCE_DIR"
        ok "installing from $SOURCE"
        return
    fi
    local here=""
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
        here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    fi
    if [[ -n "$here" ]] && is_checkout "$here"; then
        SOURCE="$here"
        ok "installing this checkout ($SOURCE)"
        return
    fi
    command -v curl > /dev/null || die "curl is needed to download cshutdown."
    SOURCE="$(mktemp -d)"
    trap 'rm -rf "$SOURCE"' EXIT
    local raw="https://raw.githubusercontent.com/$REPO/$REF"
    mkdir -p "$SOURCE/assets"
    curl -fsSL "$raw/cshutdown" -o "$SOURCE/cshutdown" \
        || die "Could not download $raw/cshutdown. Set CSHUTDOWN_REPO (or CSHUTDOWN_REF) to the right value."
    curl -fsSL "$raw/install.sh" -o "$SOURCE/install.sh" || true
    curl -fsSL "$raw/assets/icon.png" -o "$SOURCE/assets/icon.png" || rm -f "$SOURCE/assets/icon.png"
    is_checkout "$SOURCE" || die "What came back from $raw is not cshutdown."
    ok "downloaded $REPO ($REF)"
}

# Adds or removes our row in the Omarchy menu's JSONC. Python does the edit so a
# missing trailing comma in your file can't break the menu, and the result is
# parsed the way the menu parses it before it is written back.
edit_menu() {
    local mode="$1" line="${2:-}"
    python3 - "$MENU_FILE" "$MENU_ID" "$mode" "$line" << 'PY'
import json, os, re, sys

path, menu_id, mode, new = sys.argv[1:5]
tag = "added by the cshutdown installer"
text = open(path).read() if os.path.exists(path) else "{\n}\n"
lines = [l for l in text.splitlines() if tag not in l and '"%s"' % menu_id not in l]

if mode == "add":
    close = max((i for i, l in enumerate(lines) if l.strip() == "}"), default=None)
    if close is None:
        sys.exit("no closing brace on its own line in " + path)
    prev = next((i for i in range(close - 1, -1, -1) if lines[i].strip() and not lines[i].strip().startswith("//")), None)
    if prev is not None and not lines[prev].rstrip().endswith((",", "{")):
        lines[prev] = lines[prev].rstrip() + ","
    lines[close:close] = ["  // %s; ./install.sh --uninstall removes it" % tag, new]

out = "\n".join(lines) + "\n"
# the same stripping the Omarchy menu does before JSON.parse
check = re.sub(r"^\s*//[^\n]*(\n|$)", "", out, flags=re.M)
check = re.sub(r",(\s*[}\]])", r"\1", check)
try:
    json.loads(check)
except ValueError as e:
    sys.exit("the menu file would not parse (%s); left it untouched" % e)
if out != text:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path + ".tmp", "w") as f:
        f.write(out)
    os.replace(path + ".tmp", path)
PY
}

refresh_menu() {
    command -v omarchy-menu > /dev/null && omarchy-menu refresh > /dev/null 2>&1 || true
}

add_to_omarchy() {
    local action="omarchy-launch-tui --app-id=org.omarchy.cshutdown $BIN --fullscreen"
    local row
    row="$(printf '  "%s": {"icon":"󰚌","label":"Cyber Shutdown","description":"Crash like it'"'"'s 2077, then power off","action":"%s"},' "$MENU_ID" "$action")"
    if edit_menu add "$row"; then
        refresh_menu
        ok "added Cyber Shutdown to the System menu (Super+Escape)"
    else
        warn "could not add the menu item; cshutdown itself is installed"
    fi

    local icon="$SOURCE/assets/icon.png"
    [[ -f "$icon" ]] || icon="system-shutdown"
    if omarchy-tui-install "$LAUNCHER_NAME" "$BIN --fullscreen" tile "$icon" > /dev/null; then
        local entry="$HOME/.local/share/applications/$LAUNCHER_NAME.desktop"
        sed -i "s/^Comment=.*/Comment=Cyberpunk 2077 style system crash, then shutdown. Any key aborts./" "$entry"
        grep -q '^Keywords=' "$entry" || printf 'Keywords=cshutdown;shutdown;power;poweroff;cyberpunk;\n' >> "$entry"
        ok "added Cyber Shutdown to the app launcher (Super+Alt+Space)"
    else
        warn "could not add the app launcher entry; cshutdown itself is installed"
    fi
}

remove_from_omarchy() {
    if [[ -f "$MENU_FILE" ]] && grep -q "\"$MENU_ID\"" "$MENU_FILE"; then
        if edit_menu remove; then
            refresh_menu
            ok "removed Cyber Shutdown from the Omarchy menu"
        else
            warn "could not remove the menu item from $MENU_FILE; delete the \"$MENU_ID\" line by hand"
        fi
    fi
    if [[ -e "$HOME/.local/share/applications/$LAUNCHER_NAME.desktop" ]]; then
        if command -v omarchy-tui-remove > /dev/null; then
            OMARCHY_REMOVE_NOTIFY=false omarchy-tui-remove "$LAUNCHER_NAME" > /dev/null
        else
            rm -f "$HOME/.local/share/applications/$LAUNCHER_NAME.desktop"
        fi
        ok "removed Cyber Shutdown from the app launcher"
    fi
}

check_path() {
    case ":$PATH:" in
        *":$BIN_DIR:"*) ;;
        *)
            warn "$BIN_DIR is not on your PATH. Add this to your shell's rc file:"
            printf '      export PATH="%s:$PATH"\n' "$BIN_DIR" >&2
            ;;
    esac
}

installed_version() {
    [[ -x "$BIN" ]] && "$BIN" --version 2> /dev/null | awk '{print $2}' || true
}

install_cshutdown() {
    banner
    if is_omarchy; then
        ok "Omarchy $(omarchy-version 2> /dev/null || true) detected: wiring into the menu"
    fi
    step "checking the runtime"
    ensure_python
    step "getting the payload"
    find_source
    local old new
    old="$(installed_version)"
    new="$(python3 "$SOURCE/cshutdown" --version | awk '{print $2}')"
    if [[ -n "$old" && "$old" == "$new" ]]; then
        step "reinstalling cshutdown $new"
    elif [[ -n "$old" ]]; then
        step "updating cshutdown $old → $new"
    else
        step "installing cshutdown $new"
    fi
    install -Dm755 "$SOURCE/cshutdown" "$BIN"
    ok "installed $BIN"
    if is_omarchy; then
        step "jacking into Omarchy"
        add_to_omarchy
    fi
    check_path
    printf '\n  %s%sdaemon uploaded.%s try %s%scshutdown --dry-run%s first. any key aborts.\n\n' \
        "$CYAN" "$BOLD" "$RESET" "$YEL" "$BOLD" "$RESET"
}

uninstall_cshutdown() {
    step "flatlining cshutdown"
    if [[ -e "$BIN" ]]; then
        rm -f "$BIN"
        ok "removed $BIN"
    else
        ok "cshutdown was not installed in $BIN_DIR"
    fi
    remove_from_omarchy
    printf '\n  %s// SIGNAL LOST%s\n\n' "$GHOST" "$RESET"
}

main() {
    local mode=install
    for arg in "$@"; do
        case "$arg" in
            --uninstall) mode=uninstall ;;
            -h | --help)
                sed -n '2,14p' "${BASH_SOURCE[0]:-/dev/null}" 2> /dev/null | sed 's/^# \{0,1\}//'
                exit 0
                ;;
            *) die "unknown option: $arg (try --help)" ;;
        esac
    done
    if [[ "$mode" == uninstall ]]; then
        uninstall_cshutdown
    else
        install_cshutdown
    fi
}

main "$@"
