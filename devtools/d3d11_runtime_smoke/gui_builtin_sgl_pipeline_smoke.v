module main

import gg
import math
import os
import sokol.gfx
import sokol.sgl

#include "@VMODROOT/shaders/gui_builtin.h"

fn C.gui_rounded_rect_shader_desc(gfx.Backend) &gfx.ShaderDesc
fn C.gui_shadow_shader_desc(gfx.Backend) &gfx.ShaderDesc
fn C.gui_blur_shader_desc(gfx.Backend) &gfx.ShaderDesc
fn C.gui_gradient_shader_desc(gfx.Backend) &gfx.ShaderDesc
fn C.gui_image_clip_shader_desc(gfx.Backend) &gfx.ShaderDesc

fn phase_log_dir() string {
	return os.join_path(os.getwd(), 'd3d11-smoke-logs')
}

fn phase_log_path() string {
	return os.join_path(phase_log_dir(), '${os.file_name(os.executable())}.phase.log')
}

fn log_phase(message string) {
	println(message)
	log_dir := phase_log_dir()
	os.mkdir_all(log_dir) or {
		eprintln('phase log mkdir failed: ${err}')
		return
	}
	path := phase_log_path()
	mut file := os.open_file(path, 'a') or {
		eprintln('phase log open failed: ${err}')
		return
	}
	file.writeln(message) or { eprintln('phase log write failed: ${err}') }
	file.close()
}

struct App {
mut:
	gg               &gg.Context = unsafe { nil }
	rounded_rect_pip sgl.Pipeline
	shadow_pip       sgl.Pipeline
	blur_pip         sgl.Pipeline
	gradient_pip     sgl.Pipeline
	image_clip_pip   sgl.Pipeline
	frames           int
}

const packed_param_stride = 4096
const packed_param_scale = 4
const packed_param_mask = packed_param_stride - 1

fn require_d3d11_on_windows(backend gfx.Backend) {
	$if windows {
		if backend != .d3d11 {
			panic('expected D3D11 backend on Windows, got ${backend}')
		}
	}
}

@[inline]
fn pack_shader_params(radius f32, thickness f32) f32 {
	max_value := f32(packed_param_mask) / f32(packed_param_scale)
	safe_radius := math.max(0.0, math.min(radius, max_value))
	safe_thickness := math.max(0.0, math.min(thickness, max_value))
	radius_q := int(math.round(f64(safe_radius * f32(packed_param_scale))))
	thickness_q := int(math.round(f64(safe_thickness * f32(packed_param_scale))))
	return f32(radius_q * packed_param_stride + thickness_q)
}

fn gui_builtin_vertex_layout() gfx.VertexLayoutState {
	mut attrs := [16]gfx.VertexAttrDesc{}
	attrs[0] = gfx.VertexAttrDesc{
		format:       .float3
		offset:       0
		buffer_index: 0
	}
	attrs[1] = gfx.VertexAttrDesc{
		format:       .float2
		offset:       12
		buffer_index: 0
	}
	attrs[2] = gfx.VertexAttrDesc{
		format:       .ubyte4n
		offset:       20
		buffer_index: 0
	}
	mut buffers := [8]gfx.VertexBufferLayoutState{}
	buffers[0] = gfx.VertexBufferLayoutState{
		stride: 24
	}
	return gfx.VertexLayoutState{
		attrs:   attrs
		buffers: buffers
	}
}

fn gui_builtin_alpha_colors() [4]gfx.ColorTargetState {
	mut colors := [4]gfx.ColorTargetState{}
	colors[0] = gfx.ColorTargetState{
		blend:      gfx.BlendState{
			enabled:          true
			src_factor_rgb:   .src_alpha
			dst_factor_rgb:   .one_minus_src_alpha
			src_factor_alpha: .one
			dst_factor_alpha: .one_minus_src_alpha
		}
		write_mask: .rgba
	}
	return colors
}

fn make_gui_builtin_sgl_pipeline(label &char, shader gfx.Shader) sgl.Pipeline {
	desc := gfx.PipelineDesc{
		label:  unsafe { label }
		colors: gui_builtin_alpha_colors()
		layout: gui_builtin_vertex_layout()
		shader: shader
	}
	return sgl.make_pipeline(&desc)
}

fn draw_probe_quad() {
	log_phase('draw_probe_quad: entered')
	params := pack_shader_params(12.0, 0.0)
	log_phase('draw_probe_quad: packed params=${params}')
	log_phase('draw_probe_quad: before sgl.begin_quads')
	sgl.begin_quads()
	log_phase('draw_probe_quad: after sgl.begin_quads')
	sgl.c4b(60, 140, 240, 255)
	log_phase('draw_probe_quad: after color')
	sgl.t2f(-1.0, -1.0)
	sgl.v3f(32, 24, params)
	log_phase('draw_probe_quad: after vertex 1')
	sgl.t2f(1.0, -1.0)
	sgl.v3f(128, 24, params)
	log_phase('draw_probe_quad: after vertex 2')
	sgl.t2f(1.0, 1.0)
	sgl.v3f(128, 96, params)
	log_phase('draw_probe_quad: after vertex 3')
	sgl.t2f(-1.0, 1.0)
	sgl.v3f(32, 96, params)
	log_phase('draw_probe_quad: after vertex 4')
	log_phase('draw_probe_quad: before sgl.end')
	sgl.end()
	log_phase('draw_probe_quad: after sgl.end')
}

