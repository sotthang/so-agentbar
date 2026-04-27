#!/usr/bin/env bash
# post-edit-check.sh — PostToolUse hook: runs lint/typecheck after Edit/Write/MultiEdit
# Stdin: Claude Code hook JSON (ignored — cwd-based detection)
# Exit 0 = skip or all pass / non-zero = one or more tools failed

# Consume stdin to avoid broken pipe
cat > /dev/null

EXIT_CODE=0
SCRIPT_NAME="$(basename "$0")"

# ── Node.js / npm ──────────────────────────────────────────────────────────
if [ -f "package.json" ]; then
  # Detect if "lint" script exists (grep fallback, works without jq)
  if grep -q '"lint"' package.json; then
    npm run lint --silent 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "$SCRIPT_NAME: npm run lint failed (exit $rc)" >&2
      EXIT_CODE=$rc
    fi
  fi

  if grep -q '"typecheck"' package.json; then
    npm run typecheck --silent 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "$SCRIPT_NAME: npm run typecheck failed (exit $rc)" >&2
      EXIT_CODE=$rc
    fi
  fi
fi

# ── Python ─────────────────────────────────────────────────────────────────
if [ -f "pyproject.toml" ] || [ -f "setup.py" ]; then
  if command -v ruff &>/dev/null; then
    ruff check . 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "$SCRIPT_NAME: ruff check failed (exit $rc)" >&2
      EXIT_CODE=$rc
    fi
  fi
  if command -v mypy &>/dev/null; then
    mypy . 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "$SCRIPT_NAME: mypy failed (exit $rc)" >&2
      EXIT_CODE=$rc
    fi
  fi
fi

# ── Go ─────────────────────────────────────────────────────────────────────
if [ -f "go.mod" ]; then
  if command -v go &>/dev/null; then
    go vet ./... 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "$SCRIPT_NAME: go vet failed (exit $rc)" >&2
      EXIT_CODE=$rc
    fi
  fi
fi

# ── Rust ───────────────────────────────────────────────────────────────────
if [ -f "Cargo.toml" ]; then
  if command -v cargo &>/dev/null; then
    cargo check 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "$SCRIPT_NAME: cargo check failed (exit $rc)" >&2
      EXIT_CODE=$rc
    fi
  fi
fi

exit "$EXIT_CODE"
