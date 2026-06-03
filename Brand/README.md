# Brand masters

Source artwork for WindowLens. Run from the repo root after updating these files:

```bash
swift scripts/prepare-brand-assets.swift
```

| File | Purpose |
| --- | --- |
| `WindowLens_Logo-compressed.png` | Full-color app icon (1024+ squircle) |
| `WindowLens_MenuBar.png` | White-on-black menu bar master (auto-cropped) |

Generated outputs land in `WindowLens/Resources/Assets.xcassets/` and `AppIcon.icns`.

For GitHub social preview, add `docs/brand/social-1280x640.png` and set it under **Repository settings → Social preview**.
