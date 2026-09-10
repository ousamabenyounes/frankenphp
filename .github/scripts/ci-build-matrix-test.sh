#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPOSITORY_ROOT="$(cd -- "${SCRIPT_DIR}/../.." >/dev/null 2>&1 && pwd)"
readonly REPOSITORY_ROOT
readonly FULL_MATRIX_LABEL='ready to test'
readonly LEGACY_FULL_MATRIX_LABEL='full-build-matrix'
readonly PULL_REQUEST_ACTIVITY_TYPES='types: [opened, synchronize, reopened, labeled]'
readonly PRESERVED_MATRIX_SCRIPT="\${RUNNER_TEMP}/ci-build-matrix.sh"
readonly MATRIX_SCRIPT_COPY="cp .github/scripts/ci-build-matrix.sh \"\${RUNNER_TEMP}/ci-build-matrix.sh\""
readonly STATIC_CHECKOUT_REF="          ref: \${{ steps.check.outputs.ref }}"
readonly MATRIX_WORKFLOWS=(
	"${REPOSITORY_ROOT}/.github/workflows/docker.yaml"
	"${REPOSITORY_ROOT}/.github/workflows/static.yaml"
)

assert_workflow_label() {
	local label_count workflow

	for workflow in "${MATRIX_WORKFLOWS[@]}"; do
		label_count="$(grep -Fc "'${FULL_MATRIX_LABEL}'" "${workflow}" || true)"
		if [[ "${label_count}" -ne 1 ]]; then
			printf '%s must define the issue-specified full matrix label %q exactly once; found %d\n' \
				"${workflow}" "${FULL_MATRIX_LABEL}" "${label_count}" >&2
			return 1
		fi
		if grep -Fq "'${LEGACY_FULL_MATRIX_LABEL}'" "${workflow}"; then
			printf '%s still uses the unsupported full matrix label %q\n' "${workflow}" "${LEGACY_FULL_MATRIX_LABEL}" >&2
			return 1
		fi
		if ! grep -Fq "${PULL_REQUEST_ACTIVITY_TYPES}" "${workflow}"; then
			printf '%s does not run when the full matrix label is applied\n' "${workflow}" >&2
			return 1
		fi
	done
}

assert_preserved_matrix_script() {
	local copy_line ref_switch_line workflow

	for workflow in "${MATRIX_WORKFLOWS[@]}"; do
		copy_line="$(grep -nF "${MATRIX_SCRIPT_COPY}" "${workflow}" | cut -d: -f1 || true)"
		if [[ -z "${copy_line}" ]]; then
			printf '%s does not preserve the matrix script outside the mutable checkout\n' "${workflow}" >&2
			return 1
		fi
		if ! grep -Fq "${PRESERVED_MATRIX_SCRIPT}" "${workflow}"; then
			printf '%s does not execute the preserved matrix script\n' "${workflow}" >&2
			return 1
		fi
		if grep -Fq './.github/scripts/ci-build-matrix.sh' "${workflow}"; then
			printf '%s executes the matrix script from a checkout that may change refs\n' "${workflow}" >&2
			return 1
		fi
	done

	ref_switch_line="$(grep -nF "${STATIC_CHECKOUT_REF}" "${REPOSITORY_ROOT}/.github/workflows/static.yaml" | cut -d: -f1 || true)"
	if [[ -z "${ref_switch_line}" || "${copy_line}" -ge "${ref_switch_line}" ]]; then
		printf 'static.yaml must preserve the matrix script before checking out a release\n' >&2
		return 1
	fi
}

assert_output() {
	local kind="$1"
	local full_matrix="$2"
	local expected="$3"
	local actual

	actual="$(METADATA="${TEST_METADATA}" REBUILD_VARIANTS="${REBUILD_VARIANTS:-}" "${SCRIPT_DIR}/ci-build-matrix.sh" "${kind}" "${full_matrix}")"
	if [[ "${actual}" != "${expected}" ]]; then
		printf 'expected:\n%s\nactual:\n%s\n' "${expected}" "${actual}" >&2
		return 1
	fi
}

TEST_METADATA='{
	"group": {
		"default": {
			"targets": [
				"builder-php-8-2-bookworm",
				"builder-php-8-2-trixie",
				"builder-php-8-3-bookworm",
				"builder-php-8-3-trixie",
				"runner-php-8-2-bookworm",
				"runner-php-8-2-trixie",
				"runner-php-8-3-bookworm",
				"runner-php-8-3-trixie"
			]
		}
	},
	"target": {
		"builder-php-8-2-bookworm": {
			"platforms": ["linux/amd64", "linux/arm64"]
		},
		"static-builder-musl": {
			"platforms": ["linux/amd64", "linux/arm64"]
		}
	}
}'

assert_output docker false $'variants=["php-8-2-bookworm","php-8-3-bookworm"]\nplatforms=["linux/amd64"]'
assert_output docker true $'variants=["php-8-2-bookworm","php-8-2-trixie","php-8-3-bookworm","php-8-3-trixie"]\nplatforms=["linux/amd64","linux/arm64"]'
assert_output static false 'platforms=["linux/amd64"]'
assert_output static true 'platforms=["linux/amd64","linux/arm64"]'

# On scheduled rebuilds REBUILD_VARIANTS narrows the docker matrix to the changed bases only.
REBUILD_VARIANTS='["php-8-2-trixie","php-8-3-bookworm"]' \
	assert_output docker true $'variants=["php-8-2-trixie","php-8-3-bookworm"]\nplatforms=["linux/amd64","linux/arm64"]'
# The empty-array sentinel leaves the matrix untouched.
REBUILD_VARIANTS='[]' \
	assert_output docker true $'variants=["php-8-2-bookworm","php-8-2-trixie","php-8-3-bookworm","php-8-3-trixie"]\nplatforms=["linux/amd64","linux/arm64"]'

assert_workflow_label
assert_preserved_matrix_script
