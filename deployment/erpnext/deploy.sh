#!/usr/bin/env bash
# Build, stage, smoke-test, and promote a minimal Frappe image overlay.
# This script runs on the deployment host, never inside an application container.
set -euo pipefail

: "${RELEASE_DIR:?Set RELEASE_DIR to the uploaded release directory}"
: "${RELEASE_TAG:?Set RELEASE_TAG to a unique Docker tag}"

GITOPS_DIR=${GITOPS_DIR:-/home/ubuntu/gitops}
PRODUCTION_COMPOSE=${PRODUCTION_COMPOSE:-$GITOPS_DIR/erpnext-zh-green.yaml}
STAGING_COMPOSE=${STAGING_COMPOSE:-$GITOPS_DIR/erpnext-zh-staging.yaml}
SITE=${SITE:-erp.amoze.net}
IMAGE_REPOSITORY=${IMAGE_REPOSITORY:-local/erpnext-china}
BUILD_ASSETS=${BUILD_ASSETS:-0}
WAIT_TIMEOUT=${WAIT_TIMEOUT:-180}
CURL_TIMEOUT=${CURL_TIMEOUT:-20}
SOURCE_REF=${SOURCE_REF:-unknown}
PATCH_DIR="$RELEASE_DIR/patch"
DOCKERFILE="$RELEASE_DIR/Dockerfile.patch"

fail() {
	echo "ERROR: $*" >&2
	exit 1
}

log() {
	printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"
}

[[ "$RELEASE_TAG" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || fail "Invalid RELEASE_TAG: $RELEASE_TAG"
[[ "$BUILD_ASSETS" == "0" || "$BUILD_ASSETS" == "1" ]] || fail "BUILD_ASSETS must be 0 or 1"
[[ "$WAIT_TIMEOUT" =~ ^[0-9]+$ ]] || fail "WAIT_TIMEOUT must be an integer"
[[ "$CURL_TIMEOUT" =~ ^[0-9]+$ ]] || fail "CURL_TIMEOUT must be an integer"
[[ -d "$PATCH_DIR" ]] || fail "Missing patch directory: $PATCH_DIR"
[[ -f "$DOCKERFILE" ]] || fail "Missing Dockerfile: $DOCKERFILE"
[[ -f "$PRODUCTION_COMPOSE" ]] || fail "Missing production Compose file: $PRODUCTION_COMPOSE"
[[ -f "$STAGING_COMPOSE" ]] || fail "Missing staging Compose file: $STAGING_COMPOSE"

docker compose --file "$PRODUCTION_COMPOSE" config -q
docker compose --file "$STAGING_COMPOSE" config -q

application_image() {
	docker compose --file "$1" config --images | awk '/^local\/erpnext-china:/ { print; exit }'
}

replace_image() {
	local compose_file=$1 from_image=$2 to_image=$3
	python3 - "$compose_file" "$from_image" "$to_image" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
old = sys.argv[2]
new = sys.argv[3]
content = path.read_text()
count = content.count(old)
if not count:
    raise SystemExit(f"image {old!r} was not found in {path}")
path.write_text(content.replace(old, new))
print(f"updated {count} image reference(s) in {path}")
PY
}

rollback_compose() {
	local compose_file=$1 backup_file=$2 environment_name=$3
	log "Rolling back $environment_name Compose file."
	cp "$backup_file" "$compose_file"
	docker compose --file "$compose_file" config -q
	docker compose --file "$compose_file" up --detach --wait --wait-timeout "$WAIT_TIMEOUT"
}

clear_metadata_cache() {
	local compose_file=$1
	docker compose --file "$compose_file" exec -T backend \
		bench --site "$SITE" clear-cache </dev/null
}

smoke_test() {
	local compose_file=$1 environment_name=$2 endpoint ping_response desk_status
	if ! endpoint=$(docker compose --file "$compose_file" port frontend 8080); then
		echo "ERROR: Could not resolve $environment_name frontend port" >&2
		return 1
	fi
	if [[ -z "$endpoint" ]]; then
		echo "ERROR: $environment_name frontend has no published port" >&2
		return 1
	fi

	if ! ping_response=$(curl --fail --silent --show-error --max-time "$CURL_TIMEOUT" \
		--header "Host: $SITE" "http://$endpoint/api/method/ping"); then
		echo "ERROR: $environment_name ping request failed" >&2
		return 1
	fi
	if [[ "$ping_response" != *'"pong"'* ]]; then
		echo "ERROR: $environment_name ping did not return pong" >&2
		return 1
	fi

	if ! desk_status=$(curl --silent --show-error --max-time "$CURL_TIMEOUT" --output /dev/null \
		--write-out '%{http_code}' --header "Host: $SITE" "http://$endpoint/desk"); then
		echo "ERROR: $environment_name Desk request failed" >&2
		return 1
	fi
	case "$desk_status" in
	200|301|302) ;;
	*)
		echo "ERROR: $environment_name Desk check returned HTTP $desk_status" >&2
		return 1
		;;
	esac

	# Optional marker gives small UI-only releases a direct source-presence check.
	if [[ -n "${SMOKE_MARKER:-}" ]]; then
		if [[ -z "${SMOKE_PATH:-}" ]]; then
			echo "ERROR: Set SMOKE_PATH when using SMOKE_MARKER" >&2
			return 1
		fi
		if ! docker compose --file "$compose_file" exec -T \
			-e "SMOKE_MARKER=$SMOKE_MARKER" -e "SMOKE_PATH=$SMOKE_PATH" backend \
			sh -lc 'grep -Fq -- "$SMOKE_MARKER" "$SMOKE_PATH"' </dev/null; then
			echo "ERROR: $environment_name smoke marker was not found" >&2
			return 1
		fi
	fi

	log "$environment_name smoke test passed (ping and Desk HTTP $desk_status)."
}

