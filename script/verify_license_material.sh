#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MATERIAL_DIR="${1:?usage: $0 APP_RESOURCES_DIRECTORY}"
for name in LICENSE LICENSING.md LICENSE-MIT; do
  [[ -f "$MATERIAL_DIR/$name" ]] || { echo "Missing license material: $name" >&2; exit 1; }
  cmp -s "$ROOT_DIR/$name" "$MATERIAL_DIR/$name" || { echo "License material differs: $name" >&2; exit 1; }
done
grep -Fq 'GNU GENERAL PUBLIC LICENSE' "$MATERIAL_DIR/LICENSE"
grep -Fq 'Version 3, 29 June 2007' "$MATERIAL_DIR/LICENSE"
grep -Fxq 'SPDX-License-Identifier: GPL-3.0-or-later' "$MATERIAL_DIR/LICENSING.md"
grep -Fxq 'MIT License' "$MATERIAL_DIR/LICENSE-MIT"
