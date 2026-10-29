# Troubleshooting

## Remote players get “Multiplayer Connection Failed”

Do not move Tailscale back to the macOS host and forward UDP into Docker. That arrangement can rewrite the UDP source address through the macOS `utun` interface and OrbStack bridge NAT, breaking NetherNet/WebRTC ICE handshakes.

The required design is:

- `bedrock-tailscale` owns the Tailscale interface and `/dev/net/tun`.
- `bedrock-voice` and `bedrock-server` use `network_mode: "service:tailscale"`.
- The Tailscale sidecar publishes the local fallback ports.

Check the namespace with:

```bash
docker compose ps
docker exec bedrock-tailscale tailscale status
```

## BDS says RakNet is unsupported

BDS `1.26.60+` requires NetherNet. Keep these values in `.env`:

```dotenv
TRANSPORT=nethernet
SERVER_UDP_PORTS=19140-19155
```

Restart after changing them:

```bash
./scripts/manage.sh restart bedrock-server
```

## The same Mac sees a LAN World entry that fails

Docker bridge broadcast discovery can advertise an internal or IPv6 endpoint. Ignore the automatic LAN World entry and use **Play → Servers → Add Server**, the Tailscale hostname, and port `19132`.

## Shared friends connect to Tailscale but packets are dropped

The Tailscale log may say `no rules matched`. Machine Sharing users are represented by `autogroup:shared`; your policy must explicitly allow both members and shared users. Merge this into the existing policy:

```json
{
  "grants": [
    {
      "src": ["autogroup:member", "autogroup:shared"],
      "dst": ["*"],
      "ip": ["*"]
    }
  ]
}
```

Then have the player reconnect Tailscale and retry.

## `tailscale up` reports an accept-DNS error

The official Tailscale container starts `tailscaled` with DNS acceptance disabled. Use:

```bash
docker exec bedrock-tailscale tailscale up --accept-dns=false
```

Do not remove `--accept-dns=false`. The Compose `extra_hosts` mapping is the deliberate replacement for the missing container DNS integration:

```yaml
extra_hosts:
  - "${TS_DOMAIN}:127.0.0.1"
```

## Voice app says the server is unreachable or TLS is invalid

Confirm all of the following:

1. The player is connected to Tailscale and can resolve the MagicDNS hostname.
2. MagicDNS and HTTPS certificates are enabled in Tailscale Admin DNS.
3. The voice URL uses `https://` and exactly the machine's MagicDNS name.
4. The BVC container is running: `docker compose --profile voice ps`.
5. The certificate is present and readable by BVC:

   ```bash
   ls -l bvc-data/tls/
   docker logs --tail=100 bedrock-voice
   ```

Certificates are valid for about 90 days. Renew them with:

```bash
./scripts/manage.sh renew-cert
```

This runs `tailscale cert` inside the sidecar, copies the certificate and private key into ignored `bvc-data/tls/`, and restarts BVC. Never commit those files.

## The BVC addon does not load on `26.60`

Do not byte-patch `experiments.gametest` in `level.dat`. BDS `1.26+` reads migrated experiment flags from LevelDB. Create the world in a Bedrock client with **Experiments → Beta APIs** enabled, then run:

```bash
./scripts/setup-voice.sh "YourXboxGamertag" "/path/to/world.mcworld"
```

The setup script also extracts the two nested `.mcpack` archives from the BVC `.mcaddon` and patches the BVC behavior-pack manifest from `@minecraft/server` `2.11.0-beta` / `@minecraft/server-ui` `2.3.0-beta` to the `26.60` compatible beta versions.

## A pack installs but does not appear

Use the drag-and-drop installer so the pack is copied into the correct behavior/resource directory and its UUID/version is added to the active world's pack list:

```bash
./scripts/install-pack.sh "/path/to/pack.mcaddon"
```

The input may be `.mcpack`, `.mcaddon`, `.zip`, or an unpacked folder. The folder must contain a valid Bedrock `manifest.json`.

## The Mac sleeps and the server becomes unavailable

Run this while the server should stay online:

```bash
./scripts/manage.sh awake
```

It wraps the Docker wait process with macOS `caffeinate`. OrbStack and the Tailscale sidecar must also remain running.

## Backups and sensitive files

Run:

```bash
./scripts/manage.sh backup
```

The archive is written under ignored `backups/`. It contains runtime data, which may include access tokens and worlds; keep it local and never upload it to GitHub.

