#!/bin/sh -e

# Configuration
REPO_URL="https://github.com/esnet/iperf.git"
TAG="3.20"
CHECKOUT_PATH="iperf3"
SRC_PATH="Sources/IperfCLib"
SYNC_DATA="iperf_sync"

cd "$(dirname "$0")"

echo "----------------------------------------"
echo "iPerf Source Synchronization Script"
echo "Target Version: $TAG"
echo "----------------------------------------"

echo "Checking out $REPO_URL (tag $TAG)"
rm -rf "$CHECKOUT_PATH" && mkdir "$CHECKOUT_PATH"
git clone --quiet --depth 1 --single-branch "$REPO_URL" --branch "$TAG" "$CHECKOUT_PATH"

echo "Configuring the source files"
(cd "$CHECKOUT_PATH" && ./configure > /dev/null)

echo "Cleaning and updating $SRC_PATH"
rm -rf "$SRC_PATH"
mkdir -p "$SRC_PATH/include"

echo "Copying upstream source files"
cp "$CHECKOUT_PATH/src/"*.h "$SRC_PATH/include"
cp "$CHECKOUT_PATH/src/"*.c "$SRC_PATH/"
rm "$SRC_PATH/main.c" "$SRC_PATH/t_"*.c
rm -rf "$CHECKOUT_PATH"

echo "Applying customizations..."

# 1. Apply modifications patch (Steps 2, 3, 4, 6, 7 from README)
if [ -f "$SYNC_DATA/patches/modifications.patch" ]; then
    echo "  Applying modifications.patch..."
    patch -p1 -d "$SRC_PATH" < "$SYNC_DATA/patches/modifications.patch"
else
    echo "  WARNING: modifications.patch not found!"
fi

# 2. Copy custom files (File.h, stdatomic, etc.)
if [ -d "$SYNC_DATA/custom_files" ]; then
    echo "  Installing custom files..."
    cp "$SYNC_DATA/custom_files/"*.c "$SRC_PATH/"
    cp "$SYNC_DATA/custom_files/"*.h "$SRC_PATH/include/"
else
    echo "  WARNING: custom_files directory not found!"
fi

# 3. Global replacements (Step 5 from README)
echo "  Recovering iperf_stdatomic.h usage in all files..."
# Search in both .c and .h files and replace <stdatomic.h> with <iperf_stdatomic.h>
# We use grep -l to only process files that contain the include
grep -l "#include <stdatomic.h>" "$SRC_PATH"/*.[ch] "$SRC_PATH"/include/*.h 2>/dev/null | xargs sed -i '' 's/<stdatomic.h>/<iperf_stdatomic.h>/g' || true

echo "----------------------------------------"
echo "SUCCESS: $SRC_PATH updated and patched!"
echo "----------------------------------------"
