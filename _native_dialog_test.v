module gui

import nativebridge

fn test_nativebridge_module_loads() {
	_ = nativebridge.BridgeDialogStatus.ok
}

fn test_native_extensions_from_filters_normalizes_and_dedupes() {
	extensions := native_extensions_from_filters([
		NativeFileFilter{
			extensions: ['.PNG', ' jpg ', '', 'png']
		},
		NativeFileFilter{
			extensions: ['txt', 'TXT']
		},
	]) or { panic(err.msg()) }
	assert extensions == ['png', 'jpg', 'txt']
}

fn test_native_normalize_extension_rejects_invalid_chars() {
	_ := native_normalize_extension('tar.gz') or {
		assert err.msg().contains('invalid extension')
		return
	}
	assert false
}

fn test_native_save_extensions_appends_default_once() {
	extensions := native_save_extensions([
		NativeFileFilter{
			extensions: ['jpg', '.JPG']
		},
	], '.png') or { panic(err.msg()) }
	assert extensions == ['jpg', 'png']
}

fn test_native_result_from_bridge_ex_maps_ok_paths_without_native_ui() {
	mut w := Window{}
	result := native_result_from_bridge_ex(nativebridge.BridgeDialogResultEx{
		status:  .ok
		entries: [
			nativebridge.BridgeBookmarkEntry{
				path: 'C:/tmp/example.txt'
			},
		]
	}, mut w)

	assert result.status == .ok
	assert result.paths.len == 1
	assert result.paths[0].path == 'C:/tmp/example.txt'
	assert result.error_code == ''
	assert result.error_message == ''
}

fn test_native_result_from_bridge_ex_maps_cancel_without_native_ui() {
	mut w := Window{}
	result := native_result_from_bridge_ex(nativebridge.BridgeDialogResultEx{
		status: .cancel
	}, mut w)

	assert result.status == .cancel
	assert result.paths.len == 0
	assert result.error_code == ''
	assert result.error_message == ''
}

$if !(macos || linux || windows) {
	fn test_nativebridge_stub_returns_unsupported() {
		open_result := nativebridge.open_dialog(nativebridge.BridgeOpenCfg{})
		assert open_result.status == .error
		assert open_result.error_code == 'unsupported'

		save_result := nativebridge.save_dialog(nativebridge.BridgeSaveCfg{})
		assert save_result.status == .error
		assert save_result.error_code == 'unsupported'

		folder_result := nativebridge.folder_dialog(nativebridge.BridgeFolderCfg{})
		assert folder_result.status == .error
		assert folder_result.error_code == 'unsupported'
	}
}
