# Philips Hue bridge behaviour

Verified against a real bridge (BSB002, API 1.78) on 2026-11-03 from a macOS
Network.framework spike. No keys, client keys or bridge ids are recorded here.

## Entertainment streaming (DTLS)

- Streaming opens only after `PUT /clip/v2/resource/entertainment_configuration/<id>`
  with `{"action":"start"}`; it is closed with `{"action":"stop"}`.
- DTLS 1.2 to UDP port 2100: `NWParameters(dtls:udp:)`, min and max protocol
  version `.DTLSv12`, PSK = hex-decoded `clientkey` bytes, PSK identity = the
  application key (`username`) as UTF-8.
- Offer both `TLS_PSK_WITH_AES_128_GCM_SHA256` (0x00A8) and
  `TLS_PSK_WITH_AES_256_GCM_SHA384` (0x00A9): the bridge negotiated 0x00A9
  although 0x00A8 was offered. Negotiated version 0xFEFD.
- ~48 packets/s were accepted (144 packets in 3 s). The bridge drops the
  stream after roughly 10 s without packets.

## Stream packet (v2)

| Bytes | Value |
|-------|-------|
| 0–8   | `HueStream` (ASCII) |
| 9–10  | `0x02 0x00` (version 2.0) |
| 11    | sequence (UInt8) |
| 12–13 | `0x00 0x00` reserved |
| 14    | colour space, `0x00` = RGB |
| 15    | `0x00` reserved |
| 16–51 | entertainment configuration id, 36 ASCII characters |
| then  | per channel: channel id (UInt8) + R, G, B (UInt16 big-endian) |

`HueStreamMessageTests` pins this layout.

## Entertainment areas seen

- `TV`: `configuration_type` `screen`, two channels — ch0 at
  (x 0.47, y 1.0, z -1.0), ch1 at (x -0.11, y 0.04, z 1.0).
- `Bildschirm`: `configuration_type` `monitor`, one channel.

## HTTP (CLIP v2 and pairing)

`HueBridgeClientTests` drives `HueBridgeClient` against the JSON files here.
They follow the documented response shapes; the ids and keys in them are
placeholders, not values from a real bridge.

- `GET /api/0/config` answers without a key and gives `name`, `bridgeid`
  (uppercase), `modelid` and `apiversion` (`hue-config.json`). For a typed
  address, Lume compares that `bridgeid` with the certificate's common name,
  which is the same id in lowercase.
- Pairing is `POST /api` with `{"devicetype":"lume#appletv","generateclientkey":true}`.
  Before the link button is pressed the answer is a 200 with
  `[{"error":{"type":101,…}}]` (`hue-pairing-link-button.json`). Afterwards it
  is `[{"success":{"username":…,"clientkey":…}}]` (`hue-pairing-success.json`).
  Lume makes one attempt per call; the caller does the polling.
- Every CLIP v2 response is the envelope `{"errors":[{"description":…}],"data":[…]}`.
  A PUT the bridge doesn't fully apply can come back 2xx with `errors` set
  (`hue-put-error.json`). The client treats that as rejected. It never shows
  the bridge's description text.
- A wrong or revoked `hue-application-key` gets a 403 with an
  `unauthorized user` error (`hue-error-403.json`).
- `entertainment_configuration` has `status` (`inactive` / `active`) and
  `active_streamer` (`hue-entertainment-configuration-active.json`).
  Channel members reference `entertainment` services. Their
  `renderer_reference` names the light (`hue-entertainment-services.json`).
- `light` gives `on.on`, `dimming.brightness` (percent), `color.xy` and
  `color_temperature.mirek` / `mirek_valid` (`hue-lights.json`).
- Streamed colours never reach the `light` resources: after a stream they
  still report the state from before it (verified on a BSB002). Restore
  therefore sends each light's whole captured state and never diffs.

### Not yet verified on hardware

- What the bridge answers to `{"action":"start"}` while another app streams
  to the area. Lume reads the area first and does not start one that is
  `active`. If a start is still refused (409 or a CLIP error), Lume reports
  the area as in use. It never takes the area over and never retries. After a
  crash, Lume's own stale stream also shows as in use until the bridge drops
  it, which takes about 10 s.
- Whether App Transport Security needs an exception to reach a bridge by
  bare IP on tvOS/iOS. This has to be checked on a device.

## TLS trust

The bridge certificate is self-issued and names the bridge id (16 hex digits,
lowercase) as its common name, so system trust can't evaluate it.
`HueTrust.decide` accepts it only in these cases:

- The chain verifies against Signify's bridge root (`CN=root-bridge`,
  embedded in `HueTrustDelegate.swift`) and the common name is the bridge id.
- Or the leaf matches the SHA-256 pin stored with the credentials. That pin is
  taken on first use, and only while pairing.

Everything else is refused, including a common name for a different bridge.
