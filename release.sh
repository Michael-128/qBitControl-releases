#!/bin/bash

# Exit immediately if any command fails
set -e

# Help instructions
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <path_to_ipa> <path_to_adp_zip>"
    echo "Example: $0 ~/Downloads/qBitControl.ipa ~/Downloads/adp.zip"
    exit 1
fi

IPA_PATH=$1
ADP_ZIP_PATH=$2

# Check if IPA exists
if [ ! -f "$IPA_PATH" ]; then
    echo "Error: IPA file does not exist at '$IPA_PATH'"
    exit 1
fi

# Check if ADP ZIP exists
if [ ! -f "$ADP_ZIP_PATH" ]; then
    echo "Error: ADP ZIP file does not exist at '$ADP_ZIP_PATH'"
    exit 1
fi

# Create backup files of the JSONs in case of rejection or script failure
BACKUP_JSON=$(mktemp /tmp/source.json.XXXXXX)
BACKUP_CLASSIC=$(mktemp /tmp/source-classic.json.XXXXXX)
cp source.json "$BACKUP_JSON"
cp source-classic.json "$BACKUP_CLASSIC"

# Track success state for automatic error cleanup
SUCCESS=false

cleanup() {
    # If the script failed or was aborted, restore original state
    if [ "$SUCCESS" = "false" ]; then
        echo -e "\n⚠️  Script did not finish successfully. Reverting changes..."
        if [ -f "$BACKUP_JSON" ]; then
            cp "$BACKUP_JSON" source.json 2>/dev/null || true
        fi
        if [ -f "$BACKUP_CLASSIC" ]; then
            cp "$BACKUP_CLASSIC" source-classic.json 2>/dev/null || true
        fi
        if [ ! -z "$VERSION" ]; then
            rm -rf "IPAS/$VERSION" "ADPS/$VERSION" "screenshots/$VERSION" 2>/dev/null || true
        fi
    fi
    # Delete temporary files
    rm -f "$BACKUP_JSON" "$BACKUP_CLASSIC"
}

# Ensure cleanup runs on exit (success, error, or manual interrupt)
trap cleanup EXIT

# Prompt for Version
read -p "Enter Version (e.g., 1.3.5): " VERSION
if [ -z "$VERSION" ]; then
    echo "Error: Version cannot be empty."
    exit 1
fi

# Prompt for Build Number
read -p "Enter Build Number (e.g., 19): " BUILD
if [ -z "$BUILD" ]; then
    echo "Error: Build number cannot be empty."
    exit 1
fi

# Open Neovim for description
TEMP_NOTES_FILE=$(mktemp /tmp/release_notes.XXXXXX)
nvim "$TEMP_NOTES_FILE"

# Read description
CLEANED_NOTES=$(cat "$TEMP_NOTES_FILE")
rm -f "$TEMP_NOTES_FILE"

if [ -z "$CLEANED_NOTES" ]; then
    echo "Error: Release description is empty. Aborting."
    exit 1
fi

DATE=$(date +"%Y-%m-%d")

# Create Release Directories
mkdir -p "IPAS/$VERSION"
mkdir -p "ADPS/$VERSION"
mkdir -p "screenshots/$VERSION"

# Copy IPA and Unzip ADP
cp "$IPA_PATH" "IPAS/$VERSION/qBitControl.ipa"
unzip -q -o "$ADP_ZIP_PATH" -d "ADPS/$VERSION"

# Handle Screenshots (Copy from previous release as fallback)
LAST_VERSION=$(jq -r '.apps[0].versions[0].version' source-classic.json)
if [ -d "screenshots/$LAST_VERSION" ]; then
    cp -R "screenshots/$LAST_VERSION/" "screenshots/$VERSION/"
fi

# Calculate sizes
IPA_SIZE=$(stat -f %z "$IPA_PATH")
ADP_SIZE=$(find "ADPS/$VERSION" -type f -exec stat -f %z {} + | awk '{s+=$1} END {print s}')

# Build JSON blocks natively via jq (altsource tool is no longer required!)
CLASSIC_VERSION_BLOCK=$(jq -n \
  --arg ver "$VERSION" \
  --arg date "$DATE" \
  --arg build "$BUILD" \
  --arg desc "$CLEANED_NOTES" \
  --arg url "https://michael-128.github.io/qBitControl-releases/IPAS/$VERSION/qBitControl.ipa" \
  --argjson size "$IPA_SIZE" \
  --arg minOS "16.0" \
  '{version: $ver, date: $date, buildVersion: $build, localizedDescription: $desc, downloadURL: $url, size: $size, minOSVersion: $minOS}')

PAL_VERSION_BLOCK=$(echo "$CLASSIC_VERSION_BLOCK" | jq \
  --arg url "https://michael-128.github.io/qBitControl-releases/ADPS/$VERSION" \
  --argjson size "$ADP_SIZE" \
  '.downloadURL = $url | .size = $size')

# Update source-classic.json: prepend version block and update screenshots path
jq --arg old "$LAST_VERSION" --arg new "$VERSION" --argjson block "$CLASSIC_VERSION_BLOCK" \
  '.apps[0].screenshots |= map(gsub($old; $new)) | .apps[0].versions = [$block] + .apps[0].versions' \
  source-classic.json > temp.json && mv temp.json source-classic.json

# Update source.json: prepend version block and update screenshots path
jq --arg old "$LAST_VERSION" --arg new "$VERSION" --argjson block "$PAL_VERSION_BLOCK" \
  '.apps[0].screenshots |= map(gsub($old; $new)) | .apps[0].versions = [$block] + .apps[0].versions' \
  source.json > temp.json && mv temp.json source.json

# Print Preview
echo -e "\n========================================================"
echo -e "         PREVIEW: NEW AltStore RELEASE BLOCKS           "
echo -e "========================================================"
echo -e "\n--- AltStore Classic Version Entry (source-classic.json) ---"
jq '.apps[0].versions[0]' source-classic.json
echo -e "\n--- AltStore PAL Version Entry (source.json) ---"
jq '.apps[0].versions[0]' source.json
echo -e "========================================================\n"

# Prompt for Confirmation
read -p "Do you want to apply these changes? (y/n): " CONFIRM

if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
    SUCCESS=true
    echo "✅ Release $VERSION ($BUILD) successfully staged!"
    echo "Review changes with 'git diff' and commit when ready."
else
    echo "❌ Release discarded. Reverting all changes..."
    exit 1
fi
