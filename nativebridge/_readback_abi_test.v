module nativebridge

#include <stdlib.h>

fn C.malloc(size usize) &u8

fn test_readback_buffer_free_accepts_c_allocated_buffer() {
	$if macos || linux || windows {
		ptr := C.malloc(16)
		assert ptr != unsafe { nil }
		C.gui_readback_buffer_free(ptr)
	}
}

fn test_readback_metal_reports_unsupported_off_macos() {
	$if !macos {
		readback_metal_texture(unsafe { nil }, unsafe { nil }, 1, 1) or {
			assert err.msg().contains('not available')
			return
		}
		assert false
	}
}

fn test_readback_gl_reports_unsupported_off_linux() {
	$if !linux {
		readback_gl_framebuffer(0, 1, 1) or {
			assert err.msg().contains('not available')
			return
		}
		assert false
	}
}

fn test_readback_d3d11_reports_unsupported_off_windows() {
	$if !windows {
		readback_d3d11_texture(unsafe { nil }, unsafe { nil }, unsafe { nil }, 1, 1) or {
			assert err.msg().contains('not available')
			return
		}
		assert false
	}
}
