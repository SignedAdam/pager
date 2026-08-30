#!/bin/bash
# Raise a panel for whatever was just copied, with a keep-it button.
text="$(pbpaste)"
kind="text"; case "$text" in http*) kind="url" ;; esac
pager --title "${text:0:80}" --source "clipboard" --accent "#3b8eea" \
      --subtitle "copied just now" --chip "$kind" \
      --action "Copy again:printf %s $(printf %q "$text") | pbcopy" \
      --seconds 20
