#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

if [ ! -f .env ]; then
  echo "ERROR: .env is missing. Copy .env.example to .env and set TS_DOMAIN first." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
. "$PROJECT_DIR/.env"
set +a

GAMERTAG="${1:-}"
WORLD_INPUT="${2:-}"

if [ -z "$GAMERTAG" ]; then
  echo "Usage: $0 \"YourXboxGamertag\" /path/to/world.mcworld" >&2
  echo "   or: $0 \"YourXboxGamertag\" /path/to/copied-bedrock-world-folder" >&2
  exit 1
fi

TAILSCALE_CONTAINER="${TAILSCALE_CONTAINER:-bedrock-tailscale}"
BVC_CONTAINER="${BVC_CONTAINER:-bedrock-voice}"
BDS_CONTAINER="${BDS_CONTAINER:-bedrock-server}"
LEVEL_NAME="${LEVEL_NAME:-Voice World}"
TS_HOSTNAME="${TS_HOSTNAME:-minecraft-bedrock}"
BVC_ADDON_URL="${BVC_ADDON_URL:-https://github.com/Alaydriem/bedrock-voice-chat/releases/download/mods-v1.0.0-beta.24/bvc-bds-pack-1.0.0-beta.24.mcaddon}"

TEMP_ROOT="${TMPDIR:-/tmp}/bedrock-voice-setup.$$"
ADDON_DIR="$TEMP_ROOT/addon"
WORLD_UNPACK_DIR="$TEMP_ROOT/world"
mkdir -p "$ADDON_DIR" "$WORLD_UNPACK_DIR"
cleanup() { rm -rf "$TEMP_ROOT"; }
trap cleanup EXIT INT TERM

find_world_dir() {
  local root="$1"
  if [ -f "$root/level.dat" ]; then
    printf '%s\n' "$root"
    return 0
  fi
  find "$root" -type f -name level.dat -print 2>/dev/null | sed -n '1p' | sed 's#/level\.dat$##'
}

WORLD_SRC=""
if [ -n "$WORLD_INPUT" ]; then
  if [ -f "$WORLD_INPUT" ]; then
    case "$WORLD_INPUT" in
      *.mcworld|*.MCWORLD|*.zip|*.ZIP)
        unzip -q -o "$WORLD_INPUT" -d "$WORLD_UNPACK_DIR"
        WORLD_SRC="$(find_world_dir "$WORLD_UNPACK_DIR")"
        ;;
      *)
        echo "ERROR: A world file must be .mcworld (a Bedrock world folder is also accepted)." >&2
        exit 1
        ;;
    esac
  elif [ -d "$WORLD_INPUT" ]; then
    WORLD_SRC="$(find_world_dir "$WORLD_INPUT")"
  else
    echo "ERROR: World input not found: $WORLD_INPUT" >&2
    exit 1
  fi
else
  WORLD_SRC="$(find_world_dir "$PROJECT_DIR/incoming" 2>/dev/null || true)"
fi

if [ -z "$WORLD_SRC" ] || [ ! -f "$WORLD_SRC/level.dat" ]; then
  echo "ERROR: Could not find a Bedrock world folder containing level.dat." >&2
  echo "Pass a .mcworld file or a copied Bedrock world folder as the second argument." >&2
  exit 1
fi

if [ ! -d "$WORLD_SRC/db" ]; then
  echo "ERROR: '$WORLD_SRC' has no db/ folder; it does not look like a Bedrock world." >&2
  echo "Create/export the world from Bedrock with Experiments -> Beta APIs enabled." >&2
  exit 1
fi

WORLD_TITLE="$(cat "$WORLD_SRC/levelname.txt" 2>/dev/null || basename "$WORLD_SRC")"
echo "==> Found Bedrock world: $WORLD_TITLE"

