#!/bin/bash

# Script to copy the compiled app to /Applications and refresh system caches

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Find the most recently built app in DerivedData
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData -name "*.app" -type d -depth 4 | \
    grep -v "Archive" | \
    grep "Build/Products" | \
    xargs ls -dt 2>/dev/null | \
    head -n 1)

if [ -z "$APP_PATH" ]; then
    echo -e "${RED}Error: No compiled app found in DerivedData${NC}"
    echo "Please build your project in Xcode first."
    exit 1
fi

APP_NAME=$(basename "$APP_PATH")
APP_NAME_WITHOUT_EXT="${APP_NAME%.app}"
DEST_PATH="/Applications/$APP_NAME"

echo "Found app: $APP_NAME"
echo "Path: $APP_PATH"
echo ""

# Check if the app is currently running
if pgrep -x "$APP_NAME_WITHOUT_EXT" > /dev/null; then
    echo -e "${YELLOW}⚠ $APP_NAME_WITHOUT_EXT is currently running${NC}"
    echo "Quitting the app..."
    osascript -e "quit app \"$APP_NAME_WITHOUT_EXT\"" 2>/dev/null
    sleep 1
    
    # Force quit if still running
    if pgrep -x "$APP_NAME_WITHOUT_EXT" > /dev/null; then
        echo "Force quitting..."
        killall "$APP_NAME_WITHOUT_EXT" 2>/dev/null
        sleep 1
    fi
    echo -e "${GREEN}✓ App quit successfully${NC}"
fi

# Remove the old version from Applications
if [ -e "$DEST_PATH" ]; then
    echo "Removing old version from /Applications..."
    rm -rf "$DEST_PATH"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Old version removed${NC}"
    else
        echo -e "${RED}✗ Failed to remove old version${NC}"
        exit 1
    fi
fi

echo "Copying new version to /Applications..."

# Copy the app to Applications
cp -R "$APP_PATH" /Applications/

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Successfully copied $APP_NAME to /Applications${NC}"
    
    # Clear macOS launch services cache to ensure the new version is recognized
    echo "Refreshing Launch Services database..."
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST_PATH"
    
    # Clear extended attributes that might cause issues
    xattr -cr "$DEST_PATH" 2>/dev/null
    
    echo -e "${GREEN}✓ Cache refreshed${NC}"
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}Done! You can now launch $APP_NAME_WITHOUT_EXT${NC}"
    echo -e "${GREEN}========================================${NC}"
else
    echo -e "${RED}✗ Failed to copy app to /Applications${NC}"
    echo "You may need to run with sudo: sudo ./copy_to_applications.sh"
    exit 1
fi
