# How to Join the Private Bedrock Server

You need Minecraft Bedrock, a Tailscale account, and the Bedrock Voice Chat companion app. These steps work on Android, iPhone/iPad, and Windows PC.

## 1. Join the private network

1. Install **Tailscale** from the Google Play Store, Apple App Store, or [tailscale.com/download](https://tailscale.com/download).
2. Sign in with your own account.
3. Accept the Minecraft server share invitation from the server owner.
4. Open Tailscale and leave it connected. Keep **Use Tailscale DNS** enabled.

## 2. Join Minecraft

1. Open Minecraft Bedrock.
2. Select **Play → Servers → Add Server**.
3. Enter the server hostname supplied by the owner and port `19132`.
4. Save and join.

Use the supplied hostname, not the auto-discovered LAN World entry. Console editions are not covered by this guide.

## 3. Enable proximity voice

1. Install the **Bedrock Voice Chat** companion app from the official source supplied by the server owner.
2. In the app, enter the server URL:

   `https://YOUR_MACHINE.YOUR_TAILNET.ts.net`

3. Enter the one-time login code supplied by the owner.
4. Allow microphone permission and select the Minecraft profile if prompted.

That is it: Tailscale connects you to the private network, Minecraft connects on port `19132`, and voice uses the same machine over HTTPS `443` and voice QUIC `28280/udp`.

## If it does not connect

- Confirm Tailscale says connected and that you accepted the share invitation.
- Turn off another VPN temporarily.
- Confirm the hostname and port are exactly `19132`.
- Ask the owner for a new voice login code; codes expire.
- Do not use the LAN World shortcut.

