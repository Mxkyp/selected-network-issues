#!/usr/bin/env bash
# Builds the "Project Resources" archive: scripts, manifests, policies and their instructions.
#
#   ./make-resources-archive.sh [ref] [output.zip]
#
#   ref         git commit, branch or tag to pack (default: HEAD, the current branch)
#   output.zip  default: project-resources-group4.zip in the repo root
#
# Only committed files go into the archive (git archive), so uncommitted changes are left out:
# the script stops if any packed path has them. Evidence, reports, slides and the AI notes stay
# out on purpose; see the list below.
set -euo pipefail
cd "$(dirname "$0")"

REF=${1:-HEAD}
OUT=${2:-project-resources-group4.zip}
PREFIX=zero-trust-service-mesh/

PATHS=(
  README.md
  setup.sh setup.ps1
  zero-trust.sh zero-trust.ps1
  app
  cluster
  policies
  attack
  observability
  stage4/performance
)

git rev-parse --verify --quiet "$REF^{commit}" >/dev/null || { echo "Unknown ref: $REF" >&2; exit 1; }

for p in "${PATHS[@]}"; do
  git cat-file -e "$REF:$p" 2>/dev/null || { echo "Missing in $REF: $p" >&2; exit 1; }
done

if [ "$REF" = HEAD ] && [ -n "$(git status --porcelain -- "${PATHS[@]}")" ]; then
  echo "Uncommitted changes in packed files (they would be left out of the archive):" >&2
  git status --short -- "${PATHS[@]}" >&2
  echo "Commit them first, or pass a ref explicitly to pack it as it is." >&2
  exit 1
fi

git archive --format=zip --prefix="$PREFIX" -o "$OUT" "$REF" -- "${PATHS[@]}"

echo "Created $OUT from $(git rev-parse --short "$REF") ($(git rev-parse --abbrev-ref "$REF" 2>/dev/null || echo "$REF"))"
unzip -l "$OUT" | tail -1 | awk '{print "  " $2 " files, " $1 " bytes uncompressed"}'
