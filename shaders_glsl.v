module gui

// GLSL vertex source used by the runtime custom Shader API.
const vs_custom_glsl = '
    #version 330
    layout(location=0) in vec3 position;
    layout(location=1) in vec2 texcoord0;
    layout(location=2) in vec4 color0;

    uniform mat4 mvp;
    uniform mat4 tm;

    out vec2 uv;
    out vec4 color;
    out float params;
    out vec4 p0;
    out vec4 p1;
    out vec4 p2;
    out vec4 p3;

    void main() {
        gl_Position = mvp * vec4(position.xy, 0.0, 1.0);
        uv = texcoord0;
        color = color0;
        params = position.z;
        p0 = tm[0];
        p1 = tm[1];
        p2 = tm[2];
        p3 = tm[3];
    }
'
