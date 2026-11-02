# Brush-edit provider evaluation

**Status: documented candidate only; not enabled for user edits.** No API request has been sent and no image has been uploaded. The owner’s no-spend rule remains in force. A real proof requires explicit approval for one billed image and a Replicate credential; this note does not imply that proof passed.

## Leading candidate

- **Provider:** Replicate's official-model API.
- **Model:** `black-forest-labs/flux-fill-pro`.
- **Pinned version:** `b23335a86ed317e5a35eb1be11bbf8f8985f9fdf12c53484ecf930d734095f74`.
- **Documented price checked 2026-11-01:** `$0.05` per output image. The app must still get user approval before every paid edit; never infer an exact quote from a local estimate.
- **Inputs in the pinned schema:** `prompt` (string), `image` (file, JPEG/PNG/WebP), `mask` (file, JPEG/PNG/WebP, optional only if using an alpha mask), `seed` (integer, optional), plus `steps` (1–50, default 50), `prompt_upsampling` (boolean, default false), `guidance` (2–5, default 3), `safety_tolerance` (1–6, default 2), and `output_format` (default JPG).
- **Mask polarity:** black preserves; white is repainted. The mask must have the same pixel dimensions as the source.
- **Seed:** documented for reproducible generation; it is not a promise that faces or unmasked pixels will remain identical. Store only a seed actually supplied/returned by the service.
- **Input limits:** the published pinned input schema does not state a maximum pixel dimension. Replicate's generic file-input guidance recommends data URLs only for files below 1 MB; larger files should use a file upload or hosted URL. Do not silently upload user images to another hosting service. Before enabling, choose and test a size policy, keep source and mask dimensions identical, and disclose provider processing.
- **Output and retention:** the API returns a prediction; image output is represented by an HTTPS file URL. Replicate documents API prediction inputs/outputs as being deleted after one hour by default. The app must download and save a completed output locally, never retain a signed output URL in image metadata, and handle cancellation/timeouts without saving partial output.
- **Visual quality limitation:** documentation describes the intended inpainting behavior, but does not prove that the untouched area is preserved well enough for MAIPA-G. A real, redacted fixture and visual comparison are still required.

## Redacted request shape (not a working fixture)

The following shows the request contract only. Placeholders are not valid input and no credentials or user files are included.

```json
{
  "version": "b23335a86ed317e5a35eb1be11bbf8f8985f9fdf12c53484ecf930d734095f74",
  "input": {
    "prompt": "<user instruction>",
    "image": "<approved image file input>",
    "mask": "<same-size black/white mask file input>",
    "seed": 12345,
    "output_format": "jpg"
  }
}
```

For the official-model HTTP path, Replicate documents `POST /v1/models/black-forest-labs/flux-fill-pro/predictions`, bearer authentication, and polling through the prediction's `urls.get` until a terminal status. The app must validate that every API URL it follows is HTTPS and on the expected Replicate host, impose an output byte limit, and never log image/mask bytes, tokens, or full signed URLs.

## Evidence and remaining proof

Official schema and model information:

- [Pinned version API schema](https://replicate.com/black-forest-labs/flux-fill-pro/versions/b23335a86ed317e5a35eb1be11bbf8f8985f9fdf12c53484ecf930d734095f74/api)
- [Model pricing and data-use statement](https://replicate.com/black-forest-labs/flux-fill-pro/api/schema)
- [Replicate HTTP API and prediction lifecycle](https://replicate.com/docs/reference/http)
- [Replicate input files and data-URL guidance](https://replicate.com/docs/topics/predictions/input-files)
- [Black Forest Labs FLUX.1 Fill documentation](https://docs.bfl.ml/flux_1_fill)

Still required before the provider can be enabled:

1. Owner approval of one `$0.05` real-provider proof request and a suitable Replicate credential, or a clear decision not to use this provider.
2. Submit the roadmap's sample source/mask once; save a redacted request/response fixture with no credentials, image bytes, or signed URLs.
3. Verify output MIME type/dimensions and visually check that unmasked content is acceptably preserved; record latency and actual charge.
4. Implement/test the provider adapter against that verified fixture and pinned version. Until then, the in-app editor must not dispatch a request or imply that an edit is available.
