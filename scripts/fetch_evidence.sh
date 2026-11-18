#!/usr/bin/env bash
# Download the evidence archive (raw results and the working journal) from the GitHub release
# into the repository root, so that citations such as `f3/resultados/...` and `ARQUITETURA.md`
# in docs/ and .claude/ resolve to real files. Both paths are git-ignored.
set -euo pipefail
tag="${EVIDENCE_TAG:-evidence-2026-11-12}"
repo="${EVIDENCE_REPO:-paulohenriquevn/infer}"
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

command -v gh >/dev/null || { echo "fetch_evidence: the GitHub CLI (gh) is required" >&2; exit 1; }
gh release download "$tag" --repo "$repo" --dir "$work"
(cd "$work" && sed 's#journal/##' SHA256SUMS | sha256sum --check --strict) \
  || { echo "fetch_evidence: checksum mismatch for release $tag; nothing was extracted" >&2; exit 2; }

if [ -e "$root/f3/resultados" ]; then
  echo "fetch_evidence: $root/f3/resultados already exists; remove it first to re-extract" >&2; exit 3
fi
# Only f3/ goes to the repository root; the archive's own README goes next to the results,
# never over the repository README.
tar -xzf "$work"/infer-results-*.tar.gz -C "$work"
cp -r "$work"/infer-results-*/f3 "$root/"
cp "$work"/infer-results-*/README.md "$root/f3/resultados/README.md"
cp "$work/ARQUITETURA.md" "$root/ARQUITETURA.md"
echo "Evidence from $tag extracted: $root/f3/resultados/ and $root/ARQUITETURA.md (read only; never edit)."
