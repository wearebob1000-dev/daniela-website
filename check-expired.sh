#!/bin/bash
# check-expired.sh - Detect expired/withdrawn listings in Bayonne, NJ 07002
# Uses diff-based approach: compares current active listings against previous snapshot
# Listings that disappear (and weren't sold) are likely expired/withdrawn/delisted.

MEMORY_DIR="/Users/bob/clawd/memory/daniela"
SNAPSHOT_FILE="$MEMORY_DIR/bayonne-listings-snapshot.json"
SNAPSHOT_PREV="$MEMORY_DIR/bayonne-listings-snapshot-prev.json"
KNOWN_FILE="$MEMORY_DIR/bayonne-expired-known.txt"
SOLD_CACHE="$MEMORY_DIR/bayonne-sold-cache.txt"

UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
REDFIN_GIS="https://www.redfin.com/stingray/api/gis?al=1&market=newjersey&region_id=970&region_type=6&uipt=1,2,3,4,5,6,7,8&v=8"
REDFIN_CSV="https://www.redfin.com/stingray/api/gis-csv?al=1&market=newjersey&region_id=970&region_type=6&sold_within_days=90&uipt=1,2,3,4,5,6,7,8&v=8"

# Ensure files exist
mkdir -p "$MEMORY_DIR"
touch "$KNOWN_FILE"

# Step 1: Fetch current active listings
echo "Fetching current active listings for Bayonne..."
RESPONSE=$(curl -s "$REDFIN_GIS" -H "User-Agent: $UA")
CLEAN=$(echo "$RESPONSE" | sed 's/^{}&&//')

# Parse into a simple address|price|url|listingId format
CURRENT=$(echo "$CLEAN" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    homes = d.get('payload', {}).get('homes', [])
    listings = {}
    for h in homes:
        addr = h.get('streetLine', {}).get('value', '')
        price = h.get('price', {}).get('value', 0)
        url = h.get('url', '')
        lid = h.get('listingId', '')
        city = h.get('city', '')
        zipcode = h.get('zip', '')
        dom_val = h.get('timeOnRedfin', {}).get('value', 0)
        dom_days = dom_val // 86400000 if dom_val else 0
        beds = h.get('beds', '')
        baths = h.get('baths', '')
        ptype = h.get('uiPropertyType', '')
        if addr:
            print(f'{addr}|{price}|{url}|{lid}|{dom_days}|{beds}|{baths}|{ptype}')
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)
")

if [ -z "$CURRENT" ]; then
    echo "ERROR: Failed to fetch current listings"
    exit 1
fi

CURRENT_COUNT=$(echo "$CURRENT" | wc -l | tr -d ' ')
echo "Found $CURRENT_COUNT active listings"

# Step 2: Fetch recent sold listings to exclude from "expired" detection
echo "Fetching recently sold listings..."
SOLD_ADDRESSES=$(curl -s "$REDFIN_CSV" -H "User-Agent: $UA" | python3 -c "
import sys, csv
reader = csv.DictReader(sys.stdin)
for row in reader:
    addr = row.get('ADDRESS', '').strip()
    if addr:
        print(addr)
" 2>/dev/null)
echo "$SOLD_ADDRESSES" > "$SOLD_CACHE"

# Step 3: Compare against previous snapshot
if [ ! -f "$SNAPSHOT_FILE" ]; then
    echo "No previous snapshot found. Saving current snapshot as baseline."
    echo "$CURRENT" > "$SNAPSHOT_FILE"
    echo "Baseline saved with $CURRENT_COUNT listings. Run again later to detect changes."
    exit 0
fi

# Move current snapshot to prev, save new one
cp "$SNAPSHOT_FILE" "$SNAPSHOT_PREV"
echo "$CURRENT" > "$SNAPSHOT_FILE"

# Step 4: Find listings that disappeared (in prev but not in current)
echo ""
echo "=== Comparing snapshots ==="

DISAPPEARED=$(python3 -c "
import sys

# Load previous listings
prev = {}
with open('$SNAPSHOT_PREV') as f:
    for line in f:
        parts = line.strip().split('|')
        if len(parts) >= 4:
            addr = parts[0]
            prev[addr] = parts

# Load current listings
current_addrs = set()
with open('$SNAPSHOT_FILE') as f:
    for line in f:
        parts = line.strip().split('|')
        if parts:
            current_addrs.add(parts[0])

# Load sold addresses
sold_addrs = set()
try:
    with open('$SOLD_CACHE') as f:
        for line in f:
            sold_addrs.add(line.strip().upper())
except:
    pass

# Load known expired
known = set()
try:
    with open('$KNOWN_FILE') as f:
        for line in f:
            known.add(line.strip())
except:
    pass

# Find disappeared (not sold, not already known)
new_expired = []
for addr, parts in prev.items():
    if addr not in current_addrs:
        if addr.upper() not in sold_addrs:
            if addr not in known:
                price = parts[1] if len(parts) > 1 else '?'
                url = parts[2] if len(parts) > 2 else ''
                dom = parts[4] if len(parts) > 4 else '?'
                beds = parts[5] if len(parts) > 5 else '?'
                baths = parts[6] if len(parts) > 6 else '?'
                new_expired.append((addr, price, url, dom, beds, baths))

if new_expired:
    print(f'🏠 {len(new_expired)} NEW potentially expired/withdrawn listings:')
    print()
    for addr, price, url, dom, beds, baths in sorted(new_expired):
        price_fmt = f'\${int(float(price)):,}' if price and price != '0' else 'N/A'
        print(f'  📍 {addr}')
        print(f'     Price: {price_fmt} | Beds: {beds} | Baths: {baths} | Days on market: {dom}')
        if url:
            print(f'     https://www.redfin.com{url}')
        print()
else:
    print('No new expired/withdrawn listings detected.')

# Also report newly appeared listings
new_listings = []
for line in open('$SNAPSHOT_FILE'):
    parts = line.strip().split('|')
    if parts and parts[0] not in prev:
        new_listings.append(parts)

if new_listings:
    print(f'📋 {len(new_listings)} NEW listings appeared:')
    for parts in new_listings:
        addr = parts[0]
        price = parts[1] if len(parts) > 1 else '?'
        price_fmt = f'\${int(float(price)):,}' if price and price != '0' else 'N/A'
        print(f'  ➕ {addr} - {price_fmt}')
")

echo "$DISAPPEARED"

# If there are new expired listings, append to known file
echo "$DISAPPEARED" | grep "📍" | sed 's/.*📍 //' | while read -r addr; do
    echo "$addr" >> "$KNOWN_FILE"
done

echo ""
echo "Done. $(date)"
