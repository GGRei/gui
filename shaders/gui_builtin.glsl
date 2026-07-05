// Built-in v-gui shaders.
//
// Regenerate gui_builtin.h with:
//   v shader -l glsl410 -l hlsl4 -l metal_macos shaders/gui_builtin.glsl

@vs gui_rect_vs
uniform gui_rect_vs_params {
    mat4 mvp;
    mat4 tm;
};

in vec3 position;
in vec2 texcoord0;
in vec4 color0;
in float psize;

out vec2 uv;
out vec4 color;
out float params;

void main() {
    gl_Position = mvp * vec4(position.xy, 0.0, 1.0);
    gl_PointSize = psize;
    uv = texcoord0;
    color = color0;
    params = position.z;
}
@end

@vs gui_shadow_vs
uniform gui_shadow_vs_params {
    mat4 mvp;
    mat4 tm;
};

in vec3 position;
in vec2 texcoord0;
in vec4 color0;
in float psize;

out vec2 uv;
out vec4 color;
out float params;
out vec2 offset;

void main() {
    gl_Position = mvp * vec4(position.xy, 0.0, 1.0);
    gl_PointSize = psize;
    uv = texcoord0;
    color = color0;
    params = position.z;
    offset = (tm * vec4(0.0, 0.0, 0.0, 1.0)).xy;
}
@end

@vs gui_gradient_vs
uniform gui_gradient_vs_params {
    mat4 mvp;
    mat4 tm;
};

in vec3 position;
in vec2 texcoord0;
in vec4 color0;
in float psize;

out vec2 uv;
out vec4 color;
out float params;
out vec4 stop12;
out vec4 stop34;
out vec4 stop56;
out vec4 meta;

void main() {
    gl_Position = mvp * vec4(position.xy, 0.0, 1.0);
    gl_PointSize = psize;
    uv = texcoord0;
    color = color0;
    params = position.z;
    stop12 = tm[0];
    stop34 = tm[1];
    stop56 = tm[2];
    meta = tm[3];
}
@end

@vs gui_filter_vs
uniform gui_filter_vs_params {
    mat4 mvp;
    mat4 tm;
};

in vec3 position;
in vec2 texcoord0;
in vec4 color0;

out vec2 uv;
out vec4 color;
out float std_dev;

void main() {
    gl_Position = mvp * vec4(position.xy, 0.0, 1.0);
    uv = texcoord0;
    color = color0;
    std_dev = tm[0][0];
}
@end

@vs gui_filter_sgl_vs
uniform gui_filter_sgl_vs_params {
    mat4 mvp;
    mat4 tm;
};

in vec3 position;
in vec2 texcoord0;
in vec4 color0;
in float psize;

out vec2 uv;
out vec4 color;
out float std_dev;

void main() {
    gl_Position = mvp * vec4(position.xy, 0.0, 1.0);
    gl_PointSize = psize;
    uv = texcoord0;
    color = color0;
    std_dev = tm[0][0];
}
@end

@fs gui_rounded_rect_fs
uniform texture2D tex;
uniform sampler smp;

in vec2 uv;
in vec4 color;
in float params;

out vec4 frag_color;

float gui_unpack_radius(float packed_params) {
    return floor(packed_params / 4096.0) / 4.0;
}

float gui_unpack_secondary(float packed_params) {
    return mod(packed_params, 4096.0) / 4.0;
}

