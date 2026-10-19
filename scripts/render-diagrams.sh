#!/bin/zsh
# Renders the how-it-works diagrams (docs/diagrams/*.html) to PNG at 2× in docs/assets/how-it-works/, with Chrome.
#
#   scripts/render-diagrams.sh [name…]     e.g. scripts/render-diagrams.sh 00-overview
set -euo pipefail
cd "${0:A:h}/.."

chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[[ -x $chrome ]] || { print -u2 "Google Chrome is needed to render the diagrams."; exit 1; }
out=docs/assets/how-it-works
mkdir -p $out

names=("$@")
(( $#names )) || names=(docs/diagrams/[0-9]*.html(:t:r))
work=$(mktemp -d)
for name in $names; do
  # Chrome's teardown watchdog can exit non-zero after the screenshot is written, so the file is the check.
  "$chrome" --headless=new --user-data-dir=$work/profile --hide-scrollbars --allow-file-access-from-files \
    --force-device-scale-factor=2 --window-size=1200,675 --virtual-time-budget=3000 \
    --screenshot="$work/$name.png" "file://$PWD/docs/diagrams/$name.html" &>/dev/null || true
  [[ -s $work/$name.png ]] || { print -u2 "$name did not render."; exit 1; }
  mv $work/$name.png $out/$name.png
  print "$out/$name.png"
done
