#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
if [ ! -f .env ]; then
  echo "ERROR: .env is missing. Copy .env.example to .env first." >&2
  exit 1
fi
set -a
# shellcheck disable=SC1091
. "$PROJECT_DIR/.env"
set +a

if [ "$#" -lt 1 ]; then
  echo "Usage: $0 <path-to-.mcpack/.mcaddon/.zip-or-folder> [...more packs]" >&2
  exit 1
fi

LEVEL_NAME="${LEVEL_NAME:-Voice World}"
WORLD_DIR="data/worlds/$LEVEL_NAME"
if [ ! -d "$WORLD_DIR" ]; then
  echo "ERROR: Active world folder does not exist: $WORLD_DIR" >&2
  exit 1
fi

STAGE_ROOT="${TMPDIR:-/tmp}/mc-pack-stage.$$"
mkdir -p "$STAGE_ROOT"
cleanup() { rm -rf "$STAGE_ROOT"; }
trap cleanup EXIT INT TERM

upsert_world_json() {
  local json_path="$1" uuid="$2" version="$3"
  /usr/bin/perl -MJSON::PP -e '
    my ($path, $uuid, $version) = @ARGV;
    my $list = [];
    if (-f $path && open(my $fh, "<:raw", $path)) {
      local $/; my $raw = <$fh>; close($fh);
      $list = eval { decode_json($raw) } || [];
      $list = [] unless ref($list) eq "ARRAY";
    }
    my @v = map { int($_) } split(/\./, $version);
    push @v, 0 while @v < 3;
    my $found = 0;
    for my $entry (@$list) {
      if (lc($entry->{pack_id} // "") eq lc($uuid)) {
        $entry->{version} = \@v; $found = 1;
      }
    }
    push @$list, { pack_id => lc($uuid), version => \@v } unless $found;
    open(my $out, ">:raw", $path) or die "Cannot write $path: $!\n";
    print $out JSON::PP->new->utf8->pretty->canonical->encode($list);
    close($out);
  ' "$json_path" "$uuid" "$version"
}

parse_manifest() {
  local manifest="$1"
  /usr/bin/perl -MJSON::PP -e '
    my $path = shift;
    open(my $fh, "<:raw", $path) or exit 0;
    local $/; my $raw = <$fh>; close($fh);
    $raw =~ s/^\xEF\xBB\xBF//;
    $raw =~ s{("(?:\\.|[^"\\])*")|/\*.*?\*/|//[^\r\n]*}{$1 // ""}gse;
    $raw =~ s/,(\s*[}\]])/$1/gs;
    my $m = eval { decode_json($raw) }; exit 0 unless $m && ref($m) eq "HASH" && $m->{header};
    my $h = $m->{header}; my $uuid = lc($h->{uuid} // ""); exit 0 unless $uuid;
    my $name = $h->{name} // "pack"; my $v = $h->{version} // [1,0,0];
    my @ver = ref($v) eq "ARRAY" ? map { int($_) } @$v[0..2] : (1,0,0);
    my ($rp, $bp) = (0, 0);
    for my $mod (@{$m->{modules} || []}) {
      my $type = lc($mod->{type} // "");
      $rp = 1 if $type eq "resources" || $type eq "worldtemplate";
      $bp = 1 if $type eq "data" || $type eq "script";
    }
    (my $slug = lc($name)) =~ s/[^a-z0-9]+/-/g; $slug =~ s/^-+|-+$//g; $slug = "pack" unless $slug;
    $slug = substr($slug, 0, 28);
    print join("\t", $name, $uuid, join(".", @ver), $rp, $bp, "${slug}-" . substr($uuid,0,8)), "\n";
  ' "$manifest"
}

TOTAL=0
INDEX=0
for INPUT_PATH in "$@"; do
  if [ ! -e "$INPUT_PATH" ]; then
    echo "ERROR: File or folder not found: $INPUT_PATH" >&2
    exit 1
  fi
  INDEX=$((INDEX + 1))
  STAGE_DIR="$STAGE_ROOT/item-$INDEX"
  mkdir -p "$STAGE_DIR"
  echo "==> Unpacking $(basename "$INPUT_PATH")..."
  if [ -d "$INPUT_PATH" ]; then
    cp -R "$INPUT_PATH"/. "$STAGE_DIR/"
  else
    unzip -q -o "$INPUT_PATH" -d "$STAGE_DIR"
  fi

  # .mcaddon files commonly contain nested .mcpack files.
  NESTED_INDEX=0
  while :; do
    FOUND_ARCHIVE=0
    while IFS= read -r -d '' ARCHIVE; do
      FOUND_ARCHIVE=1
      NESTED_INDEX=$((NESTED_INDEX + 1))
      NESTED_DIR="$STAGE_DIR/.nested-$NESTED_INDEX"
      mkdir -p "$NESTED_DIR"
      unzip -q -o "$ARCHIVE" -d "$NESTED_DIR"
      rm -f "$ARCHIVE"
    done < <(find "$STAGE_DIR" -maxdepth 5 -type f \( -iname '*.mcpack' -o -iname '*.mcaddon' -o -iname '*.zip' \) -print0)
    [ "$FOUND_ARCHIVE" -eq 1 ] || break
  done

  FOUND=0
  while IFS= read -r -d '' MANIFEST; do
    case "$MANIFEST" in */subpacks/*) continue ;; esac
    RESULT="$(parse_manifest "$MANIFEST")"
    [ -n "$RESULT" ] || continue
    FOUND=1
    IFS=$'\t' read -r PACK_NAME PACK_UUID PACK_VERSION IS_RP IS_BP PACK_FOLDER <<< "$RESULT"
    PACK_SRC_DIR="$(dirname "$MANIFEST")"
    if [ "$IS_RP" = "1" ]; then
      DEST="data/resource_packs/$PACK_FOLDER"
      rm -rf "$DEST"; mkdir -p "$DEST"
      cp -R "$PACK_SRC_DIR"/. "$DEST/"
      upsert_world_json "$WORLD_DIR/world_resource_packs.json" "$PACK_UUID" "$PACK_VERSION"
      echo "    [Resource/Texture] $PACK_NAME v$PACK_VERSION -> $DEST"
      TOTAL=$((TOTAL + 1))
    fi
    if [ "$IS_BP" = "1" ]; then
      DEST="data/behavior_packs/$PACK_FOLDER"
      rm -rf "$DEST"; mkdir -p "$DEST"
      cp -R "$PACK_SRC_DIR"/. "$DEST/"
      upsert_world_json "$WORLD_DIR/world_behavior_packs.json" "$PACK_UUID" "$PACK_VERSION"
      echo "    [Behavior/Addon]   $PACK_NAME v$PACK_VERSION -> $DEST"
      TOTAL=$((TOTAL + 1))
    fi
  done < <(find "$STAGE_DIR" -maxdepth 5 -type f -iname manifest.json -print0)

  if [ "$FOUND" -eq 0 ]; then
    echo "WARNING: No valid Bedrock manifest.json found inside '$INPUT_PATH'." >&2
  fi
done

if [ "$TOTAL" -gt 0 ]; then
  echo "==> Restarting bedrock-server to load $TOTAL installed pack(s)..."
  docker compose restart bedrock-server
  echo "Done."
else
  echo "No packs were installed." >&2
  exit 1
fi