base_image=$(application_image "$PRODUCTION_COMPOSE")
[[ -n "$base_image" ]] || fail "Could not determine the current application image"
new_image="$IMAGE_REPOSITORY:$RELEASE_TAG"
backup_dir="$RELEASE_DIR/rollback"
mkdir -p "$backup_dir"

cp "$PRODUCTION_COMPOSE" "$backup_dir/production-compose.yaml"
cp "$STAGING_COMPOSE" "$backup_dir/staging-compose.yaml"
old_image_id=$(docker image inspect "$base_image" --format '{{.Id}}')
printf 'source_ref=%s\nbase_image=%s\nbase_image_id=%s\nnew_image=%s\nbuild_assets=%s\n' \
	"$SOURCE_REF" "$base_image" "$old_image_id" "$new_image" "$BUILD_ASSETS" > "$RELEASE_DIR/deployment-record.txt"

# Require a pre-provisioned staging site. Bootstrap is a one-time, deliberate
# operation; every release must reuse this environment and must not create data.
docker compose --file "$STAGING_COMPOSE" exec -T backend \
	sh -lc "test -d /home/frappe/frappe-bench/sites/$SITE" </dev/null \
	|| fail "Persistent staging site $SITE is absent"

log "Building $new_image from $base_image (BUILD_ASSETS=$BUILD_ASSETS)."
# The base image already contains all application dependencies. BuildKit keeps
    # its layer metadata on the deployment host, so no multi-gigabyte cache export is needed.
docker buildx build --load --pull=false --progress=plain \
	--build-arg "BASE_IMAGE=$base_image" \
	--build-arg "BUILD_ASSETS=$BUILD_ASSETS" \
	--file "$DOCKERFILE" --tag "$new_image" "$RELEASE_DIR"
new_image_id=$(docker image inspect "$new_image" --format '{{.Id}}')
printf 'new_image_id=%s\n' "$new_image_id" >> "$RELEASE_DIR/deployment-record.txt"

log "Promoting $new_image to staging."
replace_image "$STAGING_COMPOSE" "$base_image" "$new_image"
if ! docker compose --file "$STAGING_COMPOSE" config -q \
	|| ! docker compose --file "$STAGING_COMPOSE" up --detach --wait --wait-timeout "$WAIT_TIMEOUT" \
	|| ! clear_metadata_cache "$STAGING_COMPOSE" \
	|| ! smoke_test "$STAGING_COMPOSE" staging; then
	rollback_compose "$STAGING_COMPOSE" "$backup_dir/staging-compose.yaml" staging || true
	fail "Staging verification failed; production was not changed"
fi

log "Promoting $new_image to production."
replace_image "$PRODUCTION_COMPOSE" "$base_image" "$new_image"
if ! docker compose --file "$PRODUCTION_COMPOSE" config -q \
	|| ! docker compose --file "$PRODUCTION_COMPOSE" up --detach --wait --wait-timeout "$WAIT_TIMEOUT" \
	|| ! clear_metadata_cache "$PRODUCTION_COMPOSE" \
	|| ! smoke_test "$PRODUCTION_COMPOSE" production; then
	rollback_compose "$PRODUCTION_COMPOSE" "$backup_dir/production-compose.yaml" production || true
	fail "Production verification failed and rollback was attempted"
fi

printf 'status=deployed\ndeployed_at=%s\n' "$(date -u +%FT%TZ)" >> "$RELEASE_DIR/deployment-record.txt"
log "Deployment succeeded: $new_image ($new_image_id)."
