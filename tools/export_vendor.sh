#!/bin/sh
# One-shot export of everything under ThirdParty/ that .gitignore keeps off GitHub, so CI can build
# the app and so we can publish the GPL "corresponding source" of every core we ship.
#
# Run from inside the GameDuo checkout on the Mac that has ThirdParty/ populated:
#   cd ~/Developer/GameDuo && git fetch origin && git show origin/export-vendor-tool:tools/export_vendor.sh | sh
# It never touches the current working tree or branch: it commits into a temporary worktree and pushes
# branch `vendor-export` (patches + manifest). The prebuilt StoreCores go to GitHub release
# `vendor-cores` when `gh` is logged in, otherwise to orphan branch `vendor-bin` in <95 MB chunks.
set -eu

ROOT=$(cd "$(git rev-parse --show-toplevel)" && pwd -P)
cd "$ROOT"
TP="$ROOT/ThirdParty"
[ -d "$TP" ] || { echo "no ThirdParty/ here: $TP" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/gameduo-vendor.XXXXXX")
OUT="$WORK/vendor"
mkdir -p "$OUT/patches"
MANIFEST="$OUT/MANIFEST.tsv"
printf 'path\tkind\tremote\tcommit\tdiff_bytes\tuntracked_files\tsize_kb\n' > "$MANIFEST"

record_repo() {
    # $1 = repo dir (absolute), $2 = label used for file names
    dir=$1; label=$2
    remote=$(git -C "$dir" remote get-url origin 2>/dev/null || echo -)
    commit=$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo -)
    git -C "$dir" diff --binary HEAD > "$OUT/patches/$label.diff" 2>/dev/null || true
    git -C "$dir" ls-files --others --exclude-standard -z > "$WORK/untracked" 2>/dev/null || true
    n=$(tr -cd '\000' < "$WORK/untracked" | wc -c | tr -d ' ')
    if [ "$n" -gt 0 ]; then
        (cd "$dir" && xargs -0 tar -czf "$OUT/patches/$label.untracked.tgz" < "$WORK/untracked")
    fi
    bytes=$(wc -c < "$OUT/patches/$label.diff" | tr -d ' ')
    [ "$bytes" -gt 0 ] || rm -f "$OUT/patches/$label.diff"
    printf '%s\tgit\t%s\t%s\t%s\t%s\t-\n' "${dir#$ROOT/}" "$remote" "$commit" "$bytes" "$n" >> "$MANIFEST"
}

for entry in "$TP"/*; do
    [ -e "$entry" ] || continue
    name=$(basename "$entry")
    case "$name" in PlayWeb) continue ;; esac
    if [ -d "$entry" ] && [ "$(git -C "$entry" rev-parse --show-toplevel 2>/dev/null)" = "$(cd "$entry" && pwd -P)" ]; then
        record_repo "$entry" "$name"
        # Submodules (Azahar keeps most deps there); only record ones we actually changed.
        git -C "$entry" submodule foreach --quiet --recursive 'echo "$toplevel/$sm_path"' 2>/dev/null |
        while IFS= read -r sub; do
            if [ -n "$(git -C "$sub" status --porcelain 2>/dev/null)" ]; then
                record_repo "$sub" "$(echo "${sub#$TP/}" | tr '/' '_')"
            fi
        done
    else
        kb=$(du -sk "$entry" | cut -f1)
        printf '%s\tplain\t-\t-\t-\t-\t%s\n' "ThirdParty/$name" "$kb" >> "$MANIFEST"
        # Plain source drops (no git) up to 200 MB are archived whole; xcframeworks are binaries, handled below.
        case "$name" in
            *.xcframework|StoreCores) ;;
            *) if [ -d "$entry" ] && [ "$kb" -lt 204800 ]; then
                   tar -czf "$OUT/patches/$name.plain.tgz" -C "$TP" "$name"
               fi ;;
        esac
    fi
done

# Build scripts that lived only on this Mac (PPSSPP / DeSmuME cores have none in tools/).
for f in "$ROOT"/tools/*.sh "$ROOT"/work/*.py "$ROOT"/work/*.sh; do
    [ -f "$f" ] || continue
    git ls-files --error-unmatch "$f" >/dev/null 2>&1 || { mkdir -p "$OUT/local-scripts"; cp "$f" "$OUT/local-scripts/"; }
done

# Prebuilt cores exactly as build 13 shipped them.
BIN=""
if [ -d "$TP/StoreCores" ]; then
    BIN="$WORK/StoreCores-build13.tgz"
    tar -czf "$BIN" -C "$TP" StoreCores
    (cd "$TP/StoreCores" && find . -type f -exec shasum -a 256 {} +) > "$OUT/StoreCores.sha256"
fi

# GitHub rejects files over 100 MB; drop oversized artifacts and say so in the manifest.
find "$OUT" -type f -size +95M | while IFS= read -r big; do
    printf '%s\tTOO_BIG_SKIPPED\t-\t-\t-\t-\t%s\n' "${big#$OUT/}" "$(du -k "$big" | cut -f1)" >> "$MANIFEST"
    rm -f "$big"
done

git fetch -q origin
git worktree add -q --detach "$WORK/wt" origin/ps2-core
mkdir -p "$WORK/wt/vendor"
cp -R "$OUT/." "$WORK/wt/vendor/"
(
    cd "$WORK/wt"
    git checkout -q -B vendor-export
    git add -f vendor
    git commit -q -m "vendor: ThirdParty manifest, local core patches, untracked build scripts"
    git push -q -f origin vendor-export
)

if [ -n "$BIN" ]; then
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
        gh release view vendor-cores >/dev/null 2>&1 ||
            gh release create vendor-cores --target ps2-core --title "vendor-cores" --notes "Prebuilt StoreCores from build 13 (internal)." >/dev/null
        gh release upload vendor-cores "$BIN" --clobber
    else
        (
            cd "$WORK/wt"
            git checkout -q --orphan vendor-bin
            git rm -rq --cached . >/dev/null 2>&1 || true
            find . -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
            split -b 90m "$BIN" StoreCores-build13.tgz.part-
            git add -f StoreCores-build13.tgz.part-*
            git commit -q -m "vendor-bin: StoreCores build 13 (cat parts | tar xz)"
            git push -q -f origin vendor-bin
        )
    fi
fi

git worktree remove --force "$WORK/wt"
git branch -q -D vendor-export vendor-bin 2>/dev/null || true
echo "done. pushed branch vendor-export$( [ -n "$BIN" ] && echo ' + StoreCores' )"
cat "$MANIFEST"
rm -rf "$WORK"
