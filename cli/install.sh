#!/usr/bin/env bash
# ==============================================================================
# Android Compose Inspector CLI Installer
# ==============================================================================
# Installs the 'compose-inspector' CLI (and the 'android-compose-inspector' MCP
# server entry point) onto the user's system as an isolated `uv tool`, so both
# commands land on PATH without touching any project virtualenv.
#
# Local mode (run from inside a clone of this repo):
#   ./install.sh                 # installs from this checkout
#   ./install.sh --pip           # force a `pip install --user` fallback
#
# Remote mode (piped from GitHub, no local checkout needed):
#   curl -fsSL https://raw.githubusercontent.com/balvinderz/recomposition_inspector/main/cli/install.sh | bash
# ==============================================================================

set -e

REPO_SLUG="balvinderz/recomposition_inspector"
REPO_REF="${COMPOSE_INSPECTOR_REF:-main}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
BINARY_NAME="compose-inspector"
FORCE_PIP=""

for arg in "$@"; do
    case $arg in
        --pip)
            FORCE_PIP="1"
            shift
            ;;
    esac
done

if [ -n "$SCRIPT_DIR" ] && [ -f "${SCRIPT_DIR}/pyproject.toml" ]; then
    INSTALL_SOURCE="$SCRIPT_DIR"
    echo "🔎 Local checkout detected; installing from ${SCRIPT_DIR}."
else
    if [ "$REPO_SLUG" = "OWNER/REPO" ]; then
        echo "❌ Error: this installer was run outside a local checkout, and its" >&2
        echo "   REPO_SLUG placeholder hasn't been set to a real GitHub owner/repo yet." >&2
        echo "   Either run ./install.sh from inside a clone of this repo's cli/" >&2
        echo "   directory, or edit REPO_SLUG in this script once it's pushed." >&2
        exit 1
    fi
    INSTALL_SOURCE="git+https://github.com/${REPO_SLUG}@${REPO_REF}#subdirectory=cli"
    echo "🔎 Remote install; fetching compose-inspector from ${INSTALL_SOURCE}."
fi

if [ -z "$FORCE_PIP" ] && command -v uv >/dev/null 2>&1; then
    echo "🔨 Installing '${BINARY_NAME}' as an isolated uv tool..."
    uv tool install --force "${INSTALL_SOURCE}"
    echo "✅ Installed via uv tool."
else
    if ! command -v python3 >/dev/null 2>&1; then
        echo "❌ Error: neither 'uv' nor 'python3' was found in PATH."
        echo "   Install uv (https://docs.astral.sh/uv/) or Python 3.11+ and retry."
        exit 1
    fi
    echo "🔨 'uv' not found (or --pip forced); installing with 'pip install --user' instead..."
    python3 -m pip install --user --upgrade "${INSTALL_SOURCE}"
    echo "✅ Installed via pip --user."
fi

# ==============================================================================
# Initialize state & extract the AI skill file
# ==============================================================================

echo ""
echo "🚀 Initializing state and extracting the AI skill..."
"${BINARY_NAME}" prerequisites >/dev/null 2>&1 || true

# ==============================================================================
# Verify PATH, adb, and report
# ==============================================================================

echo ""
if command -v "${BINARY_NAME}" >/dev/null 2>&1; then
    BIN_PATH="$(command -v "${BINARY_NAME}")"
    echo "✅ '${BINARY_NAME}' is on PATH: ${BIN_PATH}"
else
    echo "⚠️  Notice: '${BINARY_NAME}' was installed but is not yet on PATH."
    echo "   If you installed via uv, run: uv tool update-shell"
    echo "   Then restart your shell, or: export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

echo ""
echo "🔍 Checking adb..."
if command -v adb >/dev/null 2>&1; then
    echo "✅ adb detected: $(command -v adb)"
else
    echo "⚠️  Warning: 'adb' not found in PATH. Install Android platform-tools first."
fi

echo "=============================================================================="
echo "🎉 compose-inspector installed successfully!"
echo "   AI Skill:  ~/.compose-inspector/skills/compose-inspector-cli/SKILL.md"
echo "   Test it:   ${BINARY_NAME} --help"
echo ""
echo "   Symlink the skill into your agent's skill directory, e.g.:"
echo "     mkdir -p ~/.claude/skills/compose-inspector && ln -s \\"
echo "       ~/.compose-inspector/skills/compose-inspector-cli/SKILL.md \\"
echo "       ~/.claude/skills/compose-inspector/SKILL.md"
echo "=============================================================================="
