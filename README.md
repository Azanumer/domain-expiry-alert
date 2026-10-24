# Domain Expiry Alert

Monitor domain expiration dates via WHOIS and get warned before a domain lapses. Built for cron and Nagios-style monitoring.

## What it does

- Reads a domain list (one per line, `#` comments allowed)
- Queries WHOIS per domain and parses the expiry date across registry formats (`Registry Expiry Date`, `Expiration Date`, `paid-till`, ISO-8601, `15-Jan-2027`, …)
- Classifies each domain: **ok / warning / critical / expired / unknown**
- Output as a human table or `--json`; exit codes `0` ok, `1` warning/unknown, `2` critical/expired, `3` usage error
- Optional `--to` mail digest when something needs attention (uses `mail`)

## Usage

```bash
cp domains.txt.example domains.txt   # add your domains
./check-domains.sh --file domains.txt --warn-days 30 --crit-days 7
./check-domains.sh --file domains.txt --json --quiet   # cron/Nagios friendly
```

## Cron

```cron
0 8 * * * /opt/domain-expiry-alert/check-domains.sh --file /opt/domain-expiry-alert/domains.txt --to ops@example.com --quiet
```

## Notes

- Requires the `whois` client. WHOIS rate limits apply — the default 15s `--timeout` keeps one slow registry from stalling the run.
- Domains whose expiry can't be parsed are reported as `unknown` (warning level), never silently OK.

## License

MIT