echo "==> Detecting the Tailscale HTTPS domain..."
DETECTED_DOMAIN="$(docker exec "$TAILSCALE_CONTAINER" tailscale status --json | /usr/bin/perl -MJSON::PP -0777 -e '
  local $/; my $raw = <STDIN>; my $j = eval { decode_json($raw) };
  my $dns = $j->{Self}{DNSName} // $j->{DNSName} // "";
  $dns =~ s/\.$//; print $dns;
')"
if [ -z "$DETECTED_DOMAIN" ]; then
  echo "ERROR: Could not detect a Tailscale DNS name. Enable MagicDNS and HTTPS in the Tailscale Admin DNS page." >&2
  exit 1
fi

if [ "${TS_DOMAIN:-}" != "$DETECTED_DOMAIN" ]; then
  echo "    Updating TS_DOMAIN in .env to $DETECTED_DOMAIN"
  BEDROCK_DETECTED_DOMAIN="$DETECTED_DOMAIN" /usr/bin/perl -0pi \
    -e 's/^TS_DOMAIN=.*$/TS_DOMAIN=$ENV{BEDROCK_DETECTED_DOMAIN}/m' .env
  TS_DOMAIN="$DETECTED_DOMAIN"
fi
case "$TS_DOMAIN" in
  *[!A-Za-z0-9._-]*) echo "ERROR: TS_DOMAIN contains unsupported hostname characters." >&2; exit 1 ;;
esac

echo "==> Provisioning the 90-day Let's Encrypt certificate..."
mkdir -p bvc-data/tls
docker exec "$TAILSCALE_CONTAINER" mkdir -p /tmp/certs
docker exec "$TAILSCALE_CONTAINER" tailscale cert \
  --cert-file=/tmp/certs/cert.pem \
  --key-file=/tmp/certs/key.pem \
  "$TS_DOMAIN"
docker cp "$TAILSCALE_CONTAINER:/tmp/certs/cert.pem" bvc-data/tls/cert.pem
docker cp "$TAILSCALE_CONTAINER:/tmp/certs/key.pem" bvc-data/tls/key.pem
chmod 644 bvc-data/tls/cert.pem
chmod 600 bvc-data/tls/key.pem

echo "==> Downloading and unpacking Bedrock Voice Chat..."
curl -fsSL -o "$ADDON_DIR/bvc.mcaddon" "$BVC_ADDON_URL"
unzip -q -o "$ADDON_DIR/bvc.mcaddon" -d "$ADDON_DIR/unpacked"
BP_ARCHIVE="$(find "$ADDON_DIR/unpacked" -type f -iname '*bp*.mcpack' -print 2>/dev/null | sed -n '1p')"
RP_ARCHIVE="$(find "$ADDON_DIR/unpacked" -type f -iname '*rp*.mcpack' -print 2>/dev/null | sed -n '1p')"
if [ -z "$BP_ARCHIVE" ] || [ -z "$RP_ARCHIVE" ]; then
  echo "ERROR: The downloaded .mcaddon did not contain both nested BP and RP .mcpack files." >&2
  exit 1
fi
rm -rf data/behavior_packs/bvc-bp data/resource_packs/bvc-rp
mkdir -p data/behavior_packs/bvc-bp data/resource_packs/bvc-rp
unzip -q -o "$BP_ARCHIVE" -d data/behavior_packs/bvc-bp
unzip -q -o "$RP_ARCHIVE" -d data/resource_packs/bvc-rp
find data/behavior_packs/bvc-bp -type f -name manifest.json -exec \
  /usr/bin/perl -pi -e 's/"2\.11\.0-beta"/"2.12.0-beta"/g; s/"2\.3\.0-beta"/"2.4.0-beta"/g' {} +

echo "==> Installing the world into data/worlds/$LEVEL_NAME..."
docker compose stop "$BDS_CONTAINER" >/dev/null 2>&1 || true
rm -rf "data/worlds/$LEVEL_NAME"
mkdir -p "data/worlds/$LEVEL_NAME"
cp -R "$WORLD_SRC"/. "data/worlds/$LEVEL_NAME/"