fn create_shader(name string, desc &gfx.ShaderDesc) gfx.Shader {
	if desc == unsafe { nil } {
		panic('${name} shader desc is unavailable for backend ${gfx.query_backend()}')
	}
	log_phase('${name}: before make_shader')
	shader := gfx.make_shader(desc)
	log_phase('${name}: after make_shader')
	log_phase('${name}: before query_shader_state')
	state := gfx.query_shader_state(shader)
	log_phase('${name}: after query_shader_state')
	log_phase('${name} shader state: ${state}')
	if state != .valid {
		panic('${name} shader did not become valid')
	}
	return shader
}

fn create_sgl_pipeline(name string, label &char, desc &gfx.ShaderDesc) sgl.Pipeline {
	shader := create_shader(name, desc)
	log_phase('${name}: before make_pipeline')
	pipeline := make_gui_builtin_sgl_pipeline(label, shader)
	log_phase('${name}: after make_pipeline')
	log_phase('${name} sgl pipeline id: ${pipeline.id}')
	if pipeline.id == 0 {
		panic('${name} sgl pipeline id is zero')
	}
	return pipeline
}

fn init(data voidptr) {
	log_phase('gui_builtin SGL D3D11 smoke init entered')
	mut app := unsafe { &App(data) }
	backend := gfx.query_backend()
	log_phase('gfx backend: ${backend}')
	require_d3d11_on_windows(backend)
	log_phase('rounded_rect: before descriptor lookup')
	rounded_rect_desc := C.gui_rounded_rect_shader_desc(backend)
	log_phase('rounded_rect: after descriptor lookup')
	app.rounded_rect_pip = create_sgl_pipeline('rounded_rect', c'rounded_rect_smoke_pip',
		rounded_rect_desc)
	log_phase('shadow: before descriptor lookup')
	shadow_desc := C.gui_shadow_shader_desc(backend)
	log_phase('shadow: after descriptor lookup')
	app.shadow_pip = create_sgl_pipeline('shadow', c'shadow_smoke_pip', shadow_desc)
	log_phase('blur: before descriptor lookup')
	blur_desc := C.gui_blur_shader_desc(backend)
	log_phase('blur: after descriptor lookup')
	app.blur_pip = create_sgl_pipeline('blur', c'blur_smoke_pip', blur_desc)
	log_phase('gradient: before descriptor lookup')
	gradient_desc := C.gui_gradient_shader_desc(backend)
	log_phase('gradient: after descriptor lookup')
	app.gradient_pip = create_sgl_pipeline('gradient', c'gradient_smoke_pip', gradient_desc)
	log_phase('image_clip: before descriptor lookup')
	image_clip_desc := C.gui_image_clip_shader_desc(backend)
	log_phase('image_clip: after descriptor lookup')
	app.image_clip_pip = create_sgl_pipeline('image_clip', c'image_clip_smoke_pip', image_clip_desc)
	log_phase('gui_builtin SGL D3D11 smoke init completed')
}

fn frame(data voidptr) {
	mut app := unsafe { &App(data) }
	app.frames++
	log_phase('gui_builtin SGL D3D11 smoke frame ${app.frames} entered')
	log_phase('gui_builtin frame ${app.frames}: before gg.begin')
	app.gg.begin()
	log_phase('gui_builtin frame ${app.frames}: after gg.begin')
	if app.frames <= 3 {
		log_phase('gui_builtin frame ${app.frames}: before sgl.load_pipeline')
	}
	sgl.load_pipeline(app.rounded_rect_pip)
	if app.frames <= 3 {
		log_phase('gui_builtin frame ${app.frames}: after sgl.load_pipeline')
		log_phase('gui_builtin frame ${app.frames}: before draw_probe_quad')
	}
	draw_probe_quad()
	if app.frames <= 3 {
		log_phase('gui_builtin frame ${app.frames}: after draw_probe_quad')
		log_phase('gui_builtin frame ${app.frames}: before sgl.load_default_pipeline')
	}
	sgl.load_default_pipeline()
	if app.frames <= 3 {
		log_phase('gui_builtin frame ${app.frames}: after sgl.load_default_pipeline')
		log_phase('gui_builtin frame ${app.frames}: before gg.end')
	}
	app.gg.end()
	if app.frames <= 3 {
		log_phase('gui_builtin frame ${app.frames}: after gg.end')
	}
	if app.frames >= 3 {
		log_phase('gui_builtin SGL D3D11 smoke frame ${app.frames}: before quit')
		app.gg.quit()
		log_phase('gui_builtin SGL D3D11 smoke frame ${app.frames}: after quit')
	}
}

fn main() {
	log_phase('gui_builtin SGL D3D11 smoke main started')
	mut app := &App{}
	log_phase('gui_builtin SGL D3D11 smoke creating context')
	app.gg = gg.new_context(
		width:         160
		height:        120
		create_window: true
		window_title:  'D3D11 gui_builtin SGL smoke'
		bg_color:      gg.white
		init_fn:       init
		frame_fn:      frame
		user_data:     app
	)
	log_phase('gui_builtin SGL D3D11 smoke context created')
	log_phase('gui_builtin SGL D3D11 smoke before gg.run')
	app.gg.run()
	log_phase('gui_builtin SGL D3D11 smoke after gg.run frames=${app.frames}')
	if app.frames < 3 {
		panic('gui_builtin SGL D3D11 smoke closed before 3 frames, got ${app.frames}')
	}
	log_phase('gui_builtin SGL D3D11 smoke completed')
}
