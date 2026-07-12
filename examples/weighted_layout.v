module main

import gui

fn main_view(window &gui.Window) gui.View {
	width, height := window.window_size()
	return gui.row(
		width:   width
		height:  height
		sizing:  gui.fixed_fixed
		content: [
			gui.weighted(
				weight: 1
				view:   gui.button(content: [gui.text(text: '25% - first share')])
			),
			gui.weighted(
				weight: 1
				view:   gui.button(content: [gui.text(text: '25% - second share')])
			),
			gui.weighted(
				weight: 2
				view:   gui.button(content: [gui.text(text: '50% - double share')])
			),
		]
	)
}

fn main() {
	mut window := gui.window(
		width:   900
		height:  280
		title:   'Resizable weighted layout 1:1:2'
		on_init: fn (mut w gui.Window) {
			w.update_view(main_view)
		}
	)
	window.run()
}
