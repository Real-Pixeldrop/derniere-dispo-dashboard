#!/bin/bash
# Script de mise à jour automatique du dashboard DernièreDispo
# Exécuté via cron Clawdbot

set -e
cd "$(dirname "$0")"

HTML_FILE="index.html"

# 1. Nombre de lieux (WordPress API)
LIEUX_COUNT=$(curl -sI "https://dernieredispo.com/wp-json/wp/v2/lieux?per_page=1" | grep -i "x-wp-total:" | sed 's/[^0-9]//g')
echo "Lieux: $LIEUX_COUNT"

# 2. Dernier lieu ajouté (WordPress API)
LAST_LIEU=$(curl -s "https://dernieredispo.com/wp-json/wp/v2/lieux?per_page=1&orderby=date&order=desc" | jq -r '.[0].title.rendered')
LAST_LIEU_DATE=$(curl -s "https://dernieredispo.com/wp-json/wp/v2/lieux?per_page=1&orderby=date&order=desc" | jq -r '.[0].date' | cut -d'T' -f1)
# Convertir date en format français
LAST_LIEU_DATE_FR=$(LC_TIME=fr_FR.UTF-8 date -j -f "%Y-%m-%d" "$LAST_LIEU_DATE" "+%-d %B %Y" 2>/dev/null || echo "$LAST_LIEU_DATE")
echo "Dernier lieu: $LAST_LIEU ($LAST_LIEU_DATE_FR)"

# 3. Lieu le plus vu (GA4)
ACCESS_TOKEN=$(curl -s -X POST https://oauth2.googleapis.com/token \
  -d "refresh_token=$(jq -r .refresh_token ~/.config/ga4/config.json)" \
  -d "client_id=$(jq -r .client_id ~/.config/ga4/config.json)" \
  -d "client_secret=$(jq -r .client_secret ~/.config/ga4/config.json)" \
  -d "grant_type=refresh_token" | jq -r '.access_token')

TOP_LIEU_RAW=$(curl -s -X POST "https://analyticsdata.googleapis.com/v1beta/properties/496482435:runReport" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "dateRanges":[{"startDate":"2025-01-01","endDate":"today"}],
    "dimensions":[{"name":"pagePath"}],
    "metrics":[{"name":"screenPageViews"}],
    "limit":100
  }' | jq -r '[.rows[] | select(.dimensionValues[0].value | test("/lieux/"))] | sort_by(-(.metricValues[0].value | tonumber)) | .[0]')

TOP_LIEU_PATH=$(echo "$TOP_LIEU_RAW" | jq -r '.dimensionValues[0].value')
TOP_LIEU_VIEWS=$(echo "$TOP_LIEU_RAW" | jq -r '.metricValues[0].value')
# Extraire le nom du lieu depuis l'URL
TOP_LIEU_NAME=$(echo "$TOP_LIEU_PATH" | sed 's|/lieux/||;s|/$||' | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1')
echo "Top lieu: $TOP_LIEU_NAME ($TOP_LIEU_VIEWS vues)"

# 4. Calcul du rythme nécessaire
OBJECTIF=1000
MOIS_RESTANTS=$(python3 -c "
from datetime import date
today = date.today()
end = date(2026, 12, 31)
months = (end.year - today.year) * 12 + end.month - today.month
print(max(months, 1))
")
RYTHME=$(python3 -c "print(round(($OBJECTIF - $LIEUX_COUNT) / $MOIS_RESTANTS))")
echo "Rythme: +$RYTHME/mois"

# 5. Pourcentage progression
PERCENTAGE=$(python3 -c "print(round($LIEUX_COUNT * 100 / $OBJECTIF, 1))")
echo "Progression: $PERCENTAGE%"

# --- Mise à jour du HTML ---

# Lieux count (dans l'animation JS)
sed -i '' "s/animateValue('lieux-count', 0, [0-9]*, 1500)/animateValue('lieux-count', 0, $LIEUX_COUNT, 1500)/" "$HTML_FILE"

# Actuel
sed -i '' "s/Actuel : [0-9]*/Actuel : $LIEUX_COUNT/" "$HTML_FILE"

# Progress bar
sed -i '' "s/style.width = '[0-9.]*%'/style.width = '${PERCENTAGE}%'/" "$HTML_FILE"
sed -i '' "s/>[0-9.]*%</>$PERCENTAGE%</" "$HTML_FILE"

# Rythme
sed -i '' "s/<div class=\"stat-value primary\">+[0-9]*</<div class=\"stat-value primary\">+$RYTHME</" "$HTML_FILE"

# Dernier ajout
sed -i '' "s|id=\"last-lieu\">[^<]*<|id=\"last-lieu\">$LAST_LIEU<|" "$HTML_FILE"
sed -i '' "s|id=\"last-lieu-date\">[^<]*<|id=\"last-lieu-date\">$LAST_LIEU_DATE_FR<|" "$HTML_FILE"

# Lieu le plus vu
sed -i '' "s|Lieu le plus vu</div>[[:space:]]*<div class=\"stat-value primary\" style=\"font-size: 1.5rem;\">[^<]*</div>[[:space:]]*<div style=\"color: var(--text-light); font-size: 0.9rem;\">[^<]*</div>|Lieu le plus vu</div>\n                <div class=\"stat-value primary\" style=\"font-size: 1.5rem;\">$TOP_LIEU_NAME</div>\n                <div style=\"color: var(--text-light); font-size: 0.9rem;\">$TOP_LIEU_VIEWS vues</div>|" "$HTML_FILE"

# --- Git commit et push ---
git add -A
if ! git diff --quiet --staged; then
  git commit -m "Auto-update: $LIEUX_COUNT lieux | Top: $TOP_LIEU_NAME ($TOP_LIEU_VIEWS vues)"
  git push
  echo "Dashboard mis a jour et pousse"
else
  echo "Pas de changement"
fi
