#!/bin/sh

set -e

REPO_DIR=$(cd -P -- "$(dirname -- "$(command -v -- "$0")")/.." && pwd -P || exit 1)

if ! type git > /dev/null 2>&1; then
    echo "ERROR: git not found, can't continue" >&2
    exit 1
fi

git config --global --add safe.directory "$REPO_DIR" || true

git -C "$REPO_DIR" fetch --all -pf > /dev/null 2>&1 || true

echo "Checking for tabs" >&2
! git -C "$REPO_DIR" --no-pager grep -InP "\t" -- . ':!third_party/**/*' ':!Config/ExampleFilmGrainTable.tbl' || ret=1

echo "Checking for carriage returns" >&2
! git -C "$REPO_DIR" --no-pager grep -InP "\r" -- . ':!third_party/**/*' || ret=1

echo "Checking for trailing spaces" >&2
! git -C "$REPO_DIR" --no-pager grep -InP " $" -- . ':!third_party/**/*' ':!*.patch' || ret=1

# Test only "new" commits, that is, commits that are not upstream on
# the default branch.
if git -C "$REPO_DIR" fetch -q "${CI_MERGE_REQUEST_PROJECT_URL:-https://gitlab.com/AOMediaCodec/SVT-AV1.git}" "${CI_MERGE_REQUEST_TARGET_BRANCH_NAME:-HEAD}"; then
    FETCH_HEAD=$(git -C "$REPO_DIR" rev-parse FETCH_HEAD)
else
    # in case the fetch failed, maybe internet issues, try to resolve a local default branch's ref, checked-out or not
    FETCH_HEAD=$(git -C "$REPO_DIR" rev-parse refs/remotes/origin/HEAD)
fi

# default to master if we have no origin remote
: "${FETCH_HEAD:=master}"

if ! git -C "$REPO_DIR" merge-tree "$(git -C "$REPO_DIR" merge-base HEAD "$FETCH_HEAD")" HEAD "$FETCH_HEAD" > /dev/null 2>&1; then
    echo "ERROR: failed to simulate a merge, check to see if a merge is possible" >&2
fi

if git -C "$REPO_DIR" diff --exit-code --diff-filter=d --name-only "^$FETCH_HEAD" > /dev/null 2>&1; then
    echo "No differences to upstream's default, skipping further tests"
    exit 0
fi

while read -r filename; do
    file="$REPO_DIR/$filename"
    if ! test -f "$file"; then
        printf "Ignoring file not found: '%s'\n" "$filename"
        continue
    fi
    if test -n "$(tail -c1 "$file")"; then
        printf "No newline at end of %s\n" "$filename"
        ret=1
    fi
done << EOF
$(
    git -C "$REPO_DIR" diff --name-only --diff-filter=d "$FETCH_HEAD" -- . \
        ':!third_party' ':!test/e2e_test/test_vector_list.txt' \
        ':!test/vectors/smoking_test.cfg' \
        ':!test/vectors/video_src.cfg' \
        ':!*.png' \
        ':!*.PNG' \
        ':!*.pdf'
)
EOF

while read -r i; do
    printf "Checking commit message of %s\n" "$i" >&2
    msg=$(git -C "$REPO_DIR" log --format=%B -n 1 "$i")
    if test -n "$(printf '%s' "$msg" | sed -n 2p)"; then
        printf "Malformed commit message in %s, second line must be empty\n" "$i"
        ret=1
    fi
    if printf '%s' "$msg" | head -1 | grep -q '\.$'; then
        printf "Malformed commit message in %s, trailing period in subject line\n" "$i"
        ret=1
    fi
    if printf '%s' "$msg" | head -1 | grep -qi '^fixup!'; then
        printf "Warning: fixup commit detected: %s\n" "$i"
    fi
done << EOF
$(git -C "$REPO_DIR" rev-list HEAD "^$FETCH_HEAD")
EOF

if ! type python3 > /dev/null 2>&1; then
    echo "Warning: python3 not found, skipping clang-format-diff check" >&2
    exit "${ret:-0}"
fi

CLANG_FORMAT_URL=https://raw.githubusercontent.com/llvm/llvm-project/main/clang/tools/clang-format/clang-format-diff.py

if type /usr/share/clang/clang-format-diff.py > /dev/null 2>&1; then
    CLANG_FORMAT_DIFF="/usr/share/clang/clang-format-diff.py"
else
    if ! type "$REPO_DIR/test/clang-format-diff.py" > /dev/null 2>&1; then
        curl -ls -o "$REPO_DIR/test/clang-format-diff.py" "$CLANG_FORMAT_URL" ||
            wget -q -O "$REPO_DIR/test/clang-format-diff.py" "$CLANG_FORMAT_URL"
    fi
    CLANG_FORMAT_DIFF="$REPO_DIR/test/clang-format-diff.py"
fi

if ! type "$CLANG_FORMAT_DIFF" > /dev/null 2>&1; then
    echo "ERROR: clang-format-diff.py not found, can't continue" >&2
    exit 1
fi

diff_output=$(cd "$REPO_DIR" && git diff "$FETCH_HEAD" | python3 "$CLANG_FORMAT_DIFF" -p1)
if [ -n "$diff_output" ]; then
    cat >&2 << 'FOE'
clang-format check failed!
Please run inside a posix compatible shell with git and amend or commit the
results or pipe the output of this script into `git apply -p0`
git apply -p0 <<EOF
FOE
    cat << FOE
$diff_output
FOE
    cat >&2 << 'FOE'
EOF
FOE
    ret=1
fi

exit "${ret:-0}"
