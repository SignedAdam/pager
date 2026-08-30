#!/bin/bash
# A weekly summary with a shape, not just a number. Pipe real figures into
# --sparkline and it draws them.
pager --title "Sales are up 34% this week" --source "acme" --accent "#28c840" \
      --body "12 new subscriptions, 2 churned. Best week since March." \
      --sparkline "4,6,5,9,8,12,17,16,22" \
      --chip "mrr \$1,840" --chip "+\$310" \
      --action "Dashboard:open https://example.com/admin" \
      --seconds 600
