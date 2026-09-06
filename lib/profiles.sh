#!/bin/bash
# profiles.sh — profile resolution and per-profile chezmoi config.
# Profile application: Brewfile fragments (lib/brew.sh) and defaults
# overrides (lib/defaults.sh) key off resolve_profile below.

# resolve_profile — flag > DEVSEED_PROFILE env > persisted state > default.
resolve_profile() {
  if [ -n "${DEVSEED_PROFILE_FLAG:-}" ]; then
    echo "$DEVSEED_PROFILE_FLAG"
  elif [ -n "${DEVSEED_PROFILE:-}" ]; then
    echo "$DEVSEED_PROFILE"
  elif [ -f "$(state_dir)/profile" ]; then
    cat "$(state_dir)/profile"
  else
    echo "default"
  fi
}

# write_chezmoi_config lives in lib/dotfiles.sh next to chezmoi_cmd().
