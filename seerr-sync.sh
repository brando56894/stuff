#!/usr/bin/env bash
#
# jellyseerr_arr_check.sh
#
# Cross-checks requests in Jellyseerr against Sonarr (TV) and/or Radarr
# (movies), reports approved requests that never made it into the *arr app,
# and can optionally re-add them directly with --fix.
#
# Requirements: curl, jq
#
# Usage:
#   ./jellyseerr_arr_check.sh [--service sonarr|radarr|both] [--fix] [--yes]
#
# Options:
#   -s, --service   Which app to check: sonarr, radarr, or both (default: both)
#   -f, --fix       Add missing items to Sonarr/Radarr via their APIs
#   -y, --yes       Don't prompt for confirmation before fixing (for cron)
#   -h, --help      Show this help
#
# Environment variables:
#   JELLYSEERR_URL       (default http://localhost:5055)
#   JELLYSEERR_API_KEY   required
#   SONARR_URL           (default http://localhost:8989)
#   SONARR_API_KEY       required when checking sonarr
#   RADARR_URL           (default http://localhost:7878)
#   RADARR_API_KEY       required when checking radarr
#
#   Optional overrides used by --fix (otherwise the first root folder and
#   first quality profile reported by the app are used):
#   SONARR_ROOT_FOLDER, SONARR_QUALITY_PROFILE_ID
#   RADARR_ROOT_FOLDER, RADARR_QUALITY_PROFILE_ID
#
# Exit codes: 0 = nothing missing (or everything fixed successfully),
#             1 = missing items found (and not fixed, or fix failed),
#             2 = configuration/connection error.

set -euo pipefail

JELLYSEERR_URL="${JELLYSEERR_URL:-http://localhost:5055}"
SONARR_URL="${SONARR_URL:-http://localhost:8989}"
RADARR_URL="${RADARR_URL:-http://localhost:7878}"

SERVICE="both"
FIX=0
ASSUME_YES=0

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; }

fail() { echo "ERROR: $*" >&2; exit 2; }

while (( $# )); do
    case "$1" in
        -s|--service) SERVICE="${2:?--service needs a value}"; shift 2 ;;
        -f|--fix)     FIX=1; shift ;;
        -y|--yes)     ASSUME_YES=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            fail "Unknown argument: $1 (see --help)" ;;
    esac
done

case "$SERVICE" in sonarr|radarr|both) ;; *) fail "--service must be sonarr, radarr, or both" ;; esac

command -v curl >/dev/null || fail "curl is required"
command -v jq   >/dev/null || fail "jq is required"
[[ -n "${JELLYSEERR_API_KEY:-}" ]] || fail "JELLYSEERR_API_KEY is not set"
if [[ "$SERVICE" != "radarr" ]]; then
    [[ -n "${SONARR_API_KEY:-}" ]] || fail "SONARR_API_KEY is not set (needed for --service $SERVICE)"
fi
if [[ "$SERVICE" != "sonarr" ]]; then
    [[ -n "${RADARR_API_KEY:-}" ]] || fail "RADARR_API_KEY is not set (needed for --service $SERVICE)"
fi

JELLYSEERR_URL="${JELLYSEERR_URL%/}"
SONARR_URL="${SONARR_URL%/}"
RADARR_URL="${RADARR_URL%/}"

# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------

jelly_get() {
    curl -fsS --max-time 30 -H "X-Api-Key: ${JELLYSEERR_API_KEY}" "${JELLYSEERR_URL}$1"
}

arr_get() { # $1=base url  $2=api key  $3=path
    curl -fsS --max-time 30 -H "X-Api-Key: $2" "$1$3"
}

arr_post() { # $1=base url  $2=api key  $3=path  $4=json body
    curl -fsS --max-time 60 -X POST \
         -H "X-Api-Key: $2" -H "Content-Type: application/json" \
         -d "$4" "$1$3"
}

# ---------------------------------------------------------------------------
# Fetch all Jellyseerr requests (paginated)
# ---------------------------------------------------------------------------

echo "==> Fetching requests from Jellyseerr..."
take=100
skip=0
ALL_REQUESTS='[]'
while :; do
    page=$(jelly_get "/api/v1/request?take=${take}&skip=${skip}&filter=all&sort=added") \
        || fail "Could not fetch requests from Jellyseerr at ${JELLYSEERR_URL}"
    results=$(jq '.results' <<<"$page")
    count=$(jq 'length' <<<"$results")
    ALL_REQUESTS=$(jq -n --argjson a "$ALL_REQUESTS" --argjson b "$results" '$a + $b')
    (( count < take )) && break
    (( skip += take ))
