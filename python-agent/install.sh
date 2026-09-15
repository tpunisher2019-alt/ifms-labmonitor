#!/bin/sh
set -eu
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec sh "$source_dir/install-linux.sh" "$@"