write_pack_reference() {
  local manifest="$1"
  local output="$2"
  /usr/bin/perl -MJSON::PP -e '
    my ($manifest_path, $output_path) = @ARGV;
    open(my $fh, "<:raw", $manifest_path) or die "Cannot read manifest: $!\n";
    local $/; my $raw = <$fh>; close($fh);
    $raw =~ s/^\xEF\xBB\xBF//;
    $raw =~ s{("(?:\\.|[^"\\])*")|/\*.*?\*/|//[^\r\n]*}{$1 // ""}gse;
    $raw =~ s/,(\s*[}\]])/$1/gs;
    my $m = decode_json($raw); my $h = $m->{header};
    my $version = $h->{version};
    my @v = ref($version) eq "ARRAY" ? map { int($_) } @$version[0..2] : (1, 0, 0);
    open(my $out, ">:raw", $output_path) or die "Cannot write pack reference: $!\n";
    print $out JSON::PP->new->utf8->pretty->canonical->encode([
      { pack_id => lc($h->{uuid}), version => \@v }
    ]);
    close($out);
  ' "$manifest" "$output"
}
write_pack_reference "$(find data/behavior_packs/bvc-bp -type f -name manifest.json -print | sed -n '1p')" "data/worlds/$LEVEL_NAME/world_behavior_packs.json"
write_pack_reference "$(find data/resource_packs/bvc-rp -type f -name manifest.json -print | sed -n '1p')" "data/worlds/$LEVEL_NAME/world_resource_packs.json"

mkdir -p data/config/default
cat > data/config/default/permissions.json <<'JSON'
{
  "allowed_modules": [
    "@minecraft/server",
    "@minecraft/server-admin",
    "@minecraft/server-net",
    "@minecraft/server-ui"
  ]
}
JSON

cat > bvc-data/config.hcl <<EOF
server {
  port      = 443
  quic_port = 28280

  tls {
    names       = ["${TS_DOMAIN}"]
    certificate = "/data/tls/cert.pem"
    key         = "/data/tls/key.pem"
  }
}
EOF

echo "==> Starting Bedrock Voice Chat and minting the world access token..."
docker compose --profile voice up -d tailscale "$BVC_CONTAINER"
sleep 4
BVC_TOKEN="$(docker exec "$BVC_CONTAINER" bvc-server admin token mint --local -c /data/config.hcl | tr -d '\r\n')"
mkdir -p data/config/default
BVC_TOKEN="$BVC_TOKEN" BVC_DOMAIN="$TS_DOMAIN" BVC_LEVEL="$LEVEL_NAME" \
  /usr/bin/perl -MJSON::PP -e '
    my $output = "data/config/default/variables.json";
    my $doc = {
      bvc_access_token => $ENV{BVC_TOKEN} // "",
      bvc_server => "https://" . ($ENV{BVC_DOMAIN} // ""),
      bvc_minimum_players => 1,
      bvc_world_name => $ENV{BVC_LEVEL} // "Voice World"
    };
    open(my $fh, ">:raw", $output) or die "Cannot write $output: $!\n";
    print $fh JSON::PP->new->utf8->pretty->canonical->encode($doc);
    close($fh);
  '

echo "==> Registering $GAMERTAG and starting Minecraft..."
docker exec "$BVC_CONTAINER" bvc-server admin bootstrap -p "$GAMERTAG" -g minecraft -c /data/config.hcl || true
LOGIN_CODE="$(docker exec "$BVC_CONTAINER" bvc-server admin generate-code -p "$GAMERTAG" -g minecraft -d 86400 -c /data/config.hcl || true)"
docker compose --profile voice up -d "$BDS_CONTAINER"

echo
echo "Bedrock Voice Chat is configured."
echo "Voice server URL: https://${TS_DOMAIN}"
echo "Your one-time login code: ${LOGIN_CODE}"
echo "Connect to Minecraft using the Tailscale hostname on port 19132; do not use LAN discovery."