done
echo "    Fetched $(jq 'length' <<<"$ALL_REQUESTS") total requests."

TOTAL_MISSING=0
TOTAL_FIX_FAILED=0

# Request status: 1=pending, 2=approved, 3=declined
status_label() {
    case "$1" in
        1) echo "pending" ;;
        2) echo "approved" ;;
        3) echo "declined" ;;
        *) echo "status:$1" ;;
    esac
}

# ---------------------------------------------------------------------------
# Sonarr (TV)
# ---------------------------------------------------------------------------

MISSING_TV=()   # each entry: tvdbId <TAB> title <TAB> comma-separated season numbers

check_sonarr() {
    echo
    echo "==> [Sonarr] Fetching series list..."
    local series
    series=$(arr_get "$SONARR_URL" "$SONARR_API_KEY" "/api/v3/series") \
        || fail "Could not fetch series from Sonarr at ${SONARR_URL}"
    local tvdb_ids
    tvdb_ids=$(jq '[.[].tvdbId]' <<<"$series")
    echo "    Sonarr has $(jq 'length' <<<"$tvdb_ids") series."

    local tv_requests
    tv_requests=$(jq '[.[] | select(.type == "tv")]' <<<"$ALL_REQUESTS")
    echo "    Jellyseerr has $(jq 'length' <<<"$tv_requests") TV requests."

    printf '\n%-45s %-10s %-10s %s\n' "TITLE" "TVDB ID" "REQUEST" "IN SONARR?"
    printf '%s\n' "--------------------------------------------------------------------------------"

    local req_status tmdb_id tvdb_id seasons title label in_arr details
    while IFS=$'\t' read -r req_status tmdb_id tvdb_id seasons; do
        label=$(status_label "$req_status")
        [[ "$label" == "declined" ]] && continue

        title="(unknown title)"
        if [[ "$tmdb_id" != "null" ]]; then
            details=$(jelly_get "/api/v1/tv/${tmdb_id}" || true)
            if [[ -n "$details" ]]; then
                title=$(jq -r '.name // "(unknown title)"' <<<"$details")
                if [[ "$tvdb_id" == "null" ]]; then
                    tvdb_id=$(jq -r '.externalIds.tvdbId // "null"' <<<"$details")
                fi
            fi
        fi

        if [[ "$tvdb_id" == "null" ]]; then
            printf '%-45.45s %-10s %-10s %s\n' "$title" "-" "$label" "NO TVDB ID (cannot check)"
            continue
        fi

        in_arr=$(jq --argjson id "$tvdb_id" 'any(.[]; . == $id)' <<<"$tvdb_ids")
        if [[ "$in_arr" == "true" ]]; then
            printf '%-45.45s %-10s %-10s %s\n' "$title" "$tvdb_id" "$label" "yes"
        elif [[ "$label" == "pending" ]]; then
            printf '%-45.45s %-10s %-10s %s\n' "$title" "$tvdb_id" "$label" "no (not yet approved)"
        else
            printf '%-45.45s %-10s %-10s %s\n' "$title" "$tvdb_id" "$label" "*** MISSING ***"
            MISSING_TV+=("${tvdb_id}"$'\t'"${title}"$'\t'"${seasons}")
        fi
    done < <(jq -r '.[] | [
                .status,
                (.media.tmdbId // "null"),
                (.media.tvdbId // "null"),
                ([.seasons[]?.seasonNumber] | join(","))
             ] | @tsv' <<<"$tv_requests")

    printf '%s\n' "--------------------------------------------------------------------------------"
    echo "[Sonarr] Missing: ${#MISSING_TV[@]}"
    (( TOTAL_MISSING += ${#MISSING_TV[@]} )) || true
}

fix_sonarr() {
    (( ${#MISSING_TV[@]} )) || return 0
    echo
    echo "==> [Sonarr] Adding ${#MISSING_TV[@]} missing series..."

    local root profile_id
    root="${SONARR_ROOT_FOLDER:-$(arr_get "$SONARR_URL" "$SONARR_API_KEY" "/api/v3/rootfolder" | jq -r '.[0].path // empty')}"
    profile_id="${SONARR_QUALITY_PROFILE_ID:-$(arr_get "$SONARR_URL" "$SONARR_API_KEY" "/api/v3/qualityprofile" | jq -r '.[0].id // empty')}"
    [[ -n "$root" ]]       || fail "Could not determine a Sonarr root folder (set SONARR_ROOT_FOLDER)"
    [[ -n "$profile_id" ]] || fail "Could not determine a Sonarr quality profile (set SONARR_QUALITY_PROFILE_ID)"
    echo "    Root folder: $root | Quality profile id: $profile_id"

    local entry tvdb_id title seasons lookup payload resp
    for entry in "${MISSING_TV[@]}"; do
        IFS=$'\t' read -r tvdb_id title seasons <<<"$entry"
        echo "    -> Adding '${title}' (tvdb:${tvdb_id})..."

        if ! lookup=$(arr_get "$SONARR_URL" "$SONARR_API_KEY" "/api/v3/series/lookup?term=tvdb%3A${tvdb_id}" | jq '.[0]') \
           || [[ -z "$lookup" || "$lookup" == "null" ]]; then
            echo "       FAILED: Sonarr lookup returned nothing for tvdb:${tvdb_id}"
            (( TOTAL_FIX_FAILED += 1 ))
            continue
        fi

        # Monitor only the seasons that were requested in Jellyseerr; if the
        # request had no season list, monitor everything.
        payload=$(jq --arg root "$root" --argjson qp "$profile_id" --arg seasons "$seasons" '
            ($seasons | split(",") | map(select(length > 0) | tonumber)) as $want
            | .qualityProfileId = $qp
            | .languageProfileId = (.languageProfileId // 1)
            | .rootFolderPath = $root
            | .monitored = true
            | .seasonFolder = true
            | .addOptions = { searchForMissingEpisodes: true }
            | if ($want | length) > 0 then
                  .seasons |= map(.monitored = ((.seasonNumber as $n | $want | index($n)) != null))
              else . end
        ' <<<"$lookup")

        if resp=$(arr_post "$SONARR_URL" "$SONARR_API_KEY" "/api/v3/series" "$payload" 2>&1); then
            echo "       OK: added with Sonarr id $(jq -r '.id' <<<"$resp")"
        else
            echo "       FAILED: $resp"
            (( TOTAL_FIX_FAILED += 1 ))
        fi
    done
}

# ---------------------------------------------------------------------------
# Radarr (movies)
# ---------------------------------------------------------------------------

MISSING_MOVIES=()   # each entry: tmdbId <TAB> title

check_radarr() {
    echo
    echo "==> [Radarr] Fetching movie list..."
    local movies
    movies=$(arr_get "$RADARR_URL" "$RADARR_API_KEY" "/api/v3/movie") \
        || fail "Could not fetch movies from Radarr at ${RADARR_URL}"
    local tmdb_ids
    tmdb_ids=$(jq '[.[].tmdbId]' <<<"$movies")
    echo "    Radarr has $(jq 'length' <<<"$tmdb_ids") movies."

    local movie_requests
    movie_requests=$(jq '[.[] | select(.type == "movie")]' <<<"$ALL_REQUESTS")
    echo "    Jellyseerr has $(jq 'length' <<<"$movie_requests") movie requests."

    printf '\n%-45s %-10s %-10s %s\n' "TITLE" "TMDB ID" "REQUEST" "IN RADARR?"
    printf '%s\n' "--------------------------------------------------------------------------------"

    local req_status tmdb_id title label in_arr details
    while IFS=$'\t' read -r req_status tmdb_id; do
        label=$(status_label "$req_status")
        [[ "$label" == "declined" ]] && continue

        if [[ "$tmdb_id" == "null" ]]; then
            printf '%-45.45s %-10s %-10s %s\n' "(unknown title)" "-" "$label" "NO TMDB ID (cannot check)"
            continue
        fi

        title="(unknown title)"
        details=$(jelly_get "/api/v1/movie/${tmdb_id}" || true)
        [[ -n "$details" ]] && title=$(jq -r '.title // "(unknown title)"' <<<"$details")

        in_arr=$(jq --argjson id "$tmdb_id" 'any(.[]; . == $id)' <<<"$tmdb_ids")
        if [[ "$in_arr" == "true" ]]; then
            printf '%-45.45s %-10s %-10s %s\n' "$title" "$tmdb_id" "$label" "yes"
        elif [[ "$label" == "pending" ]]; then
            printf '%-45.45s %-10s %-10s %s\n' "$title" "$tmdb_id" "$label" "no (not yet approved)"
        else
            printf '%-45.45s %-10s %-10s %s\n' "$title" "$tmdb_id" "$label" "*** MISSING ***"
            MISSING_MOVIES+=("${tmdb_id}"$'\t'"${title}")
        fi
    done < <(jq -r '.[] | [.status, (.media.tmdbId // "null")] | @tsv' <<<"$movie_requests")

    printf '%s\n' "--------------------------------------------------------------------------------"
    echo "[Radarr] Missing: ${#MISSING_MOVIES[@]}"
    (( TOTAL_MISSING += ${#MISSING_MOVIES[@]} )) || true
}

fix_radarr() {
    (( ${#MISSING_MOVIES[@]} )) || return 0
    echo
    echo "==> [Radarr] Adding ${#MISSING_MOVIES[@]} missing movies..."

    local root profile_id
    root="${RADARR_ROOT_FOLDER:-$(arr_get "$RADARR_URL" "$RADARR_API_KEY" "/api/v3/rootfolder" | jq -r '.[0].path // empty')}"
    profile_id="${RADARR_QUALITY_PROFILE_ID:-$(arr_get "$RADARR_URL" "$RADARR_API_KEY" "/api/v3/qualityprofile" | jq -r '.[0].id // empty')}"
    [[ -n "$root" ]]       || fail "Could not determine a Radarr root folder (set RADARR_ROOT_FOLDER)"
    [[ -n "$profile_id" ]] || fail "Could not determine a Radarr quality profile (set RADARR_QUALITY_PROFILE_ID)"
    echo "    Root folder: $root | Quality profile id: $profile_id"

    local entry tmdb_id title lookup payload resp
    for entry in "${MISSING_MOVIES[@]}"; do
        IFS=$'\t' read -r tmdb_id title <<<"$entry"
        echo "    -> Adding '${title}' (tmdb:${tmdb_id})..."

        if ! lookup=$(arr_get "$RADARR_URL" "$RADARR_API_KEY" "/api/v3/movie/lookup/tmdb?tmdbId=${tmdb_id}") \
           || [[ -z "$lookup" || "$lookup" == "null" ]]; then
            echo "       FAILED: Radarr lookup returned nothing for tmdb:${tmdb_id}"
            (( TOTAL_FIX_FAILED += 1 ))
            continue
        fi

        payload=$(jq --arg root "$root" --argjson qp "$profile_id" '
            .qualityProfileId = $qp
            | .rootFolderPath = $root
            | .monitored = true
            | .minimumAvailability = (.minimumAvailability // "announced")
            | .addOptions = { searchForMovie: true }
        ' <<<"$lookup")

        if resp=$(arr_post "$RADARR_URL" "$RADARR_API_KEY" "/api/v3/movie" "$payload" 2>&1); then
            echo "       OK: added with Radarr id $(jq -r '.id' <<<"$resp")"
        else
            echo "       FAILED: $resp"
            (( TOTAL_FIX_FAILED += 1 ))
        fi
    done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

[[ "$SERVICE" != "radarr" ]] && check_sonarr
[[ "$SERVICE" != "sonarr" ]] && check_radarr

echo
echo "=== Total missing across selected services: ${TOTAL_MISSING} ==="

if (( TOTAL_MISSING == 0 )); then
    echo "Nothing to do."
    exit 0
fi

if (( ! FIX )); then
    echo "Re-run with --fix to add the missing items directly to Sonarr/Radarr."
    exit 1
fi

if (( ! ASSUME_YES )); then
    read -r -p "Add ${TOTAL_MISSING} missing item(s) now? [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

[[ "$SERVICE" != "radarr" ]] && fix_sonarr
[[ "$SERVICE" != "sonarr" ]] && fix_radarr

echo
if (( TOTAL_FIX_FAILED > 0 )); then
    echo "Done, but ${TOTAL_FIX_FAILED} item(s) failed to add. See output above."
    exit 1
fi
echo "Done. All missing items were added and a search was triggered for each."
exit 0
