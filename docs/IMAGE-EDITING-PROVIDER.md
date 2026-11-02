# Image-edit model integration

**Provider choice:** Use MAIPA-G's already-configured OpenRouter account and model catalog. Do not require a separate Replicate account, Replicate API key, or new provider secret.

## Model eligibility

The Workstation edit picker includes only catalog models that are live chat models and advertise both `image` input and `image` output. Pure image-generation models that cannot accept a source image, and text/vision-only models that cannot return an image, are excluded. A model's advertised modalities are a filter, not proof of image-edit quality.

## Request shape and limits

The app uses the existing OpenRouter `/api/v1/chat/completions` transport. The request sends (1) the original image, (2) a same-size black-and-white mask image, and (3) the edit instruction. The instruction identifies the first image as the source and the second as a guide, with white as the area to change and black as the area to preserve. The model returns an image through the same image-output response format already handled by MAIPA-G.

The mask is a **visual guide**, not a provider-native inpainting mask parameter. A model may change unmasked pixels or ignore part of the mask. The UI must say this plainly, show the result for review, and never promise exact pixel preservation. The adapter validates dimensions, accepted MIME types, non-empty input, and output image signatures/size.

## Approval, account, and privacy

- The request uses the user's existing OpenRouter account and their selected catalog model; no separate image-provider credential is stored.
- Before every request, show the selected model, disclose that the original photo, mask, and instruction are sent to OpenRouter and its upstream model provider, and obtain an explicit in-app approval.
- Cost depends on the model/provider's current rates and may include image input/output charges. Do not invent a fixed price or claim an exact quote when the provider does not return one. Preserve the existing spend-approval pattern.
- The original image is never overwritten. Save a successful result as a new child image with parent metadata and the mask attachment. Do not save a partial or undecodable response.
- No real model request or visual quality proof has been run by the development workflow. The feature is not release-validated until an owner-approved sample edit is reviewed for output quality, mask adherence, latency, and actual cost.

## Local validation

Fixture tests should verify that the outgoing request uses only the selected eligible model, includes the source and mask as image inputs, requests image output, rejects mismatched dimensions and unsupported modalities before network access, handles an image response, and never logs image bytes or credentials. Real-provider testing requires the user's explicit approval in the app before a billed request.