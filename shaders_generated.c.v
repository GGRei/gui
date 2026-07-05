module gui

import sokol.gfx

#include "@VMODROOT/shaders/gui_builtin.h"

fn C.gui_rounded_rect_shader_desc(gfx.Backend) &gfx.ShaderDesc
fn C.gui_shadow_shader_desc(gfx.Backend) &gfx.ShaderDesc
fn C.gui_blur_shader_desc(gfx.Backend) &gfx.ShaderDesc
fn C.gui_gradient_shader_desc(gfx.Backend) &gfx.ShaderDesc
fn C.gui_image_clip_shader_desc(gfx.Backend) &gfx.ShaderDesc
fn C.gui_filter_blur_h_shader_desc(gfx.Backend) &gfx.ShaderDesc
fn C.gui_filter_blur_v_shader_desc(gfx.Backend) &gfx.ShaderDesc
fn C.gui_filter_color_shader_desc(gfx.Backend) &gfx.ShaderDesc
fn C.gui_filter_texture_shader_desc(gfx.Backend) &gfx.ShaderDesc
