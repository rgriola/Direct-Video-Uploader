cd /Users/rodczaro/Desktop/00-Vibecode/live-fixer && xcodebuild -project LiveFixer.xcodeproj -scheme LiveFixer -destination 'generic/platform=iOS' -quiet build 2>&1 | grep -E "error:|BUILD" | head -10

