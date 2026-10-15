#!/bin/bash
# Fetch brand marks for the ambient source column from Simple Icons (CC0).
# Writes assets/brands/<slug>.svg (monochrome path) and prints "slug #hex" lines.
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p assets/brands
for slug in github gitlab githubactions bitbucket coolify docker kubernetes vercel netlify cloudflare \
            digitalocean hetzner stripe paypal sentry grafana uptimekuma linear jira notion discord \
            telegram gmail googlecalendar apple postgresql redis npm; do
  if curl -fsSL "https://cdn.jsdelivr.net/npm/simple-icons@13/icons/$slug.svg" -o "assets/brands/$slug.svg"; then
    hex=$(curl -fsSL "https://cdn.simpleicons.org/$slug" | grep -o 'fill="#[0-9a-fA-F]*"' | head -1 | cut -d'"' -f2)
    echo "$slug $hex"
  else
    rm -f "assets/brands/$slug.svg"; echo "$slug missing" >&2
  fi
done
