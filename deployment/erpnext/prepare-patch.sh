#!/usr/bin/env bash
# Prepare a minimal Frappe source overlay for Dockerfile.patch.
set -euo pipefail

BASE_REF=${1:?Usage: prepare-patch.sh BASE_REF [TARGET_REF] [OUTPUT_DIR]}
TARGET_REF=${2:-HEAD}
OUTPUT_DIR=${3:-.release}

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/patch"

changes=$(git diff --name-status --find-renames "$BASE_REF" "$TARGET_REF" -- frappe/)
if [[ -z "$changes" ]]; then
	echo "No Frappe application changes between $BASE_REF and $TARGET_REF." >&2
	exit 1
fi

build_assets=0
while IFS=$'\t' read -r status path extra; do
	case "$status" in
	A|M)
		[[ -n "$path" && -z "$extra" ]] || {
			echo "Unexpected diff entry: $status $path $extra" >&2
			exit 1
		}
		mkdir -p "$OUTPUT_DIR/patch/$(dirname "$path")"
		git show "$TARGET_REF:$path" > "$OUTPUT_DIR/patch/$path"
		case "$path" in
		frappe/public/*|esbuild/*|package.json|yarn.lock|hooks.py) build_assets=1 ;;
		esac
		;;
	D|R*|C*)
		echo "Deleted, renamed, or copied files require a full image release: $status $path $extra" >&2
		exit 1
		;;
	*)
		echo "Unsupported diff status: $status" >&2
		exit 1
		;;
	esac
done <<< "$changes"

printf '%s\n' "$build_assets" > "$OUTPUT_DIR/build-assets"
printf '%s\n' "$changes" > "$OUTPUT_DIR/changed-files.txt"
printf 'Prepared %s source overlay (BUILD_ASSETS=%s).\n' "$OUTPUT_DIR" "$build_assets"
