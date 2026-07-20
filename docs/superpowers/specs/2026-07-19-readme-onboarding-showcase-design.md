# README Onboarding Showcase Design

## Goal

Make the new onboarding flow visible near the top of the README without replacing the existing translation demo. A first-time visitor should understand both the product outcome and the path from installation to a successful first translation.

## Selected Design

Keep the existing translation demo video as the primary product demonstration. Add a new section immediately after the introductory feature bullets and before **Install**:

- Heading: `From install to first translation`
- Centered `docs/media/onboarding-flow.gif` at its native 640 px width
- Accessible alt text describing the model, permission, and translation-test stages
- A compact centered caption: **Choose Model → Grant Permissions → Try It**
- One sentence explaining that onboarding progress survives the macOS **Quit & Reopen** permission flow

## Presentation Rules

- Use the existing README's centered HTML image pattern so GitHub renders the GIF predictably.
- Do not add `onboarding-preview.gif` to the main README section; two animated images near the top would compete for attention.
- Do not remove or reorder the existing App Store call-to-action, translation demo video, icon, or toast image.
- Keep the new copy concise and product-focused rather than documenting implementation details.
- Do not introduce new assets or modify the GIF files.

## Verification

- Confirm the relative GIF path exists and the file is a valid 640×465 GIF.
- Inspect the README diff to ensure the section sits between the intro bullets and **Install**.
- Confirm the rendered markup has a descriptive `alt` attribute and no broken HTML tags.
- Push the documentation change with `[skip release]` so it does not create a new application release.

## Out of Scope

- Changing application behavior or onboarding copy inside the app
- Replacing the main translation demo
- Adding a multi-GIF gallery or per-step screenshot grid
