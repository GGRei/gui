module gui

import sokol.gfx
import sokol.sapp

struct GuiRenderTargetFormats {
	color gfx.PixelFormat
	depth gfx.PixelFormat
}

fn gui_render_target_formats() GuiRenderTargetFormats {
	defaults := sapp.glue_environment().defaults
	return GuiRenderTargetFormats{
		color: defaults.color_format
		depth: defaults.depth_format
	}
}