float gui_rounded_box_sdf(vec2 pos, vec2 half_size, float radius) {
    vec2 q = abs(pos) - half_size + vec2(radius);
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

float gui_normalized_sdf_alpha(float d) {
    float grad_len = length(vec2(dFdx(d), dFdy(d)));
    d = d / max(grad_len, 0.001);
    return 1.0 - smoothstep(-0.59, 0.59, d);
}

void main() {
    float radius = gui_unpack_radius(params);
    float thickness = gui_unpack_secondary(params);

    vec2 uv_to_px = 1.0 / (vec2(fwidth(uv.x), fwidth(uv.y)) + 1e-6);
    vec2 half_size = uv_to_px;
    vec2 pos = uv * half_size;

    float d = gui_rounded_box_sdf(pos, half_size, radius);
    if (thickness > 0.0) {
        d = abs(d + thickness * 0.5) - thickness * 0.5;
    }

    float alpha = gui_normalized_sdf_alpha(d);
    frag_color = vec4(color.rgb, color.a * alpha);
    if (frag_color.a < 0.0) {
        frag_color += texture(sampler2D(tex, smp), uv);
    }
}
@end

@fs gui_shadow_fs
uniform texture2D tex;
uniform sampler smp;

in vec2 uv;
in vec4 color;
in float params;
in vec2 offset;

out vec4 frag_color;

float gui_unpack_radius(float packed_params) {
    return floor(packed_params / 4096.0) / 4.0;
}

float gui_unpack_secondary(float packed_params) {
    return mod(packed_params, 4096.0) / 4.0;
}

float gui_rounded_box_sdf(vec2 pos, vec2 half_size, float radius) {
    vec2 q = abs(pos) - half_size + vec2(radius);
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

void main() {
    float radius = gui_unpack_radius(params);
    float blur = gui_unpack_secondary(params);

    vec2 uv_to_px = 1.0 / (vec2(fwidth(uv.x), fwidth(uv.y)) + 1e-6);
    vec2 half_size = uv_to_px;
    vec2 pos = uv * half_size;

    vec2 expanded = half_size - vec2(1.5 * blur);
    float d = gui_rounded_box_sdf(pos, expanded, radius);
    float d_c = gui_rounded_box_sdf(pos + offset, expanded, radius);

    float alpha_falloff = 1.0 - smoothstep(0.0, max(1.0, blur), d);
    float alpha_clip = smoothstep(-1.0, 0.0, d_c);
    float alpha = alpha_falloff * alpha_clip;

    frag_color = vec4(color.rgb, color.a * alpha);
    if (frag_color.a < 0.0) {
        frag_color += texture(sampler2D(tex, smp), uv);
    }
}
@end

@fs gui_blur_fs
uniform texture2D tex;
uniform sampler smp;

in vec2 uv;
in vec4 color;
in float params;
in vec2 offset;

out vec4 frag_color;

float gui_unpack_radius(float packed_params) {
    return floor(packed_params / 4096.0) / 4.0;
}

float gui_unpack_secondary(float packed_params) {
    return mod(packed_params, 4096.0) / 4.0;
}

float gui_rounded_box_sdf(vec2 pos, vec2 half_size, float radius) {
    vec2 q = abs(pos) - half_size + vec2(radius);
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

void main() {
    float radius = gui_unpack_radius(params);
    float blur = gui_unpack_secondary(params);

    vec2 uv_to_px = 1.0 / (vec2(fwidth(uv.x), fwidth(uv.y)) + 1e-6);
    vec2 half_size = uv_to_px;
    vec2 pos = uv * half_size;

    vec2 expanded = half_size - vec2(1.5 * blur);
    float d = gui_rounded_box_sdf(pos, expanded, radius);
    float alpha = 1.0 - smoothstep(-blur, blur, d);

    frag_color = vec4(color.rgb, color.a * alpha);
    if (frag_color.a < 0.0) {
        frag_color += texture(sampler2D(tex, smp), uv);
    }
}
@end

@fs gui_gradient_fs
uniform texture2D tex;
uniform sampler smp;

in vec2 uv;
in vec4 color;
in float params;
in vec4 stop12;
in vec4 stop34;
in vec4 stop56;
in vec4 meta;

out vec4 frag_color;

float gui_unpack_radius(float packed_params) {
    return floor(packed_params / 4096.0) / 4.0;
}

float gui_rounded_box_sdf(vec2 pos, vec2 half_size, float radius) {
    vec2 q = abs(pos) - half_size + vec2(radius);
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

float gui_normalized_sdf_alpha(float d) {
    float grad_len = length(vec2(dFdx(d), dFdy(d)));
    d = d / max(grad_len, 0.001);
    return 1.0 - smoothstep(-0.59, 0.59, d);
}

float gui_random(vec2 coords) {
    return fract(sin(dot(coords.xy, vec2(12.9898, 78.233))) * 43758.5453);
}

void gui_unpack_gradient_data(float val1, float val2, out vec4 c, out float p) {
    float r = mod(val1, 256.0);
    float g = mod(floor(val1 / 256.0), 256.0);
    float b = floor(val1 / 65536.0);
    float a = mod(val2, 256.0);
    p = floor(val2 / 256.0) / 10000.0;
    c = vec4(r / 255.0, g / 255.0, b / 255.0, a / 255.0);
}

void main() {
    float radius = gui_unpack_radius(params);
    float hw = meta.x;
    float hh = meta.y;
    float grad_type = meta.z;
    int stop_count = int(meta.w);

    vec2 pos = uv * vec2(hw, hh);
    float d = gui_rounded_box_sdf(pos, vec2(hw, hh), radius);
    float sdf_alpha = 1.0 - smoothstep(-0.5, 0.5, d);

    float t;
    if (grad_type > 0.5) {
        float target_radius = stop56.w;
        t = length(pos) / target_radius;
    } else {
        vec2 stop_dir = vec2(stop56.z, stop56.w);
        t = dot(uv, stop_dir) * 0.5 + 0.5;
    }
    t = clamp(t, 0.0, 1.0);

    vec4 stop_colors[6];
    float stop_positions[6];
    gui_unpack_gradient_data(stop12.x, stop12.y, stop_colors[0], stop_positions[0]);
    gui_unpack_gradient_data(stop12.z, stop12.w, stop_colors[1], stop_positions[1]);
    gui_unpack_gradient_data(stop34.x, stop34.y, stop_colors[2], stop_positions[2]);
    gui_unpack_gradient_data(stop34.z, stop34.w, stop_colors[3], stop_positions[3]);
    gui_unpack_gradient_data(stop56.x, stop56.y, stop_colors[4], stop_positions[4]);
    stop_colors[5] = stop_colors[4];
    stop_positions[5] = stop_positions[4];

    vec4 c1 = stop_colors[0];
    vec4 c2 = c1;
    float p1 = stop_positions[0];
    float p2 = p1;

    for (int i = 1; i < 6; i++) {
        if (i >= stop_count) {
            break;
        }
        if (t <= stop_positions[i]) {
            c2 = stop_colors[i];
            p2 = stop_positions[i];
            c1 = stop_colors[i - 1];
            p1 = stop_positions[i - 1];
            break;
        }
        if (i == stop_count - 1) {
            c1 = stop_colors[i];
            c2 = c1;
            p1 = stop_positions[i];
            p2 = p1;
        }
    }

    float local_t = (t - p1) / max(p2 - p1, 0.0001);
    vec3 c1_pre = c1.rgb * c1.a;
    vec3 c2_pre = c2.rgb * c2.a;
    vec3 rgb_pre = mix(c1_pre, c2_pre, local_t);
    float alpha = mix(c1.a, c2.a, local_t);
    vec3 rgb = rgb_pre / max(alpha, 0.0001);
    vec4 gradient_color = vec4(rgb, alpha);

    float dither = (gui_random(gl_FragCoord.xy) - 0.5) / 255.0;
    gradient_color.rgb += vec3(dither);

    frag_color = vec4(gradient_color.rgb, gradient_color.a * sdf_alpha * color.a);
    if (frag_color.a < 0.0) {
        frag_color += texture(sampler2D(tex, smp), uv);
    }
}
@end

@fs gui_image_clip_fs
uniform texture2D tex;
uniform sampler smp;

in vec2 uv;
in vec4 color;
in float params;

out vec4 frag_color;

float gui_unpack_radius(float packed_params) {
    return floor(packed_params / 4096.0) / 4.0;
}

float gui_rounded_box_sdf(vec2 pos, vec2 half_size, float radius) {
    vec2 q = abs(pos) - half_size + vec2(radius);
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

float gui_normalized_sdf_alpha(float d) {
    float grad_len = length(vec2(dFdx(d), dFdy(d)));
    d = d / max(grad_len, 0.001);
    return 1.0 - smoothstep(-0.59, 0.59, d);
}

void main() {
    float radius = gui_unpack_radius(params);
    vec2 uv_to_px = 1.0 / (vec2(fwidth(uv.x), fwidth(uv.y)) + 1e-6);
    vec2 half_size = uv_to_px;
    vec2 pos = uv * half_size;

    float d = gui_rounded_box_sdf(pos, half_size, radius);
    float alpha = gui_normalized_sdf_alpha(d);

    vec2 tex_uv = uv * 0.5 + 0.5;
    vec4 tex_color = texture(sampler2D(tex, smp), tex_uv);
    frag_color = vec4(tex_color.rgb, tex_color.a * alpha);
}
@end

@fs gui_filter_blur_h_fs
uniform texture2D tex;
uniform sampler smp;

in vec2 uv;
in vec4 color;
in float std_dev;

out vec4 frag_color;

void main() {
    float w[7] = float[7](0.19947, 0.17603, 0.12098, 0.06476, 0.02700, 0.00877, 0.00222);
    vec2 tex_size = vec2(textureSize(sampler2D(tex, smp), 0));
    float step_size = std_dev / tex_size.x;

    frag_color = texture(sampler2D(tex, smp), uv) * w[0];
    for (int i = 1; i < 7; i++) {
        float off = float(i) * step_size;
        frag_color += texture(sampler2D(tex, smp), uv + vec2(off, 0.0)) * w[i];
        frag_color += texture(sampler2D(tex, smp), uv - vec2(off, 0.0)) * w[i];
    }
}
@end

@fs gui_filter_blur_v_fs
uniform texture2D tex;
uniform sampler smp;

in vec2 uv;
in vec4 color;
in float std_dev;

out vec4 frag_color;

void main() {
    float w[7] = float[7](0.19947, 0.17603, 0.12098, 0.06476, 0.02700, 0.00877, 0.00222);
    vec2 tex_size = vec2(textureSize(sampler2D(tex, smp), 0));
    float step_size = std_dev / tex_size.y;

    frag_color = texture(sampler2D(tex, smp), uv) * w[0];
    for (int i = 1; i < 7; i++) {
        float off = float(i) * step_size;
        frag_color += texture(sampler2D(tex, smp), uv + vec2(0.0, off)) * w[i];
        frag_color += texture(sampler2D(tex, smp), uv - vec2(0.0, off)) * w[i];
    }
}
@end

@fs gui_filter_color_fs
in vec2 uv;
in vec4 color;
in float std_dev;

out vec4 frag_color;

void main() {
    frag_color = color;
}
@end

@fs gui_filter_texture_fs
uniform texture2D tex;
uniform sampler smp;

in vec2 uv;
in vec4 color;
in float std_dev;

out vec4 frag_color;

void main() {
    frag_color = texture(sampler2D(tex, smp), uv) * color;
}
@end

@program gui_rounded_rect gui_rect_vs gui_rounded_rect_fs
@program gui_shadow gui_shadow_vs gui_shadow_fs
@program gui_blur gui_shadow_vs gui_blur_fs
@program gui_gradient gui_gradient_vs gui_gradient_fs
@program gui_image_clip gui_rect_vs gui_image_clip_fs
@program gui_filter_blur_h gui_filter_vs gui_filter_blur_h_fs
@program gui_filter_blur_v gui_filter_vs gui_filter_blur_v_fs
@program gui_filter_color gui_filter_vs gui_filter_color_fs
@program gui_filter_texture gui_filter_sgl_vs gui_filter_texture_fs
