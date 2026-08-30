#!/bin/bash
# Deploy result. Red on failure, lime on success, with a rollback button.
status="${1:-ok}"
if [ "$status" = "ok" ]; then
  pager --title "Deployed to production" --source "coolify" --accent "#c8ff00" \
        --chip "$(git rev-parse --short HEAD)" --chip "$(git branch --show-current)" \
        --action "Open site:open https://example.com"
else
  pager --title "Deploy failed on production" --source "coolify" --accent "#ff5f57" \
        --body "$(tail -3 /tmp/deploy.log 2>/dev/null)" \
        --chip "$(git rev-parse --short HEAD)" \
        --action "Logs:open https://coolify.example.com" \
        --action "Rollback:./rollback.sh production" \
        --pinned
fi
