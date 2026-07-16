#!/bin/sh
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

set -eu

fail() {
  printf '%s\n' "live run: $*" >&2
  exit 1
}

script_dir=$(CDPATH='' cd -P "$(dirname "$0")" 2>/dev/null && pwd) ||
  fail "cannot resolve script directory"
repo=$(CDPATH='' cd -P "$script_dir/.." 2>/dev/null && pwd) ||
  fail "cannot resolve checkout"
cd "$repo" || fail "cannot enter checkout"

for tool in awk cat codex cp chromiumfish fc-match git grep moon pdfimages \
  pdfinfo pdftoppm readlink sed sha256sum tar wc; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is not on PATH"
done
[ "${GIT_DIR+x}" != x ] || fail "refusing ambient GIT_DIR"
[ "${GIT_WORK_TREE+x}" != x ] || fail "refusing ambient GIT_WORK_TREE"
[ "${GIT_INDEX_FILE+x}" != x ] || fail "refusing ambient GIT_INDEX_FILE"
[ "$(git rev-parse --show-toplevel 2>/dev/null)" = "$repo" ] ||
  fail "script checkout is not the Git worktree root"
if [ -L .install ]; then
  fail "refusing symlinked live scratch root: $repo/.install"
elif [ -e .install ] && [ ! -d .install ]; then
  fail "live scratch root is not a directory: $repo/.install"
fi
mkdir -p .install
scratch=$(mktemp -d "$repo/.install/live-run.XXXXXX") ||
  fail "cannot create live scratch directory"
printf '%s\n' "live run: artifacts retained at $scratch"

# Keep the proof explicit and isolated from every other opt-in test switch.
unset SLIDE_GEN_LIVE SLIDE_GEN_RENDER_CLI_LIVE SLIDE_GEN_RENDER_DOM_LIVE
unset SLIDE_GEN_RENDER_RASTER_LIVE SLIDE_GEN_RENDER_PDF_LIVE
unset SLIDE_GEN_LIVE_RUN_ROOT SLIDE_GEN_LIVE_RUN_PROJECT

codex login status >/dev/null 2>&1 || fail "Codex CLI is not authenticated"
browser=$(chromiumfish path) || fail "cannot resolve ChromiumFish browser"
if [ ! -f "$browser" ] || [ ! -x "$browser" ]; then
  fail "ChromiumFish browser is missing or not executable: $browser"
fi
font_family=$(fc-match -f '%{family}\n' 'Noto Sans CJK JP' | sed -n '1p')
case $font_family in
  *"Noto Sans CJK JP"*) ;;
  *) fail "Noto Sans CJK JP did not resolve: $font_family" ;;
esac

projects=$scratch/Projects
checkout=$projects/slide-gen
project=aurora-queue
source=$projects/$project
public_bin=$projects/.bin
outside=$projects/.outside
archive=$scratch/slide-gen.tar
file_list=$scratch/checkout-files
mkdir -p "$checkout" "$source" "$public_bin" "$outside"

# Copy the prospective nonignored tree, including new files, then commit that
# copy so the installed payload has a clean Git baseline without mutating the
# source checkout's index or worktree.
git ls-files --cached --others --exclude-standard -z >"$file_list" ||
  fail "cannot enumerate prospective checkout files"
[ -s "$file_list" ] || fail "prospective checkout file list is empty"
tar --null --verbatim-files-from --files-from="$file_list" -cf "$archive" ||
  fail "cannot archive prospective checkout"
tar -xf "$archive" -C "$checkout" || fail "cannot extract checkout fixture"
rm -f "$archive" "$file_list"
cp "$repo/testdata/live-run/README.md" "$source/README.md"
cp "$repo/testdata/live-run/metrics.csv" "$source/metrics.csv"

git -C "$checkout" init -q
git -C "$checkout" add --all
git -C "$checkout" \
  -c user.name='slide-gen live proof' \
  -c user.email='slide-gen@example.invalid' \
  -c commit.gpgsign=false \
  -c core.hooksPath=/dev/null \
  commit -qm fixture
git -C "$source" init -q
git -C "$source" add README.md metrics.csv
git -C "$source" \
  -c user.name='slide-gen live proof' \
  -c user.email='slide-gen@example.invalid' \
  -c commit.gpgsign=false \
  -c core.hooksPath=/dev/null \
  commit -qm fixture

"$checkout/tools/install.sh" "$public_bin"
installed=$public_bin/slide-gen
[ -L "$installed" ] || fail "installer did not publish a launcher symlink"
[ "$(readlink "$installed")" = "$checkout/bin/slide-gen" ] ||
  fail "installed launcher does not resolve to the disposable checkout"

enable_out=$scratch/enable.stdout
enable_err=$scratch/enable.stderr
if ! (cd "$outside" && "$installed" enable "$project") \
  >"$enable_out" 2>"$enable_err"; then
  command cat "$enable_out" >&2
  command cat "$enable_err" >&2
  fail "installed launcher could not enable the fixture project"
