# logitech_mx_ink.glb

The Logitech MX Ink stylus model (nodes: `controller_mesh`, `tip`, `front_button`, `middle_button`, `rear_button`), authored for the OpenXR
grip pose of the stylus. Taken unchanged from the `logitech-mx-ink` profile (`none.glb`) of
https://github.com/immersive-web/webxr-input-profiles (packages/assets/profiles/logitech-mx-ink), which is licensed under the
W3C Software and Document License (https://www.w3.org/Consortium/Legal/copyright-software). Used by `src/xr/stylus_model.gd`.

Import settings that matter (checked by `tests/test_stylus_model.gd`): **no generated LODs** (`meshes/generate_lods=false`): Godot's
simplified meshes tear the UV seams round the logos, so the "logi" text broke up whenever the stylus was small in view, i.e. at arm's
length in the headset. The logo texture stays **lossless** (`detect_3d/compress_to=0`, so the editor does not switch it to VRAM
compression, which smears the dim grey logos).
