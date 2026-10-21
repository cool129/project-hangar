#!/usr/bin/env bash
# Installs pinned, checksum-verified CLI tools for CI (linux/amd64).
#
# Usage: scripts/ci/install-tools.sh terragrunt trivy kubeconform actionlint
#
# Tools land in $RUNNER_TEMP/bin (or ./.tools/bin locally) and that directory
# is appended to $GITHUB_PATH so later steps can use them.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tool-versions.env
source "${HERE}/tool-versions.env"

BIN_DIR="${RUNNER_TEMP:-$PWD/.tools}/bin"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$BIN_DIR"

die() { echo "install-tools: $*" >&2; exit 1; }

# fetch <url> <expected-sha256> <output-file>
fetch() {
  local url="$1" want="$2" out="$3" got
  curl -fsSL --retry 3 -o "$out" "$url"
  got="$(sha256sum "$out" | cut -d' ' -f1)"
  [[ "$got" == "$want" ]] || die "checksum mismatch for ${url}: got ${got}, want ${want}"
}

install_terragrunt() {
  fetch "https://github.com/gruntwork-io/terragrunt/releases/download/v${TERRAGRUNT_VERSION}/terragrunt_linux_amd64" \
    "$TERRAGRUNT_SHA256" "${WORK}/terragrunt"
  install -m 0755 "${WORK}/terragrunt" "${BIN_DIR}/terragrunt"
}

install_trivy() {
  fetch "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz" \
    "$TRIVY_SHA256" "${WORK}/trivy.tgz"
  tar -xzf "${WORK}/trivy.tgz" -C "$WORK" trivy
  install -m 0755 "${WORK}/trivy" "${BIN_DIR}/trivy"
}

install_kubeconform() {
  fetch "https://github.com/yannh/kubeconform/releases/download/v${KUBECONFORM_VERSION}/kubeconform-linux-amd64.tar.gz" \
    "$KUBECONFORM_SHA256" "${WORK}/kubeconform.tgz"
  tar -xzf "${WORK}/kubeconform.tgz" -C "$WORK" kubeconform
  install -m 0755 "${WORK}/kubeconform" "${BIN_DIR}/kubeconform"
}

install_actionlint() {
  fetch "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz" \
    "$ACTIONLINT_SHA256" "${WORK}/actionlint.tgz"
  tar -xzf "${WORK}/actionlint.tgz" -C "$WORK" actionlint
  install -m 0755 "${WORK}/actionlint" "${BIN_DIR}/actionlint"
}

[[ $# -gt 0 ]] || die "usage: install-tools.sh <tool>... (terragrunt trivy kubeconform actionlint)"

for tool in "$@"; do
  case "$tool" in
    terragrunt | trivy | kubeconform | actionlint) "install_${tool}" ;;
    *) die "unknown tool: ${tool}" ;;
  esac
  version_flag="--version"
  [[ "$tool" == "kubeconform" ]] && version_flag="-v"
  echo "installed ${tool}: $("${BIN_DIR}/${tool}" "$version_flag" 2>&1 | head -n1)"
done

if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "$BIN_DIR" >> "$GITHUB_PATH"
fi