fi
[ "$(command cat "$enable_out")" = "enabled $project" ] ||
  fail "unexpected enable output"
[ ! -s "$enable_err" ] || fail "enable wrote unexpected stderr"

run_out=$scratch/run.stdout
run_err=$scratch/run.stderr
set +e
(cd "$outside" && "$installed" run) >"$run_out" 2>"$run_err"
run_status=$?
set -e
command cat "$run_out"
if [ "$run_status" -ne 0 ]; then
  command cat "$run_err" >&2
  fail "installed enabled-set run exited $run_status"
fi
[ ! -s "$run_err" ] || fail "successful run wrote unexpected stderr"
command grep -F "summary: 1 succeeded, 0 failed, 1 total" "$run_out" >/dev/null ||
  fail "successful run omitted the one-item summary"

bundle=$checkout/decks/$project
render_dir=$checkout/renders/$project
pdf=$render_dir/deck.pdf
if [ ! -f "$bundle/figures.py" ] || [ -L "$bundle/figures.py" ]; then
  fail "numeric fixture did not produce a real figure script"
fi
if [ ! -d "$bundle/assets" ] || [ -L "$bundle/assets" ]; then
  fail "numeric fixture did not produce a real asset directory"
fi
asset_count=$(/usr/bin/find "$bundle/assets" -maxdepth 1 -type f -name '*.png' -print |
  wc -l)
[ "$asset_count" -gt 0 ] || fail "numeric fixture produced no PNG asset"

# Invoke the project validator and render-layout checks independently of the
# installed process that already gated publication.
SLIDE_GEN_LIVE_RUN_ROOT=$checkout \
SLIDE_GEN_LIVE_RUN_PROJECT=$project \
  moon test --target native \
    -f '*independently validates installed live-run bundle and render*'

info=$scratch/pdfinfo.txt
images=$scratch/pdfimages.txt
LC_ALL=C pdfinfo "$pdf" >"$info" || fail "pdfinfo rejected the PDF"
pages=$(awk '/^Pages:/ { print $2 }' "$info")
case $pages in
  '' | *[!0-9]*) fail "pdfinfo returned an invalid page count: $pages" ;;
esac
[ "$pages" -gt 0 ] || fail "PDF has no pages"
LC_ALL=C pdfinfo -f 1 -l "$pages" -box "$pdf" >"$info" ||
  fail "pdfinfo could not enumerate every PDF page"
if command grep -E '^(CreationDate|ModDate):' "$info" >/dev/null; then
  fail "deterministic PDF unexpectedly carries a creation/modification date"
fi
awk -v expected="$pages" '
  /^Page +[0-9]+ size:/ {
    sizes += 1
    if ($2 != sizes || $4 != 2560 || $5 != "x" || $6 != 1440 || $7 != "pts") bad = 1
  }
  /^Page +[0-9]+ rot:/ {
    rotations += 1
    if ($2 != rotations || $4 != 0) bad = 1
  }
  END { if (bad || sizes != expected || rotations != expected) exit 1 }
' "$info" || fail "PDF pages are not ordered 2560x1440-point, zero-rotation pages"

LC_ALL=C pdfimages -list "$pdf" >"$images" ||
  fail "pdfimages rejected the PDF"
awk -v expected="$pages" '
  $1 ~ /^[0-9]+$/ {
    rows += 1
    if ($1 != rows || $2 != rows - 1 || $3 != "image" ||
        $4 != 2560 || $5 != 1440 || $6 != "rgb" || $7 != 3 ||
        $8 != 8 || $9 != "image" || $10 != "no" ||
        $13 != 72 || $14 != 72) bad = 1
  }
  END { if (bad || rows != expected) exit 1 }
' "$images" ||
  fail "PDF is not one ordered lossless 2560x1440 RGB/8-bit image per page at 72 dpi"

inspection=$scratch/poppler-pages
mkdir "$inspection"
pdftoppm -png -r 72 "$pdf" "$inspection/page" >/dev/null 2>&1 ||
  fail "Poppler could not rasterize the final PDF"
raster_count=$(/usr/bin/find "$inspection" -maxdepth 1 -type f -name 'page-*.png' -print |
  wc -l)
[ "$raster_count" -eq "$pages" ] ||
  fail "Poppler raster count $raster_count does not match PDF page count $pages"

source_status=$(git -C "$source" status --porcelain=v1 --untracked-files=all)
[ -z "$source_status" ] || fail "Codex changed the source project"
checkout_status=$(git -C "$checkout" status --porcelain=v1 --untracked-files=no)
[ -z "$checkout_status" ] || fail "live run changed tracked checkout files"
sha256sum "$pdf" "$render_dir"/page_*.png "$inspection"/page-*.png \
  >"$scratch/sha256.txt"

printf '%s\n' \
  "live run: bundle revalidated ($asset_count asset(s))" \
  "live run: PDF verified ($pages ordered lossless page(s))" \
  "live run: inspect Poppler rasters in $inspection"
