# `lgx test` harness under `LGX_HOME`

## Overview

Move the generated `lgx test` harness out of the system temp directory
and into lgx-managed state:

```text
$LGX_HOME/tmp/lgx-test-<version>.lg
```

The harness keeps the versioned static filename introduced earlier and is
overwritten on each run for the same lgx version.

## Context

- `lgx/cache.lg` owns `LGX_HOME` resolution today through a private
  `home-dir` helper.
- `lgx/test_runner.lg` writes the harness source before `lgx.main`
  invokes `lg`.
- `lgx.main/version` remains the single source of truth for the harness
  filename version.
- E2E tests already run under throwaway `LGX_HOME` roots.

## Implementation Steps

### Task 1: Share `LGX_HOME` resolution

- [x] add `lgx/home.lg` with `root` and `tmp-dir`
- [x] update `lgx/cache.lg` to use `lgx.home/root`
- [x] add unit tests for `lgx.home`

### Task 2: Write harness under `$LGX_HOME/tmp`

- [x] update `lgx/test_runner.lg` to use `lgx.home/tmp-dir`
- [x] ensure `$LGX_HOME/tmp` exists before writing the harness
- [x] update unit tests to assert the full `$LGX_HOME/tmp` path

### Task 3: Update public docs and e2e coverage

- [x] update architecture docs and README state layout
- [x] update e2e verbose test assertions for `$LGX_HOME/tmp`
- [x] run unit and e2e tests with an `lg` that supports `-source-paths`

## Completion Notes

Implemented. `lgx test` now writes
`$LGX_HOME/tmp/lgx-test-<version>.lg`, creating the `tmp` directory when
needed and overwriting the same file for each lgx version. Verification
passed with `/Users/andrew/Projects/let-go/lg` as `LGX_LG`.
