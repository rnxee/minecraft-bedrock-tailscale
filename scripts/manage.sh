#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . "$PROJECT_DIR/.env"
  set +a
fi

BDS_CONTAINER="${BDS_CONTAINER:-bedrock-server}"
BVC_CONTAINER="${BVC_CONTAINER:-bedrock-voice}"
TAILSCALE_CONTAINER="${TAILSCALE_CONTAINER:-bedrock-tailscale}"
LEVEL_NAME="${LEVEL_NAME:-Voice World}"

usage() {
  echo "Usage: $0 {start|stop|restart|logs|cmd|op|awake|backup|renew-cert} [args...]"
  echo
  echo "  start                 Start the configured stack (voice profile comes from .env)"
  echo "  stop                  Stop all project containers without deleting state"
  echo "  restart [service]     Restart the whole stack or one service"
  echo "  logs [service]        Follow logs for all services or one service"
  echo "  cmd \"command\"        Send a BDS console command"
  echo "  op \"Gamertag\"         Grant operator privileges"
  echo "  awake                 Keep macOS awake while BDS is running"
  echo "  backup                Stop BDS and archive local runtime data"
  echo "  renew-cert            Renew Tailscale HTTPS cert and restart BVC"
}

case "${1:-}" in
  start)
    docker compose up -d
    ;;
  stop)
    docker compose stop
    ;;
  restart)
    shift
    if [ "$#" -gt 0 ]; then docker compose restart "$@"; else docker compose restart; fi
    ;;
  logs)
    shift
    if [ "$#" -gt 0 ]; then docker compose logs -f --tail=200 "$@"; else docker compose logs -f --tail=200; fi
    ;;
  cmd)
    shift
    if [ "$#" -eq 0 ]; then echo "Usage: $0 cmd \"say Hello\"" >&2; exit 1; fi
    docker exec "$BDS_CONTAINER" send-command "$*"
    ;;
  op)
    shift
    if [ "$#" -ne 1 ]; then echo "Usage: $0 op \"YourGamertag\"" >&2; exit 1; fi
    docker exec "$BDS_CONTAINER" send-command "op \"$1\""
    ;;
  awake)
    caffeinate -dims docker wait "$BDS_CONTAINER"
    ;;
  backup)
    mkdir -p backups
    STAMP="$(date +%Y%m%d-%H%M%S)"
    OUTPUT="backups/${LEVEL_NAME// /-}-$STAMP.tar.gz"
    WAS_RUNNING="false"
    if [ "$(docker inspect -f '{{.State.Running}}' "$BDS_CONTAINER" 2>/dev/null || true)" = "true" ]; then
      WAS_RUNNING="true"
      docker compose stop "$BDS_CONTAINER"
    fi
    tar -czf "$OUTPUT" -C data .
    if [ "$WAS_RUNNING" = "true" ]; then docker compose up -d "$BDS_CONTAINER"; fi
    echo "Backup written to $OUTPUT"
    ;;
  renew-cert)
    TS_DOMAIN="${TS_DOMAIN:-}"
    if [ -z "$TS_DOMAIN" ] || [ "$TS_DOMAIN" = "minecraft-bedrock.example.ts.net" ]; then
      echo "ERROR: Set the real TS_DOMAIN in .env before renewing the certificate." >&2
      exit 1
    fi
    mkdir -p bvc-data/tls
    docker exec "$TAILSCALE_CONTAINER" mkdir -p /tmp/certs
    docker exec "$TAILSCALE_CONTAINER" tailscale cert \
      --cert-file=/tmp/certs/cert.pem --key-file=/tmp/certs/key.pem "$TS_DOMAIN"
    docker cp "$TAILSCALE_CONTAINER:/tmp/certs/cert.pem" bvc-data/tls/cert.pem
    docker cp "$TAILSCALE_CONTAINER:/tmp/certs/key.pem" bvc-data/tls/key.pem
    chmod 644 bvc-data/tls/cert.pem
    chmod 600 bvc-data/tls/key.pem
    docker compose --profile voice restart "$BVC_CONTAINER"
    echo "Certificate renewed and Bedrock Voice Chat restarted."
    ;;
  *)
    usage
    exit 1
    ;;
esac

