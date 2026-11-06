# Source and rights record

These four files were copied byte-for-byte from the existing Infinite Remote application working tree on 2026-11-05, after its complete relocation into app/. Original repository HEAD: 5415c92; the source includes the user’s existing uncommitted changes.

The image originated in the app’s existing remote design assets. The original prompt records an ImageGen rendering based on Xiaomi product references; upstream working notes reference https://www.mi.com/xiaomi-bluetooth-remote-2-pro. This is provenance, not a license grant or an assertion that third-party product appearance/trademarks have been cleared. The website does not use this image as its brand or hero. The repository code is GPL-3.0-or-later; this does not grant trademark or third-party artwork rights.

Original package path: Sources/RemoteDesk/Resources/RemoteModels/xiaomi-2-pro/.

## Initial SHA256

- `manifest.json`: `842bd25ad1c82eabe7a87849d4e5a29c7d08a66ed997a85f6fab00c95fc466cc`
- `layout.json`: `450387e313e8c349ab3789b77d59aabf80e9616538212a219daefecd5cf461c8`
- `inputs.json`: `ed9456f2bdddaeb4269f12f12bc65cf2309a4a406ed59740d77af020c24a03da`
- `front.png`: `d799f438b5cfc5abfb62ba1cb1e96903b043e9fe2238db5189c1f5ae4152d467`

## Registered alpha cleanup (2026-11-05)

The original PNG is retained at `artwork/xiaomi-2-pro/front-source.png` with the checksum above. `artwork/xiaomi-2-pro/cutout.json` records its measured smooth silhouette. Reproduce the final alpha with Python 3 + Pillow:

```sh
python3 scripts/clean_artwork.py --source artwork/xiaomi-2-pro/front-source.png --recipe artwork/xiaomi-2-pro/cutout.json --output models/xiaomi-2-pro/front.png
```

The authoring tool preserves the 724 × 2172 canvas, all RGB pixels and interior alpha. Only perimeter/exterior alpha is repaired, using 16 × 16 subpixel coverage with no blur, resizing, translation or generative redraw. The visible rectangle remains (100, 106, 525, 2001), and every key/anchor shape and HID input rule is unchanged. Manufacturer markings are retained from the original, not regenerated. The rejected generative candidate was not incorporated.

Model-specific annotation sides and hardware status text now belong to this package. The source-artwork directory and authoring recipe are not shipped in the model ZIP. Pillow is only required for optional artwork authoring/QA; normal Hub validation and distribution still use the Python standard library.

## Package v2 and official brand logo (2026-11-05)

Protocol v2 adds English/Chinese names, summaries, key/capability descriptions and hardware status, release 1.0.0, default actions, application target and behavior declarations. Existing model/key/capability IDs, HID device/input rules, artwork bytes and all hotspot geometry remain unchanged. The initial hashes above describe the historical v1 source; the cleaned front PNG remains SHA256 `981bd8a7144d27d8a4cd3706843b4f2d2641450ce9eb27a563f7c6541b94b221`.

`brand.png` is the authentic Xiaomi brand icon, downloaded byte-for-byte on 2026-11-05 from the PNG favicon linked by Xiaomi's official global homepage HTML at https://www.mi.com/global/ :

- Asset: https://i02.appmifile.com/i18n/scm/favicon.png
- PNG size: 196 × 196 pixels
- SHA256: `cbd7602e878c987180cbb14e86aa241541e3523e85362e1ac0bc7b896f93ea65`
- No generative recreation, recoloring, tracing, cropping or resizing was applied.

The Xiaomi mark identifies the supported device brand. Xiaomi retains its trademark and asset rights; public availability is not a license grant or an endorsement of this project. This provenance is separate from the generated product artwork record above.

## Release 1.0.1: compact English key labels (2026-11-05)

Native English UI verification found the existing annotation/name lanes could truncate “Confirm” and “Volume up/down”. Release 1.0.1 changes only these English key labels to “OK”, “Vol +” and “Vol −”, preserving the shared renderer and its established dimensions. Chinese names, all IDs/HID rules, artwork, geometry, defaults and full hardware descriptions are unchanged. The release is incremented because 1.0.0 has already been published; published package bytes are not silently replaced under the same version.

## Public release line 0.0.1 (2026-11-05)

The owner requested the first personal-account public release to use `0.0.1`, independently of the application version. The earlier `1.0.0`/`1.0.1` development publication history above is retained for provenance. The new package declares `0.0.1` and receives a new ZIP hash; it does not reuse an earlier version's bytes or disable downgrade protection. Device IDs, HID mappings, artwork, geometry and translated key labels are unchanged.
