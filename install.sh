#!/usr/bin/env bash
#
# Agent Guard Core — Installer
#
# Installs the agent-guard-core package into a target Git repository.
#
# Usage:
#   bash /path/to/agent-guard-core/install.sh [options]
#
# Options:
#   --target <dir>        Target repository root (default: current directory)
#   --package-root <path> Where to place the package inside the repo
#                         (default: packages/agent-guard-core)
#   --init-name <name>    Name of the init stub at the repo root
#                         (default: .agent-guard-init)
#   --skip-hooks          Do not install Git hooks
#   --skip-wrapper        Do not install the Kimi CLI wrapper
#   --yes                 Skip confirmation prompts

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARGET_DIR="$(pwd)"
PACKAGE_ROOT="packages/agent-guard-core"
INIT_NAME=".agent-guard-init"
INSTALL_HOOKS="true"
INSTALL_WRAPPER="true"
SKIP_CONFIRM="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)
            TARGET_DIR="${2:-}"
            shift 2
            ;;
        --target=*)
            TARGET_DIR="${1#*=}"
            shift
            ;;
        --package-root)
            PACKAGE_ROOT="${2:-}"
            shift 2
            ;;
        --package-root=*)
            PACKAGE_ROOT="${1#*=}"
            shift
            ;;
        --init-name)
            INIT_NAME="${2:-}"
            shift 2
            ;;
        --init-name=*)
            INIT_NAME="${1#*=}"
            shift
            ;;
        --skip-hooks)
            INSTALL_HOOKS="false"
            shift
            ;;
        --skip-wrapper)
            INSTALL_WRAPPER="false"
            shift
            ;;
        --yes)
            SKIP_CONFIRM="true"
            shift
            ;;
        -h|--help)
            sed -n '2,20p' "$0"
            exit 0
            ;;
        *)
            echo "❌ Unknown option: $1" >&2
            echo "   Run $0 --help for usage." >&2
            exit 1
            ;;
    esac
done

if [[ ! -d "${TARGET_DIR}/.git" && ! -f "${TARGET_DIR}/.git" ]]; then
    echo "❌ Target directory does not appear to be a Git repository: ${TARGET_DIR}" >&2
    exit 1
fi

TARGET_DIR="$(cd "${TARGET_DIR}" && pwd)"
DEST_DIR="${TARGET_DIR}/${PACKAGE_ROOT}"

if [[ -d "${DEST_DIR}" ]]; then
    echo "⚠️  Package already exists at ${DEST_DIR}" >&2
    if [[ "${SKIP_CONFIRM}" != "true" ]]; then
        read -rp "Overwrite? [y/N] " reply
        if [[ "${reply}" != "y" && "${reply}" != "Y" ]]; then
            echo "Aborted."
            exit 0
        fi
    fi
    rm -rf "${DEST_DIR}"
fi

echo "📦 Installing Agent Guard Core into ${DEST_DIR}..."
mkdir -p "${DEST_DIR}"
cp -R "${SCRIPT_DIR}/"bin "${SCRIPT_DIR}/"src "${SCRIPT_DIR}/"hooks "${SCRIPT_DIR}/"ci "${SCRIPT_DIR}/"wrappers "${SCRIPT_DIR}/"shell "${SCRIPT_DIR}/"templates "${SCRIPT_DIR}/"examples "${SCRIPT_DIR}/"README.md "${SCRIPT_DIR}/"LICENSE "${SCRIPT_DIR}/"CHANGELOG.md "${DEST_DIR}/"

# Generate agent-guard.yaml from example if it does not exist.
YAML_PATH="${TARGET_DIR}/agent-guard.yaml"
if [[ ! -f "${YAML_PATH}" ]]; then
    echo "📝 Creating ${YAML_PATH} from example..."
    cp "${SCRIPT_DIR}/agent-guard.yaml.example" "${YAML_PATH}"
    echo "   Edit this file to match your project before using Agent Guard."
else
    echo "✅ agent-guard.yaml already exists; keeping current file."
fi

# Generate the init stub at the repo root.
INIT_STUB="${TARGET_DIR}/${INIT_NAME}"
echo "🔧 Creating init stub ${INIT_STUB}..."
sed "s/{{INIT_SCRIPT_NAME}}/${INIT_NAME}/g" "${SCRIPT_DIR}/templates/init_stub.sh" > "${INIT_STUB}"
chmod +x "${INIT_STUB}"

# Install Git hooks if requested.
if [[ "${INSTALL_HOOKS}" == "true" ]]; then
    echo "🔒 Installing Git hooks..."
    bash "${DEST_DIR}/hooks/install.sh" --target "${TARGET_DIR}" || true
fi

# Install Kimi CLI wrapper if requested.
if [[ "${INSTALL_WRAPPER}" == "true" ]]; then
    KIMI_BIN_DIR="${HOME}/.kimi-code/bin"
    if [[ -f "${TARGET_DIR}/agent-guard.yaml" ]]; then
        KIMI_BIN_DIR="$(python3 -c "import yaml,sys; d=yaml.safe_load(open(sys.argv[1])); print(d.get('wrappers',{}).get('kimi',{}).get('bin_dir','${KIMI_BIN_DIR}'))" "${TARGET_DIR}/agent-guard.yaml" 2>/dev/null || echo "${KIMI_BIN_DIR}")"
    fi
    KIMI_BIN="${KIMI_BIN_DIR}/kimi"
    KIMI_REAL="${KIMI_BIN_DIR}/kimi.real"

    if [[ -f "${KIMI_BIN}" ]]; then
        if [[ ! -f "${KIMI_REAL}" ]]; then
            echo "💾 Backing up current Kimi binary to ${KIMI_REAL}..."
            cp "${KIMI_BIN}" "${KIMI_REAL}"
            chmod +x "${KIMI_REAL}"
        fi
        echo "🛡️  Installing Kimi CLI wrapper at ${KIMI_BIN}..."
        cp "${DEST_DIR}/wrappers/kimi/wrapper.sh" "${KIMI_BIN}"
        chmod +x "${KIMI_BIN}"
    else
        echo "⚠️  Kimi CLI binary not found at ${KIMI_BIN}; wrapper not installed."
        echo "   Install Kimi CLI and run: bash ${DEST_DIR}/wrappers/kimi/recovery.sh --repo-root ${TARGET_DIR}"
    fi
fi

echo ""
echo "✅ Agent Guard Core installed successfully."
echo ""
echo "Next steps:"
echo "  1. Edit ${YAML_PATH} for your project."
echo "  2. Commit the package and configuration."
echo "  3. Run: source ${INIT_NAME} <identity> <role>"
echo ""
