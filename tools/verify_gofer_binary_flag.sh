#!/bin/bash
# Copyright 2026 The gVisor Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Verifies that a built runsc binary exposes and validates --gofer-binary.
# Used by `make cortex-gofer` and GitHub Actions (see .github/workflows/build.yml).

set -euo pipefail

readonly runsc="${1:?usage: $0 /path/to/runsc}"

if [[ ! -x "${runsc}" ]]; then
  echo "FAIL: runsc is not executable: ${runsc}" >&2
  exit 1
fi

# The flag name and help string are linked into the binary when registered.
if ! strings "${runsc}" | grep -Fq 'gofer-binary'; then
  echo "FAIL: ${runsc} was built without --gofer-binary support" >&2
  exit 1
fi

# Config validation must reject a relative path before sandbox create proceeds.
# Top-level runsc flags must appear before the subcommand name.
if err="$("${runsc}" --gofer-binary=relative/shim create --bundle /tmp test 2>&1)"; then
  echo "FAIL: expected create to reject relative --gofer-binary" >&2
  exit 1
fi
if grep -Fq 'not defined' <<<"${err}" && grep -Fq 'gofer-binary' <<<"${err}"; then
  echo "FAIL: ${runsc} was built without --gofer-binary support" >&2
  exit 1
fi
if ! grep -Fq 'gofer-binary must be an absolute path' <<<"${err}"; then
  echo "FAIL: unexpected error for relative --gofer-binary:" >&2
  echo "${err}" >&2
  exit 1
fi

# Missing binary path must fail validation.
if err="$("${runsc}" --gofer-binary=/no/such/cortex-gofer-shim create --bundle /tmp test 2>&1)"; then
  echo "FAIL: expected create to reject missing --gofer-binary path" >&2
  exit 1
fi
if grep -Fq 'not defined' <<<"${err}" && grep -Fq 'gofer-binary' <<<"${err}"; then
  echo "FAIL: ${runsc} was built without --gofer-binary support" >&2
  exit 1
fi
if ! grep -Fq 'gofer-binary "/no/such/cortex-gofer-shim"' <<<"${err}"; then
  echo "FAIL: unexpected error for missing --gofer-binary:" >&2
  echo "${err}" >&2
  exit 1
fi

echo "PASS: ${runsc} supports --gofer-binary"
