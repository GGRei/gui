module gui

import os

fn gui_module_source(name string) string {
	path := os.join_path(os.dir(@FILE), name)
	return os.read_file(path) or { panic(err) }
}

fn test_render_target_formats_use_sapp_glue_defaults() {
	helper := gui_module_source('sokol_formats.v')
	assert helper.contains('sapp.glue_environment().defaults')
	assert !helper.contains('PixelFormat.from(sapp.color_format())')
	assert !helper.contains('PixelFormat.from(sapp.depth_format())')
}

fn test_raster_and_filter_targets_share_render_target_format_helper() {
	for source_name in ['print_raster.v', 'shaders.v'] {
		source := gui_module_source(source_name)
		assert source.contains('gui_render_target_formats()'), source_name
		assert !source.contains('PixelFormat.from(sapp.color_format())'), source_name
		assert !source.contains('PixelFormat.from(sapp.depth_format())'), source_name
	}
}
