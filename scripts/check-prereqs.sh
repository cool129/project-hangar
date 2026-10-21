#!/usr/bin/env bash
# Verifies the local toolchain for every phase of Project HANGAR.
# Run from WSL2/Linux/macOS. Exits non-zero if a required tool is missing.
set -Euo pipefail

missing=0

# check <required|optional> <command> <phase> <version-args...>
check() {
  local level="$1" cmd="$2" phase="$3"
  shift 3
  if command -v "$cmd" >/dev/null 2>&1; then
    local version
    version="$("$cmd" "$@" 2>&1 | head -n1)"
    printf '  \033[32mOK\033[0m       %-12s %-10s %s\n' "$cmd" "$phase" "$version"
  elif [[ "$level" == "required" ]]; then
    printf '  \033[31mMISSING\033[0m  %-12s %-10s (required)\n' "$cmd" "$phase"
    missing=$((missing + 1))
  else
    printf '  \033[33mMISSING\033[0m  %-12s %-10s (optional)\n' "$cmd" "$phase"
  fi
}

echo "Project HANGAR toolchain check"
check required az         "phase 0+"  version --query '"azure-cli"' -o tsv
check required git        "phase 0+"  --version
check required make       "phase 0+"  --version
check required pre-commit "phase 0+"  --version
check optional gh         "phase 0"   --version
check required terraform  "phase 1"   version
check required terragrunt "phase 1"   --version
check optional tflint     "phase 1"   --version
check required python3    "phase 2"   --version
check required docker     "phase 2"   --version
check required kubectl    "phase 3"   version --client
check required helm       "phase 3"   version --short
check required ansible    "phase 5"   --version
check optional trivy      "phase 4"   --version
check optional checkov    "phase 4"   --version

if [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* ]]; then
  echo
  echo "  NOTE: Git Bash detected. Ansible does not run natively on Windows;"
  echo "        use WSL2 (Ubuntu) for this project."
fi

if (( missing > 0 )); then
  echo
  echo "${missing} required tool(s) missing."
  exit 1
fi
echo
echo "All required tools present."
