#!/usr/bin/env bash
#
# domain-expiry-alert — monitor domain expiration dates via WHOIS.
#
# Reads a list of domains (one per line), queries WHOIS for each, parses the
# expiry date, and reports domains expiring soon. Designed for cron + Nagios.
#
# Usage:
#   ./check-domains.sh --file domains.txt [--warn-days 30] [--crit-days 7]
#                      [--json] [--quiet] [--timeout 15] [--to ops@example.com]
#
# Exit codes: 0 = all OK, 1 = warning (or unknown), 2 = critical, 3 = usage error.
#
# Cron example (daily at 08:00):
#   0 8 * * * /opt/domain-expiry-alert/check-domains.sh --file /opt/domain-expiry-alert/domains.txt --to ops@example.com

set -euo pipefail

FILE=""
WARN_DAYS=30
CRIT_DAYS=7
JSON=0
QUIET=0
TIMEOUT=15
MAIL_TO=""

usage() {
    sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-3}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --file)      FILE="$2"; shift 2 ;;
        --warn-days) WARN_DAYS="$2"; shift 2 ;;
        --crit-days) CRIT_DAYS="$2"; shift 2 ;;
        --json)      JSON=1; shift ;;
        --quiet)     QUIET=1; shift ;;
        --timeout)   TIMEOUT="$2"; shift 2 ;;
        --to)        MAIL_TO="$2"; shift 2 ;;
        -h|--help)   usage 0 ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
done

[[ -z "$FILE" ]] && { echo "Error: --file is required" >&2; usage; }
[[ -f "$FILE" ]] || { echo "Error: file not found: $FILE" >&2; exit 3; }
[[ "$WARN_DAYS" -ge "$CRIT_DAYS" ]] || { echo "Error: --warn-days must be >= --crit-days" >&2; exit 3; }

command -v whois >/dev/null || { echo "Error: 'whois' not installed" >&2; exit 3; }

# ---------------------------------------------------------------------------
# Parse an expiry date out of raw whois output.
# Prints epoch seconds, or nothing when unparseable.
# ---------------------------------------------------------------------------
parse_expiry() {
    local raw="$1" line datepart epoch

    # Registry/registrar field names seen in the wild, most specific first.
    line=$(printf '%s\n' "$raw" | grep -iE '^\s*(registry expiry date|registrar registration expiration date|expiration date|expiry date|expires:|paid-till|renewal date)\s*:' | head -n1 || true)
    [[ -z "$line" ]] && return 1

    datepart=$(printf '%s' "$line" | sed -E 's/^[^:]*:[[:space:]]*//')
    epoch=$(date -d "$datepart" +%s 2>/dev/null) || return 1
    printf '%s' "$epoch"
}

now=$(date +%s)

results=()   # "domain|status|days|expiry_iso"
worst=0      # 0 ok, 1 warn/unknown, 2 crit

while IFS= read -r domain || [[ -n "$domain" ]]; do
    # Skip blanks and comments.
    domain=$(printf '%s' "$domain" | tr -d '[:space:]')
    [[ -z "$domain" || "$domain" == \#* ]] && continue

    raw=$(timeout "$TIMEOUT" whois "$domain" 2>/dev/null || true)
    if expiry=$(parse_expiry "$raw"); then
        days=$(( (expiry - now) / 86400 ))
        iso=$(date -d "@$expiry" +%F)
        if (( days < 0 )); then
            status="expired";   worst=2
        elif (( days <= CRIT_DAYS )); then
            status="critical";  worst=2
        elif (( days <= WARN_DAYS )); then
            status="warning";   [[ $worst -lt 1 ]] && worst=1
        else
            status="ok"
        fi
        results+=("$domain|$status|$days|$iso")
    else
        results+=("$domain|unknown||")
        [[ $worst -lt 1 ]] && worst=1
    fi
done < "$FILE"

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if (( JSON )); then
    printf '{\n  "checked_at": "%s",\n  "warn_days": %s,\n  "crit_days": %s,\n  "domains": [\n' \
        "$(date -u +%FT%TZ)" "$WARN_DAYS" "$CRIT_DAYS"
    first=1
    for r in "${results[@]}"; do
        IFS='|' read -r d s days iso <<< "$r"
        (( first )) && first=0 || printf ',\n'
        days_json="${days:-null}"
        if [[ -n "$iso" ]]; then iso_json="\"$iso\""; else iso_json="null"; fi
        printf '    {"domain": "%s", "status": "%s", "days_left": %s, "expiry": %s}' \
            "$d" "$s" "$days_json" "$iso_json"
    done
    printf '\n  ]\n}\n'
else
    if (( QUIET == 0 )) || (( worst > 0 )); then
        printf '%-32s %-9s %10s %s\n' "DOMAIN" "STATUS" "DAYS LEFT" "EXPIRY"
        for r in "${results[@]}"; do
            IFS='|' read -r d s days iso <<< "$r"
            printf '%-32s %-9s %10s %s\n' "$d" "$s" "${days:--}" "${iso:--}"
        done
    fi
fi

# Optional mail digest when something needs attention.
if [[ -n "$MAIL_TO" && $worst -gt 0 ]] && command -v mail >/dev/null; then
    {
        echo "Subject: [domain-expiry-alert] $worst issue(s) need attention"
        echo "To: $MAIL_TO"
        echo
        for r in "${results[@]}"; do
            IFS='|' read -r d s days iso <<< "$r"
            [[ "$s" == "ok" ]] || printf '%s: %s (%s days, expires %s)\n' "$d" "$s" "${days:-?}" "${iso:-?}"
        done
    } | mail -t
fi

exit "$worst"
