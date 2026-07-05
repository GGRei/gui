# Generated Shaders

`gui_builtin.h` is generated from `gui_builtin.glsl` and committed so users do
not need to run shader generation before importing `gui`.

Regenerate after editing `gui_builtin.glsl`:

```sh
v shader -l glsl410 -l hlsl4 -l metal_macos shaders/gui_builtin.glsl
```

The `glsl410` target is intentional for the generated built-ins: current
`sokol-shdc` maps desktop `SG_BACKEND_GLCORE` shaders to GLSL 410/430. Do not
rewrite the generated header to `glsl330`; GLSL 3.3 remains the runtime custom
`Shader.glsl` body format, not the generated built-in shader target.

Before committing, keep the generated header's `Cmdline` line path-neutral:

```text
sokol-shdc --input shaders/gui_builtin.glsl --output shaders/gui_builtin.h --slang glsl410:hlsl4:metal_macos
```
