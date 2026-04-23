#!/usr/bin/env bash
set -euo pipefail

# Generates fresh seed dictionaries used by the staged SimRunner seed configs.
# Output files:
#   model/accounts-ids.txt
#   model/tx-account-ids.txt
#   model/collections-account-ids.txt

mkdir -p model

seq 1 5000 | sed 's/^/ACC/' > model/accounts-ids.txt

: > model/tx-account-ids.txt
for i in $(seq 1 5000); do
	count=$((RANDOM % 491 + 10))
	for _ in $(seq 1 "$count"); do
		echo "ACC${i}"
	done
done >> model/tx-account-ids.txt

seq 1 5000 | awk '
BEGIN { srand() }
{ a[NR] = $0 }
END {
	for (i = NR; i >= 1; i--) {
		j = int(rand() * i) + 1
		t = a[i]
		a[i] = a[j]
		a[j] = t
	}
	for (i = 1; i <= 1000; i++) {
		print "ACC" a[i]
	}
}
' > model/collections-account-ids.txt

echo "Generated:"
wc -l model/accounts-ids.txt model/tx-account-ids.txt model/collections-account-ids.txt
