#!/usr/bin/env bash
# Runs the checks this change affects, several at a time, and stops the moment one of them fails.
#
# Called with no arguments it asks what-changed which targets are affected and runs only those, so a
# documentation-only change runs nothing at all. Called with target names it runs exactly those,
# because the caller has already decided. --force runs every target whatever changed.
#
# Nothing here records a baseline. Each target captures its own when it passes, so running one by
# hand marks it up to date exactly as a run from here does, and one target passing never marks
# another as passed.
#
# what-changed reads the git history, so in a directory that is not a git repository yet it cannot
# say what changed. Name the targets instead:
#   bash scripts/test-everything.sh compile test smoke
#
# Usage:
#   bash scripts/test-everything.sh                # only what changed
#   bash scripts/test-everything.sh --force        # every target
#   bash scripts/test-everything.sh --plan         # print the decision, run nothing
#   bash scripts/test-everything.sh compile test   # just those, whatever changed
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_DIR"

# Every target there is. The names match what-changed.yaml exactly, because what-changed reports
# these names back and this script looks each one up in the table below.
ALL_TARGETS=(compile test smoke)

# What each target runs. Kept here rather than in a file of its own because this script is the only
# thing that runs them.
command_for() {
    case "$1" in
        compile) echo "zig build" ;;
        test) echo "zig build test" ;;
        smoke) echo "bash scripts/smoke.sh" ;;
        *) return 1 ;;
    esac
}

# Run with no arguments the script prints how to use it, then carries on with its default, which is
# to run only what changed.
if [ "$#" -eq 0 ]; then
    echo "Usage: bash scripts/test-everything.sh [--force] [--plan] [target...]"
    echo "  With no arguments, runs only the targets that changed."
    echo "  Targets: ${ALL_TARGETS[*]}. When what-changed has no git repository to read, name them: bash scripts/test-everything.sh compile test smoke"
    echo ""
fi

FORCE=false
PLAN_ONLY=false
NAMED_TARGETS=()

for ARGUMENT in "$@"; do
    case "$ARGUMENT" in
        --force)
            FORCE=true
            ;;
        --plan)
            PLAN_ONLY=true
            ;;
        --*)
            echo "Unknown option \"$ARGUMENT\". Known options: --force, --plan." >&2
            exit 1
            ;;
        *)
            NAMED_TARGETS+=("$ARGUMENT")
            ;;
    esac
done

if [ "${#NAMED_TARGETS[@]}" -gt 0 ]; then
    TARGETS=("${NAMED_TARGETS[@]}")
elif [ "$FORCE" = true ]; then
    TARGETS=("${ALL_TARGETS[@]}")
else
    if ! command -v what-changed >/dev/null 2>&1; then
        echo "what-changed is not on the PATH." >&2
        echo "Install the pinned toolchain, or pass --force to run every target without it." >&2
        exit 1
    fi

    TARGETS=()
    while IFS= read -r LINE; do
        if [ -n "$LINE" ]; then
            TARGETS+=("$LINE")
        fi
    done <<< "$(what-changed targets)"

    if [ "${#TARGETS[@]}" -eq 0 ]; then
        echo "Nothing to run: nothing has changed since the last passing run."
        echo "Use --force to run every target anyway."
        exit 0
    fi
fi

for TARGET in "${TARGETS[@]}"; do
    if ! command_for "$TARGET" >/dev/null; then
        echo "Unknown target \"$TARGET\". Known targets: ${ALL_TARGETS[*]}." >&2
        exit 1
    fi
done

if [ "$PLAN_ONLY" = true ]; then
    echo "Would run: ${TARGETS[*]}"
    echo "--plan given, running nothing."
    exit 0
fi

# Everything this script writes goes here, and nothing is ever removed: it is a tmp directory.
LOG_DIR="$REPO_DIR/tmp/test-everything"
mkdir -p "$LOG_DIR"

# Pids of the targets still believed to be running, in the same order as TARGETS.
TARGET_PIDS=()

# Kills a process and everything it started. Killing only the target's own pid would orphan the real
# work, which would then keep running after this script had exited.
kill_tree() {
    local pid="$1"
    local child
    for child in $(pgrep -P "$pid" 2>/dev/null); do
        kill_tree "$child"
    done
    kill -TERM "$pid" 2>/dev/null || true
}

cleanup() {
    local pid
    for pid in "${TARGET_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill_tree "$pid"
        fi
    done
}
trap cleanup EXIT
trap 'exit 130' INT TERM

echo "Running: ${TARGETS[*]}"

for TARGET in "${TARGETS[@]}"; do
    (
        eval "$(command_for "$TARGET")" > "$LOG_DIR/$TARGET.log" 2>&1
        CODE="$?"
        echo "$CODE" > "$LOG_DIR/$TARGET.code"
        # The subshell exits with the target's own code, because `wait -n` below reads that to
        # decide whether to stop. Ending on the `echo` above would make every target look passed.
        exit "$CODE"
    ) &
    TARGET_PIDS+=("$!")
done

# Waits for whichever target finishes next rather than for them in order, so the first failure
# stops the run instead of being reported once the slowest target has finished for nothing.
FAILED=""
REMAINING="${#TARGETS[@]}"
while [ "$REMAINING" -gt 0 ]; do
    if ! wait -n; then
        FAILED="yes"
        break
    fi
    REMAINING=$((REMAINING - 1))
done

if [ -n "$FAILED" ]; then
    for TARGET in "${TARGETS[@]}"; do
        if [ -f "$LOG_DIR/$TARGET.code" ] && [ "$(cat "$LOG_DIR/$TARGET.code")" != "0" ]; then
            echo ""
            echo "=== $TARGET failed ==="
            cat "$LOG_DIR/$TARGET.log"
            echo "Re-run it with: $(command_for "$TARGET")"
        fi
    done
    echo "" >&2
    echo "Failed. The rest were stopped." >&2
    exit 1
fi

for TARGET in "${TARGETS[@]}"; do
    if [ -f "$LOG_DIR/$TARGET.log" ]; then
        echo ""
        echo "=== $TARGET ==="
        cat "$LOG_DIR/$TARGET.log"
    fi
done

echo ""
echo "Passed: ${TARGETS[*]}"
