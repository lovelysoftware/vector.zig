#!/bin/bash

# Downloads and unpacks a specific SIFT dataset.
# Invoked via build.zig before testing (i.e. to download the `siftsmall` dataset).

if ! command -v curl >/dev/null 2>&1; then
    echo "Error: curl is not installed. Please install curl and try again."
    exit 1
fi

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <dataset>"
    exit 1
fi

DATASET="$1"

if [ -d "sift_data/$DATASET" ]; then
    exit 0
fi

URL="ftp://ftp.irisa.fr/local/texmex/corpus/${DATASET}.tar.gz"

if [ ! -f "${DATASET}.tar.gz" ]; then
    echo "Downloading dataset from $URL..."
    if ! curl -O "$URL"; then
        echo "Error: Failed to download dataset from $URL"
        exit 1
    fi
fi

mkdir -p sift_data/"$DATASET"
if ! tar -xzf "${DATASET}.tar.gz" -C sift_data; then
    echo "Error: Failed to extract dataset"
    rm "${DATASET}.tar.gz"
    exit 1
fi

echo "Dataset '$DATASET' downloaded and extracted successfully."
rm "${DATASET}.tar.gz"
exit 0