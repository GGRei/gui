module gui

import math

const weighted_invalid_weight_error = 'gui.weighted: weight must be finite and greater than zero'
const weighted_duplicate_error = 'gui.weighted: a view cannot be weighted more than once'
const weighted_invalid_state_error = 'gui.weighted: internal wrapper must contain exactly one view'
const weighted_missing_shape_error = 'gui.weighted: decorated view generated a layout without a shape'
const weighted_non_flow_error = 'gui.weighted: decorated view must participate in normal layout flow'

// WeightedCfg decorates one view with its share of a parent's main-axis space.
pub struct WeightedCfg {
pub:
	weight f32
	view   View @[required]
}

@[heap; minify]
struct WeightedView implements View {
	weight f32
mut:
	// Before generation this owns the decorated view at index 0. Afterwards it
	// owns that view's generated content for the generic View traversal.
	content []View
}

// weighted assigns a positive, finite main-axis weight to a view.
pub fn weighted(cfg WeightedCfg) View {
	if cfg.weight <= 0 || math.is_nan(cfg.weight) || math.is_inf(cfg.weight, 0) {
		panic(weighted_invalid_weight_error)
	}
	if cfg.view is WeightedView {
		panic(weighted_duplicate_error)
	}
	return WeightedView{
		weight:  cfg.weight
		content: [cfg.view]
	}
}

fn (mut wv WeightedView) generate_layout(mut window Window) Layout {
	if wv.content.len != 1 {
		panic(weighted_invalid_state_error)
	}

	mut decorated := wv.content[0]
	mut layout := decorated.generate_layout(mut window)

	// Transfer the generated content without cloning it. The decorated view
	// relinquishes the array header; its backing is now owned by this wrapper.
	decorated_content := decorated.content
	decorated.content = []View{}

	// Zero the temporary interface slot before exposing the delegated content
	// to the outer generic generate_layout traversal.
	array_clear(mut wv.content)
	wv.content = decorated_content

	if isnil(layout.shape) {
		panic(weighted_missing_shape_error)
	}
	if layout.shape.float || layout.shape.shape_type == .none || layout.shape.over_draw {
		panic(weighted_non_flow_error)
	}
	if layout.shape.main_axis_weight != 0 {
		panic(weighted_duplicate_error)
	}

	layout.shape.main_axis_weight = wv.weight
	return layout
}
