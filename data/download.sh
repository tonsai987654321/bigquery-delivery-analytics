#!/usr/bin/env bash
#
# Fetch the raw Olist CSVs. The CSVs themselves are not committed — see .gitignore.
#
# Needs the Kaggle CLI:
#   pipx install kaggle        # or: pip install kaggle
#
# This dataset is public, so no API token was required at the time of writing.
# If Kaggle asks for credentials, put an API token at ~/.kaggle/kaggle.json
# (Kaggle account -> Settings -> Create New Token).
#
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

kaggle datasets download -d olistbr/brazilian-ecommerce -p "${DIR}"
unzip -o -q "${DIR}/brazilian-ecommerce.zip" -d "${DIR}"

echo "downloaded:"
ls -1 "${DIR}"/olist_*.csv
