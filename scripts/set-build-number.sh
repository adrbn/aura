#!/bin/sh
# Sets the build number of every target to the number of commits, counting the commit
# that will record it. It grows with each change — App Store Connect refuses an upload
# whose number isn't higher than the last — and a build can be traced back to its commit.
# The app, its widget and its watch app get the same number: an extension or watch app whose
# number differs is refused. The same goes for MARKETING_VERSION, which the watch app also carries.
#
# Run before archiving a release (App Store or IPA), then commit the project file.
# The version the public sees (MARKETING_VERSION) is set by hand, following CHANGELOG.md.
set -eu
ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
PROJECT="$ROOT/Aura/Aura.xcodeproj/project.pbxproj"
COUNT=$(( $(git -C "$ROOT" rev-list --count HEAD) + 1 ))
sed -i '' -E "s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = $COUNT;/" "$PROJECT"
echo "Build number: $COUNT"
