module nativebridge

$if linux {
	#flag linux -DGUI_PORTAL_TESTING
	#include "@VMODROOT/nativebridge/portal_linux_test.h"

	fn C.gui_portal_test_build_handle_path_equals(&char, &char, &char) int
	fn C.gui_portal_test_build_handle_path_rejects_empty_sender() int
	fn C.gui_portal_test_parse_reply_handle_equals(&char, &char) int
	fn C.gui_portal_test_parse_reply_handle_rejects_empty_reply() int
	fn C.gui_portal_test_parse_reply_handle_rejects_string() int
}

fn test_linux_filter_arg_builds_patterns() {
	filter := linux_filter_arg(['png', ' jpg ', '', 'txt'])
	assert filter == '*.png *.jpg *.txt'
}

fn test_linux_kdialog_filter_arg_builds_pattern() {
	filter := linux_kdialog_filter_arg(['png', 'jpg'])
	assert filter == '*.png *.jpg | Files'
}

fn test_linux_media_from_size_matches_orientation() {
	assert linux_media_from_size(595, 842) == 'A4'
	assert linux_media_from_size(842, 595) == 'A4'
	assert linux_media_from_size(612, 792) == 'Letter'
}

fn test_linux_dialog_result_from_command_cancel_on_empty_stderr() {
	result := linux_dialog_result_from_command(LinuxCommandResult{
		exit_code: 1
	})
	assert result.status == .cancel
}

fn test_linux_dialog_result_from_command_error_with_stderr() {
	result := linux_dialog_result_from_command(LinuxCommandResult{
		exit_code: 1
		stderr:    'cannot open display'
	})
	assert result.status == .error
	assert result.error_code == 'internal'
	assert result.error_message.contains('cannot open display')
}

fn test_linux_parse_lpstat_default_extracts_destination() {
	name := linux_parse_lpstat_default('system default destination: Office_Printer\n')
	assert name == 'Office_Printer'
}

fn test_linux_parse_lpstat_default_rejects_no_default_line() {
	name := linux_parse_lpstat_default('no system default destination\n')
	assert name == ''
}

fn test_linux_parse_lpstat_available_extracts_first_queue() {
	name :=
		linux_parse_lpstat_available('Office_Printer accepting requests since Thu 01 Jan 1970\nTest_Printer accepting requests\n')
	assert name == 'Office_Printer'
}

fn test_linux_print_capability_warnings_include_requested_options() {
	warnings := linux_print_capability_warnings(BridgePrintCfg{
		copies:      2
		page_ranges: '1-3'
		duplex_mode: 2
		color_mode:  2
		scale_mode:  1
	})
	assert warnings.len >= 5
}

fn test_portal_handle_path_removes_unique_name_leading_colon() {
	$if linux {
		assert C.gui_portal_test_build_handle_path_equals(c':1.244', c'gui_1783082018_0',
			c'/org/freedesktop/portal/desktop/request/1_244/gui_1783082018_0') == 1
	}
}

fn test_portal_handle_path_sanitizes_dots_without_extra_prefix() {
	$if linux {
		assert C.gui_portal_test_build_handle_path_equals(c'1.244', c'gui_token',
			c'/org/freedesktop/portal/desktop/request/1_244/gui_token') == 1
	}
}

fn test_portal_handle_path_rejects_empty_sender() {
	$if linux {
		assert C.gui_portal_test_build_handle_path_rejects_empty_sender() == 1
	}
}

fn test_portal_reply_handle_parses_object_path() {
	$if linux {
		handle := '/org/freedesktop/portal/desktop/request/1_244/gui_token'
		assert C.gui_portal_test_parse_reply_handle_equals(handle.str, handle.str) == 1
	}
}

fn test_portal_reply_handle_rejects_missing_or_wrong_type() {
	$if linux {
		assert C.gui_portal_test_parse_reply_handle_rejects_empty_reply() == 1
		assert C.gui_portal_test_parse_reply_handle_rejects_string() == 1
	}
}
