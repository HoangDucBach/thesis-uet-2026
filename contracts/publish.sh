#!/bin/bash

PACKAGE_PATH=${1:-.}

sui client publish "$PACKAGE_PATH" \
    --gas-budget 1000000000 \
    --doc \
    --json