#!/usr/bin/env bash
set -euo pipefail

# ==== CONFIG ====
# Center of Houston (Downtown)
LAT="${LAT:-29.7604}"
# FIX: no leading space; the minus sign is fine without hacks
LNG="${LNG:--95.3698}"
RADIUS_M="${RADIUS_M:-10000}"   # 10 km

# API keys (set these in your shell or edit here)
GOOGLE_API_KEY="${GOOGLE_API_KEY:-AIzaSyCF4rETakUb6Hqa0daJ63BeYey3Mmmg9V0}"
OPENAQ_API_KEY="${OPENAQ_API_KEY:-6ef96d7f1809ad952a8ad5ec6064a19a22a406f1fde44d73593f339d6e649462}"

# Output file (or just prints to stdout)
OUT="${OUT:-houston_wildfire_smoke.json}"

echo ">> Using LAT=${LAT} LNG=${LNG} RADIUS_M=${RADIUS_M}" >&2

# ==== 1) NOAA HMS — Fire detections near point (GeoJSON/JSON) ====
echo ">> Querying NOAA HMS fires..." >&2
NOAA_URL="https://services2.arcgis.com/C8EMgrsFcRFL6LrL/arcgis/rest/services/NOAA_Satellite_Fire_Detections_(v1)/FeatureServer/0/query"
NOAA_JSON="$(curl -sG "$NOAA_URL" \
  --data-urlencode "where=1=1" \
  --data-urlencode "geometry=${LNG},${LAT}" \
  --data-urlencode "geometryType=esriGeometryPoint" \
  --data-urlencode "inSR=4326" \
  --data-urlencode "spatialRel=esriSpatialRelIntersects" \
  --data-urlencode "distance=${RADIUS_M}" \
  --data-urlencode "units=esriSRUnit_Meter" \
  --data-urlencode "outFields=*" \
  --data-urlencode "f=json")"

# If service returns an error, still keep going; we'll include raw JSON
# but avoid hard-failing here.
NOAA_FEATURES_COUNT="$(jq -r '.features?|length // 0' <<< "$NOAA_JSON")"
echo ">> NOAA features: ${NOAA_FEATURES_COUNT}" >&2

# ==== 2) Google Air Quality — current pollutants at point (500x500m) ====
echo ">> Querying Google Air Quality..." >&2
if [[ "$GOOGLE_API_KEY" == "YOUR_GOOGLE_API_KEY" ]]; then
  echo "!! WARNING: GOOGLE_API_KEY not set; skipping Google AQ." >&2
  GOOGLE_JSON='{"warning":"missing GOOGLE_API_KEY"}'
else
  GOOGLE_JSON="$(curl -s -X POST \
    -H "Content-Type: application/json" \
    "https://airquality.googleapis.com/v1/currentConditions:lookup?key=${GOOGLE_API_KEY}" \
    -d "$(jq -n --arg lat "$LAT" --arg lng "$LNG" '{
          location: {latitude: ($lat|tonumber), longitude: ($lng|tonumber)},
          extraComputations: ["POLLUTANT_CONCENTRATION","DOMINANT_POLLUTANT_CONCENTRATION"],
          universalAqi: true
        }')")"
fi

# Pull out a friendly pollutants map if available
GOOGLE_POLLUTANTS="$(jq -r '
  try .indexes[0].universalAqi as $aqi
  | {
      aqi: $aqi.aqi,
      category: $aqi.category,
      pollutants: ([
        .pollutants[]? | {code:.code, value: .concentration.value, units: .concentration.units}
      ] | (map({key:.code, value:{value,units}}) | from_entries))
    } catch {"note":"unavailable"}' <<< "$GOOGLE_JSON" 2>/dev/null || echo '{"note":"unavailable"}')"

# ==== 3) OpenAQ — nearby sensors (pm25, pm10, o3, no2) ====
echo ">> Querying OpenAQ..." >&2
if [[ "$OPENAQ_API_KEY" == "YOUR_OPENAQ_API_KEY" ]]; then
  echo "!! WARNING: OPENAQ_API_KEY not set; skipping OpenAQ." >&2
  OPENAQ_JSON='{"warning":"missing OPENAQ_API_KEY"}'
  OPENAQ_SUMMARY='{"note":"unavailable"}'
else
  OPENAQ_JSON="$(curl -s \
    -H "X-API-Key: ${OPENAQ_API_KEY}" \
    "https://api.openaq.org/v3/measurements?coordinates=${LAT},${LNG}&radius=${RADIUS_M}&parameters=pm25,pm10,o3,no2&limit=200")"

  # Group by parameter, keep a light payload (value, unit, coordinates, time)
  OPENAQ_SUMMARY="$(jq '
    {
      count: (.results?|length // 0),
      by_parameter:
        ( (.results // [])
          | group_by(.parameter)
          | map({ (.[0].parameter): (map({
                value, unit,
                coordinates, location, city, country,
                date: .date.utc
              })) })
          | add // {} )
    }' <<< "$OPENAQ_JSON")"
fi

# ==== Assemble final JSON ====
echo ">> Assembling final JSON..." >&2
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
FINAL="$(jq -n \
  --arg lat "$LAT" \
  --arg lng "$LNG" \
  --arg radius_m "$RADIUS_M" \
  --arg ts "$TIMESTAMP" \
  --argjson noaa "$NOAA_JSON" \
  --argjson google_raw "$GOOGLE_JSON" \
  --argjson google_poll "$GOOGLE_POLLUTANTS" \
  --argjson openaq_raw "$OPENAQ_JSON" \
  --argjson openaq_sum "$OPENAQ_SUMMARY" '
{
  location: {lat: ($lat|tonumber), lng: ($lng|tonumber), radius_m: ($radius_m|tonumber)},
  timestamp_utc: $ts,
  wildfire: {
    noaa_hms_fire_detections: {
      count: ($noaa.features?|length // 0),
      features: ($noaa.features // [])
    }
  },
  smoke_indicators: {
    google_airquality: {
      summary: $google_poll,
      raw: $google_raw
    },
    openaq: {
      summary: $openaq_sum,
      raw: $openaq_raw
    }
  }
}')"

# Write or print
if [[ -n "${OUT}" ]]; then
  printf '%s\n' "$FINAL" > "$OUT"
  echo ">> Done. Wrote ${OUT}" >&2
else
  printf '%s\n' "$FINAL"
fi
