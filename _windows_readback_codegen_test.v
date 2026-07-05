module gui

import os
import time

const windows_readback_codegen_prefix = 'gui_windows_readback_codegen_'

fn windows_readback_codegen_temp_dir() !string {
	base := os.temp_dir()
	name := '${windows_readback_codegen_prefix}${os.getpid()}_${time.now().unix_micro()}'
	path := os.join_path(base, name)
	os.mkdir_all(path)!
	return path
}

fn windows_readback_codegen_compile_printing(tmp_dir string, output_name string, extra_flags []string) !string {
	example_path := os.join_path(os.dir(@FILE), 'examples', 'printing.v')
	output_path := os.join_path(tmp_dir, output_name)
	mut args := [
		os.quoted_path(@VEXE),
		'-keepc',
		'-no-parallel',
		'-cc',
		'msvc',
	]
	args << extra_flags
	args << [
		'-o',
		os.quoted_path(output_path),
		os.quoted_path(example_path),
	]
	result := os.execute(args.join(' '))
	if result.exit_code != 0 {
		return error(result.output)
	}
	c_path := os.join_path(tmp_dir, 'vtmp', '${output_name}.tmp.c')
	return os.read_file(c_path)!
}

fn test_windows_printing_export_codegen_routes_readback_by_backend() {
	$if !windows {
		return
	}
	tmp_dir := windows_readback_codegen_temp_dir() or {
		assert false, err.msg()
		return
	}
	old_vtmp := os.getenv('VTMP')
	os.setenv('VTMP', os.join_path(tmp_dir, 'vtmp'), true)
	defer {
		if old_vtmp == '' {
			os.unsetenv('VTMP')
		} else {
			os.setenv('VTMP', old_vtmp, true)
		}
		os.rmdir_all(tmp_dir) or {}
	}

	default_c := windows_readback_codegen_compile_printing(tmp_dir, 'printing_default.exe', []) or {
		assert false, err.msg()
		return
	}
	assert default_c.contains('raster PDF export is not supported on Windows OpenGL yet')
	assert !default_c.contains('sg_d3d11_query_image_info')

	d3d11_c := windows_readback_codegen_compile_printing(tmp_dir, 'printing_d3d11.exe', [
		'-d',
		'sokol_d3d11',
	]) or {
		assert false, err.msg()
		return
	}
	assert d3d11_c.contains('sg_d3d11_query_image_info')
	assert d3d11_c.contains('readback_d3d11_texture')
	assert !d3d11_c.contains('raster PDF export is not supported on Windows OpenGL yet')
}
