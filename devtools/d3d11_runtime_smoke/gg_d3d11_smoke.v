module main

import gg
import os
import sokol.gfx

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
	gg     &gg.Context = unsafe { nil }
	frames int
}

fn require_d3d11_on_windows(backend gfx.Backend) {
	$if windows {
		if backend != .d3d11 {
			panic('expected D3D11 backend on Windows, got ${backend}')
		}
	}
}

fn init(_ voidptr) {
	log_phase('gg D3D11 smoke init entered')
	backend := gfx.query_backend()
	log_phase('gfx backend: ${backend}')
	require_d3d11_on_windows(backend)
	log_phase('gg D3D11 smoke init completed')
}

fn frame(data voidptr) {
	mut app := unsafe { &App(data) }
	app.frames++
	log_phase('gg D3D11 smoke frame ${app.frames} entered')
	if app.frames <= 3 {
		log_phase('gg frame ${app.frames}: before gg.begin')
	}
	app.gg.begin()
	if app.frames <= 3 {
		log_phase('gg frame ${app.frames}: after gg.begin')
		log_phase('gg frame ${app.frames}: before draw_rect')
	}
	app.gg.draw_rect_filled(16, 16, 96, 64, gg.rgb(40, 120, 220))
	if app.frames <= 3 {
		log_phase('gg frame ${app.frames}: after draw_rect')
		log_phase('gg frame ${app.frames}: before gg.end')
	}
	app.gg.end()
	if app.frames <= 3 {
		log_phase('gg frame ${app.frames}: after gg.end')
	}
	if app.frames >= 3 {
		log_phase('gg D3D11 smoke frame ${app.frames} requesting quit')
		app.gg.quit()
	}
}

fn main() {
	log_phase('gg D3D11 smoke main started')
	mut app := &App{}
	log_phase('gg D3D11 smoke creating context')
	app.gg = gg.new_context(
		width:         160
		height:        120
		create_window: true
		window_title:  'D3D11 gg smoke'
		bg_color:      gg.white
		init_fn:       init
		frame_fn:      frame
		user_data:     app
	)
	log_phase('gg D3D11 smoke context created')
	log_phase('gg D3D11 smoke before gg.run')
	app.gg.run()
	log_phase('gg D3D11 smoke after gg.run frames=${app.frames}')
	if app.frames < 3 {
		panic('gg D3D11 smoke closed before 3 frames, got ${app.frames}')
	}
	log_phase('gg D3D11 smoke completed')
}
