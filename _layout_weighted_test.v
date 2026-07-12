module gui

import os
import time

fn weighted_test_row(width f32, padding Padding, spacing f32, children []Layout) Layout {
	return Layout{
		shape:    &Shape{
			shape_type: .rectangle
			axis:       .left_to_right
			sizing:     fixed_fixed
			width:      width
			height:     100
			padding:    padding
			spacing:    spacing
		}
		children: children
	}
}

fn weighted_test_fill(weight f32) Layout {
	return Layout{
		shape: &Shape{
			shape_type:       .rectangle
			sizing:           fill_fill
			main_axis_weight: weight
		}
	}
}

fn test_weighted_row_and_column_distribution() {
	mut row := weighted_test_row(400, padding_none, 0, [
		weighted_test_fill(1),
		weighted_test_fill(1),
		weighted_test_fill(2),
	])
	layout_parents(mut row, unsafe { nil })
	layout_fill_widths(mut row)
	layout_fill_heights(mut row)
	assert f32_are_close(row.children[0].shape.width, 100)
	assert f32_are_close(row.children[1].shape.width, 100)
	assert f32_are_close(row.children[2].shape.width, 200)
	for child in row.children {
		assert f32_are_close(child.shape.height, 100)
	}

	mut column := Layout{
		shape:    &Shape{
			shape_type: .rectangle
			axis:       .top_to_bottom
			sizing:     fixed_fixed
			width:      100
			height:     400
		}
		children: [weighted_test_fill(1), weighted_test_fill(1),
			weighted_test_fill(2)]
	}
	layout_parents(mut column, unsafe { nil })
	layout_fill_widths(mut column)
	layout_fill_heights(mut column)
	for child in column.children {
		assert f32_are_close(child.shape.width, 100)
	}
	assert f32_are_close(column.children[0].shape.height, 100)
	assert f32_are_close(column.children[1].shape.height, 100)
	assert f32_are_close(column.children[2].shape.height, 200)
}

fn test_weighted_padding_spacing_implicit_fill_and_non_weighted_children() {
	mut root := weighted_test_row(400, Padding{
		left:  10
		right: 20
	}, 10, [
		weighted_test_fill(2),
		Layout{
			shape: &Shape{
				shape_type: .rectangle
				sizing:     fill_fill
			}
		},
		Layout{
			shape: &Shape{
				shape_type: .rectangle
				sizing:     fit_fill
				width:      40
			}
		},
		Layout{
			shape: &Shape{
				shape_type: .rectangle
				sizing:     fixed_fill
				width:      30
			}
		},
	])
	layout_parents(mut root, unsafe { nil })
	layout_fill_widths(mut root)
	// 400 - padding(30) - spacing(30) - fit/fixed(70) leaves 270 for 2:1.
	assert f32_are_close(root.children[0].shape.width, 180)
	assert f32_are_close(root.children[1].shape.width, 90)
	assert f32_are_close(root.children[2].shape.width, 40)
	assert f32_are_close(root.children[3].shape.width, 30)
}

fn test_weighted_min_max_clamp_and_zero_max_is_unbounded() {
	mut clamped := weighted_test_row(400, padding_none, 0, [
		Layout{
			shape: &Shape{
				shape_type:       .rectangle
				sizing:           fill_fill
				main_axis_weight: 1
				max_width:        80
			}
		},
		weighted_test_fill(1),
		weighted_test_fill(2),
	])
	layout_parents(mut clamped, unsafe { nil })
	layout_fill_widths(mut clamped)
	assert f32_are_close(clamped.children[0].shape.width, 80)
	assert f32_are_close(clamped.children[1].shape.width, f32(320) / 3)
	assert f32_are_close(clamped.children[2].shape.width, f32(640) / 3)

	mut unbounded := weighted_test_row(100, padding_none, 0, [
		Layout{
			shape: &Shape{
				shape_type:       .rectangle
				sizing:           fill_fill
				main_axis_weight: 1
				max_width:        0
			}
		},
		weighted_test_fill(1),
	])
	layout_parents(mut unbounded, unsafe { nil })
	layout_fill_widths(mut unbounded)
	assert f32_are_close(unbounded.children[0].shape.width, 50)
	assert f32_are_close(unbounded.children[1].shape.width, 50)
}

fn test_weighted_extreme_weight_recomputes_remaining_active_weight() {
	mut root := weighted_test_row(101, padding_none, 0, [
		Layout{
			shape: &Shape{
				shape_type:       .rectangle
				sizing:           fill_fill
				main_axis_weight: f32(1e20)
				max_width:        1
			}
		},
		weighted_test_fill(1),
		weighted_test_fill(1),
	])
	layout_parents(mut root, unsafe { nil })
	layout_fill_widths(mut root)

	// The dominant candidate freezes at 1. The remaining budget is 100 and the
	// two active weights are equal, regardless of precision lost in 1e20 + 1 + 1.
	assert f32_are_close(root.children[0].shape.width, 1)
	assert f32_are_close(root.children[1].shape.width, 50)
	assert f32_are_close(root.children[2].shape.width, 50)
}

fn test_weighted_unrealizable_residue_does_not_change_frozen_maximum() {
	budget := f32(1_000_000_000)
	maximum := f32(0.04)
	mut root := weighted_test_row(budget, padding_none, 0, [
		Layout{
			shape: &Shape{
				shape_type:       .rectangle
				sizing:           fill_fill
				main_axis_weight: 1
				max_width:        maximum
			}
		},
		weighted_test_fill(1),
	])
	layout_parents(mut root, unsafe { nil })
	layout_fill_widths(mut root)

	// The free candidate's ULP exceeds the residue, so exact conservation is
	// impossible without incorrectly changing the candidate frozen at max.
	assert test_f32_close_with_tolerance(root.children[0].shape.width, maximum, f32(0.000001))
	assert root.children[1].shape.width == budget
}

fn test_weighted_cascades_maximum_then_minimum_clamps() {
	mut root := weighted_test_row(300, padding_none, 0, [
		Layout{
			shape: &Shape{
				shape_type:       .rectangle
				sizing:           fill_fill
				main_axis_weight: 1
				min_width:        140
			}
		},
		Layout{
			shape: &Shape{
				shape_type:       .rectangle
				sizing:           fill_fill
				main_axis_weight: 1
				max_width:        40
			}
		},
		weighted_test_fill(1),
	])
	layout_parents(mut root, unsafe { nil })
	layout_fill_widths(mut root)

	// lambda starts at 100: the maximum freezes at 40. Recomputing with 260
	// freezes the first minimum at 140, leaving 120 for the final candidate.
	assert f32_are_close(root.children[0].shape.width, 140)
	assert f32_are_close(root.children[1].shape.width, 40)
	assert f32_are_close(root.children[2].shape.width, 120)
}

fn test_weighted_budget_residue_and_rtl_leave_sizes_unchanged() {
	mut ltr := weighted_test_row(401, padding_none, 0, [
		weighted_test_fill(1),
		weighted_test_fill(1),
		weighted_test_fill(2),
	])
	mut rtl := weighted_test_row(401, padding_none, 0, [
		weighted_test_fill(1),
		weighted_test_fill(1),
		weighted_test_fill(2),
	])
	rtl.shape.text_dir = .rtl
	layout_parents(mut ltr, unsafe { nil })
	layout_parents(mut rtl, unsafe { nil })
	layout_fill_widths(mut ltr)
	layout_fill_widths(mut rtl)

	assert f32_abs(ltr.children[0].shape.width + ltr.children[1].shape.width +
		ltr.children[2].shape.width - 401) <= f32_tolerance
	for i in 0 .. ltr.children.len {
		assert f32_are_close(ltr.children[i].shape.width, rtl.children[i].shape.width)
	}

	mut ltr_window := Window{}
	mut rtl_window := Window{}
	layout_positions(mut ltr, 0, 0, mut ltr_window)
	layout_positions(mut rtl, 0, 0, mut rtl_window)
	assert f32_are_close(ltr.children[0].shape.x, 0)
	assert f32_are_close(ltr.children[1].shape.x, ltr.children[0].shape.width)
	assert f32_are_close(rtl.children[0].shape.x, rtl.shape.width - rtl.children[0].shape.width)
	assert f32_are_close(rtl.children[2].shape.x, 0)
}

fn test_weighted_fractional_budget_assigns_residue_to_last_eligible_candidate() {
	budget := f32(100.1)
	mut root := weighted_test_row(budget, padding_none, 0, [
		weighted_test_fill(1),
		weighted_test_fill(1),
		weighted_test_fill(1),
	])
	layout_parents(mut root, unsafe { nil })
	layout_fill_widths(mut root)

	base := f32(f64(budget) / f64(3))
	expected_last := f32(f64(budget) - f64(2) * f64(base))
	assert root.children[0].shape.width == base
	assert root.children[1].shape.width == base
	assert expected_last != base
	assert root.children[2].shape.width == expected_last
	assert f32_abs(root.children[0].shape.width + root.children[1].shape.width +
		root.children[2].shape.width - budget) <= f32_tolerance
}

fn test_weighted_path_preserves_legacy_fill_distribution_without_weights() {
	mut root := weighted_test_row(100, padding_none, 5, [
		Layout{ shape: &Shape{ shape_type: .rectangle, sizing: fixed_fill, width: 20 } },
		Layout{ shape: &Shape{ shape_type: .rectangle, sizing: fill_fill } },
		Layout{ shape: &Shape{ shape_type: .rectangle, sizing: fill_fill } },
	])
	layout_parents(mut root, unsafe { nil })
	layout_fill_widths(mut root)
	assert f32_are_close(root.children[1].shape.width, 35)
	assert f32_are_close(root.children[2].shape.width, 35)
}

fn test_weighted_feature_preserves_legacy_shrink_min_max_scroll_and_over_draw() {
	mut shrink := weighted_test_row(100, padding_none, 0, [
		Layout{ shape: &Shape{ shape_type: .rectangle, sizing: fill_fill, width: 80 } },
		Layout{ shape: &Shape{ shape_type: .rectangle, sizing: fill_fill, width: 80 } },
	])
	layout_parents(mut shrink, unsafe { nil })
	layout_fill_widths(mut shrink)
	assert f32_are_close(shrink.children[0].shape.width, 50)
	assert f32_are_close(shrink.children[1].shape.width, 50)

	mut maximum := weighted_test_row(200, padding_none, 0, [
		Layout{
			shape: &Shape{
				shape_type: .rectangle
				sizing:     fill_fill
				width:      20
				max_width:  40
			}
		},
		Layout{ shape: &Shape{ shape_type: .rectangle, sizing: fill_fill, width: 20 } },
	])
	layout_parents(mut maximum, unsafe { nil })
	layout_fill_widths(mut maximum)
	assert f32_are_close(maximum.children[0].shape.width, 40)
	assert f32_are_close(maximum.children[1].shape.width, 160)

	mut minimum := weighted_test_row(80, padding_none, 0, [
		Layout{
			shape: &Shape{
				shape_type: .rectangle
				sizing:     fill_fill
				width:      100
				min_width:  70
			}
		},
		Layout{
			shape: &Shape{
				shape_type: .rectangle
				sizing:     fill_fill
				width:      100
				min_width:  10
			}
		},
	])
	layout_parents(mut minimum, unsafe { nil })
	layout_fill_widths(mut minimum)
	assert f32_are_close(minimum.children[0].shape.width, 70)
	assert f32_are_close(minimum.children[1].shape.width, 10)

	mut scroll := weighted_test_row(300, padding_none, 0, [
		Layout{
			shape: &Shape{
				shape_type: .rectangle
				sizing:     fixed_fill
				width:      100
			}
		},
		Layout{
			shape: &Shape{
				shape_type: .rectangle
				axis:       .top_to_bottom
				sizing:     fill_fill
				width:      50
				id_scroll:  91
			}
		},
	])
	layout_parents(mut scroll, unsafe { nil })
	layout_fill_widths(mut scroll)
	assert f32_are_close(scroll.children[1].shape.width, 200)

	mut over_draw := weighted_test_row(200, padding_none, 0, [
		Layout{ shape: &Shape{ shape_type: .rectangle, sizing: fill_fill } },
		Layout{ shape: &Shape{ shape_type: .rectangle, sizing: fill_fill } },
		Layout{
			shape: &Shape{
				shape_type: .rectangle
				sizing:     fixed_fill
				width:      80
				over_draw:  true
			}
		},
	])
	layout_parents(mut over_draw, unsafe { nil })
	layout_fill_widths(mut over_draw)
	// Preserve the historical legacy-path accounting of over_draw widths.
	assert f32_are_close(over_draw.children[0].shape.width, 60)
	assert f32_are_close(over_draw.children[1].shape.width, 60)
}

@[heap]
struct WeightedTestView implements View {
mut:
	content []View
}

fn (mut view WeightedTestView) generate_layout(mut window Window) Layout {
	return Layout{
		shape: &Shape{
			shape_type: .rectangle
			sizing:     fill_fill
		}
	}
}

@[heap]
struct WeightedCustomParentView implements View {
	width  f32
	height f32
mut:
	content []View
}

fn (mut view WeightedCustomParentView) generate_layout(mut _ Window) Layout {
	return Layout{
		shape: &Shape{
			id:         'weighted-custom-parent'
			shape_type: .rectangle
			axis:       .left_to_right
			sizing:     fixed_fixed
			width:      view.width
			height:     view.height
		}
	}
}

@[heap]
struct WeightedPayloadView implements View {
	id      string
	payload string
mut:
	content []View
}

fn (mut view WeightedPayloadView) generate_layout(mut _ Window) Layout {
	return Layout{
		shape: &Shape{
			id:         view.id
			resource:   view.payload
			shape_type: .rectangle
			sizing:     fill_fill
		}
	}
}

@[heap]
struct WeightedMutatingContentView implements View {
	root_id      string
	injected_id  string
	generated_id string
	payload      string
mut:
	content []View
}

const weighted_gc_rebuild_iterations = 128
const weighted_gc_payload_bytes = 64 * 1024
const weighted_gc_max_growth = usize(3 * 1024 * 1024)

fn weighted_collect_and_churn() {
	gc_collect()
	for _ in 0 .. 512 {
		unsafe {
			p := malloc(32)
			vmemset(p, 0x5a, 32)
		}
	}
	gc_collect()
}

fn (mut view WeightedMutatingContentView) generate_layout(mut _ Window) Layout {
	array_clear(mut view.content)
	view.content = [
		View(WeightedPayloadView{
			id:      view.generated_id
			payload: view.payload
		}),
	]
	return Layout{
		shape:    &Shape{
			id:         view.root_id
			shape_type: .rectangle
			sizing:     fill_fill
		}
		children: [
			Layout{
				shape: &Shape{
					id:         view.injected_id
					shape_type: .rectangle
					sizing:     fill_fill
				}
			},
		]
	}
}

fn test_weighted_wrapper_delegates_custom_view_without_extra_layout_node_and_clears() {
	mut view := weighted(WeightedCfg{
		weight: 2
		view:   WeightedTestView{
			content: [rectangle(sizing: fill_fill)]
		}
	})
	mut window := Window{}
	mut layout := generate_layout(mut view, mut window)
	assert f32_are_close(layout.shape.main_axis_weight, 2)
	assert layout.children.len == 1
	assert layout.children[0].shape.shape_type == .rectangle
	view_clear(mut view)
	assert view.content.len == 0
	layout_clear(mut layout)
}

fn test_weighted_custom_parent_uses_declared_main_axis() {
	mut view := View(WeightedCustomParentView{
		width:   300
		height:  80
		content: [
			weighted(weight: 1, view: rectangle(sizing: fill_fill)),
			weighted(weight: 2, view: rectangle(sizing: fill_fill)),
		]
	})
	mut window := Window{}
	mut layout := generate_layout(mut view, mut window)
	layout_parents(mut layout, unsafe { nil })
	layout_fill_widths(mut layout)
	assert layout.shape.id == 'weighted-custom-parent'
	assert f32_are_close(layout.children[0].shape.width, 100)
	assert f32_are_close(layout.children[1].shape.width, 200)
	view_clear(mut view)
	layout_clear(mut layout)
}

fn test_weighted_wrapper_transfers_mutated_content_and_preserves_injected_layout() {
	mut view := weighted(
		weight: 2
		view:   WeightedMutatingContentView{
			root_id:      'delegated-root'
			injected_id:  'pre-injected-layout'
			generated_id: 'generated-content'
			payload:      'lifecycle-payload'
			content:      [rectangle(id: 'stale-content', sizing: fill_fill)]
		}
	)
	mut window := Window{}
	mut layout := generate_layout(mut view, mut window)
	assert layout.shape.id == 'delegated-root'
	assert f32_are_close(layout.shape.main_axis_weight, 2)
	assert layout.children.len == 2
	assert layout.children[0].shape.id == 'pre-injected-layout'
	assert layout.children[1].shape.id == 'generated-content'
	assert layout.children[1].shape.resource == 'lifecycle-payload'
	assert view.content.len == 1
	assert view.content[0] is WeightedPayloadView
	view_clear(mut view)
	assert view.content.len == 0
	layout_clear(mut layout)
}

fn test_weighted_rebuilds_do_not_retain_decorated_views_or_content() {
	mut window := Window{}
	weighted_collect_and_churn()
	baseline := gc_memory_use()

	for i in 0 .. weighted_gc_rebuild_iterations {
		mut view := row(
			width:   100
			height:  40
			sizing:  fixed_fixed
			content: [
				weighted(
					weight: 1
					view:   WeightedMutatingContentView{
						root_id:      'gc-root'
						injected_id:  'gc-injected'
						generated_id: 'gc-generated'
						payload:      'x'.repeat(weighted_gc_payload_bytes) + i.str()
						content:      [rectangle(id: 'gc-stale', sizing: fill_fill)]
					}
				),
			]
		)
		mut layout := generate_layout(mut view, mut window)
		layout_parents(mut layout, unsafe { nil })
		layout_fill_widths(mut layout)
		assert layout.children.len == 1
		assert layout.children[0].shape.id == 'gc-root'
		assert layout.children[0].children.len == 2
		assert layout.children[0].children[1].shape.resource.len >= weighted_gc_payload_bytes
		assert view.content.len == 1
		assert view.content[0] is WeightedView
		assert view.content[0].content.len == 1
		assert view.content[0].content[0] is WeightedPayloadView
		// Reading the old zeroed []View backing as an interface would be invalid.
		// view_weighted.v's array_clear call covers that byte-level invariant
		// statically; the typed transfer above and bounded live memory cover the
		// observable ownership and retention contract without UB.
		view_clear(mut view)
		assert view.content.len == 0
		layout_clear(mut layout)
		if i % 16 == 0 {
			weighted_collect_and_churn()
		}
	}

	weighted_collect_and_churn()
	after := gc_memory_use()
	growth := if after > baseline { after - baseline } else { usize(0) }
	assert growth < weighted_gc_max_growth
}

fn test_weighted_public_text_view_keeps_ratio() {
	mut window := Window{}
	mut view := row(
		width:   400
		height:  100
		sizing:  fixed_fixed
		spacing: 0
		content: [
			weighted(weight: 1, view: text(text: 'one', min_width: 20)),
			weighted(weight: 1, view: text(text: 'two', min_width: 80)),
			weighted(weight: 2, view: text(text: 'four', min_width: 140)),
		]
	)
	mut layout := generate_layout(mut view, mut window)
	assert layout.children[0].shape.width >= 20
	assert layout.children[1].shape.width >= 80
	assert layout.children[2].shape.width >= 140
	assert layout.children[0].shape.width < layout.children[1].shape.width
	assert layout.children[1].shape.width < layout.children[2].shape.width
	layout_parents(mut layout, unsafe { nil })
	layout_fill_widths(mut layout)
	assert f32_are_close(layout.children[0].shape.width, 100), 'widths: ${layout.children[0].shape.width}, ${layout.children[1].shape.width}, ${layout.children[2].shape.width}'
	assert f32_are_close(layout.children[1].shape.width, 100), 'widths: ${layout.children[0].shape.width}, ${layout.children[1].shape.width}, ${layout.children[2].shape.width}'
	assert f32_are_close(layout.children[2].shape.width, 200), 'widths: ${layout.children[0].shape.width}, ${layout.children[1].shape.width}, ${layout.children[2].shape.width}'
}

fn test_weighted_headless_synthetic_children_do_not_participate() {
	mut layout := weighted_test_row(300, padding_none, 0, [
		// Headless stand-in for the floating title/tooltip layouts.
		Layout{
			shape: &Shape{
				id:         'title-tooltip-overlay'
				shape_type: .rectangle
				float:      true
				width:      60
			}
		},
		weighted_test_fill(1),
		weighted_test_fill(2),
		// Headless stand-ins for horizontal and vertical scrollbars.
		Layout{
			shape: &Shape{
				id:                    'horizontal-scrollbar'
				shape_type:            .rectangle
				scrollbar_orientation: .horizontal
				over_draw:             true
				width:                 12
			}
		},
		Layout{
			shape: &Shape{
				id:                    'vertical-scrollbar'
				shape_type:            .rectangle
				scrollbar_orientation: .vertical
				over_draw:             true
				width:                 12
			}
		},
	])
	layout_parents(mut layout, unsafe { nil })
	layout_fill_widths(mut layout)

	mut float_count := 0
	mut over_draw_count := 0
	mut weighted_indices := []int{}
	for i, child in layout.children {
		if child.shape.float {
			float_count++
		}
		if child.shape.over_draw {
			over_draw_count++
		}
		if child.shape.main_axis_weight > 0 {
			weighted_indices << i
		}
	}
	assert float_count == 1
	assert over_draw_count == 2
	assert weighted_indices.len == 2
	assert f32_are_close(layout.children[weighted_indices[0]].shape.width, 100)
	assert f32_are_close(layout.children[weighted_indices[1]].shape.width, 200)
	assert f32_are_close(layout.children[0].shape.width, 60)
	assert f32_are_close(layout.children[3].shape.width, 12)
	assert f32_are_close(layout.children[4].shape.width, 12)
	layout_clear(mut layout)
}

fn test_weighted_constraints_and_vertical_max_zero() {
	mut root := weighted_test_row(100, padding_none, 0, [
		Layout{
			shape: &Shape{
				shape_type:       .rectangle
				sizing:           fill_fill
				main_axis_weight: 1
				min_width:        60
			}
		},
		Layout{
			shape: &Shape{
				shape_type:       .rectangle
				sizing:           fill_fill
				main_axis_weight: 1
				max_width:        20
			}
		},
	])
	layout_parents(mut root, unsafe { nil })
	layout_fill_widths(mut root)
	assert f32_are_close(root.children[0].shape.width, 80)
	assert f32_are_close(root.children[1].shape.width, 20)
	mut column := Layout{
		shape:    &Shape{
			shape_type: .rectangle
			axis:       .top_to_bottom
			sizing:     fixed_fixed
			width:      100
			height:     80
		}
		children: [
			Layout{
				shape: &Shape{
					shape_type:       .rectangle
					sizing:           fill_fill
					main_axis_weight: 1
					max_height:       0
				}
			},
		]
	}
	layout_parents(mut column, unsafe { nil })
	layout_fill_heights(mut column)
	assert f32_are_close(column.children[0].shape.height, 80)
}

fn test_weighted_resize_nested_circle_recalculates_ratio() {
	mut root := weighted_test_row(300, padding_none, 0, [
		weighted_test_fill(1),
		Layout{
			shape:    &Shape{
				shape_type: .circle
				axis:       .top_to_bottom
				sizing:     fill_fill
			}
			children: [
				weighted_test_fill(1),
				weighted_test_fill(2),
			]
		},
	])
	layout_parents(mut root, unsafe { nil })
	layout_fill_widths(mut root)
	layout_fill_heights(mut root)
	assert f32_are_close(root.children[0].shape.width, 150)
	assert f32_are_close(root.children[1].children[0].shape.height, f32(100) / 3)
	assert f32_are_close(root.children[1].children[1].shape.height, f32(200) / 3)
	root.shape.width = 600
	layout_fill_widths(mut root)
	assert f32_are_close(root.children[0].shape.width, 300)
}

fn test_weighted_legacy_wrap_and_overflow_do_not_enter_weighted_path() {
	mut root := weighted_test_row(100, padding_none, 5, [
		Layout{ shape: &Shape{ shape_type: .rectangle, sizing: fill_fill } },
		Layout{ shape: &Shape{ shape_type: .rectangle, sizing: fill_fill } },
	])
	root.shape.wrap = true
	root.shape.overflow = true
	layout_parents(mut root, unsafe { nil })
	layout_fill_widths(mut root)
	assert f32_are_close(root.children[0].shape.width, 47.5)
	assert f32_are_close(root.children[1].shape.width, 47.5)
}

fn test_weighted_infeasible_minima_are_preserved() {
	mut root := weighted_test_row(100, padding_none, 0, [
		Layout{
			shape: &Shape{
				shape_type:       .rectangle
				sizing:           fill_fill
				main_axis_weight: 1
				min_width:        80
			}
		},
		Layout{
			shape: &Shape{
				shape_type:       .rectangle
				sizing:           fill_fill
				main_axis_weight: 1
				min_width:        80
			}
		},
	])
	layout_parents(mut root, unsafe { nil })
	layout_fill_widths(mut root)
	assert f32_are_close(root.children[0].shape.width, 80)
	assert f32_are_close(root.children[1].shape.width, 80)
}

fn test_weighted_all_maxima_saturated_leave_surplus_space() {
	mut root := weighted_test_row(400, padding_none, 0, [
		Layout{
			shape: &Shape{
				shape_type:       .rectangle
				sizing:           fill_fill
				main_axis_weight: 1
				max_width:        50
			}
		},
		Layout{
			shape: &Shape{
				shape_type:       .rectangle
				sizing:           fill_fill
				main_axis_weight: 1
				max_width:        70
			}
		},
	])
	layout_parents(mut root, unsafe { nil })
	layout_fill_widths(mut root)
	assert f32_are_close(root.children[0].shape.width, 50)
	assert f32_are_close(root.children[1].shape.width, 70)
}

fn test_weighted_contract_panics_in_subprocess() {
	token := '${os.getpid()}_${time.now().unix_micro()}'
	probe_source := os.join_path(os.dir(@FILE), '_weighted_contract_${token}_test.v')
	mut probe_binary := os.join_path(os.dir(@FILE), '_weighted_contract_${token}')
	$if windows {
		probe_binary += '.exe'
	}
	defer {
		os.rm(probe_source) or {}
		os.rm(probe_binary) or {}
	}
	os.write_file(probe_source, weighted_contract_probe) or {
		assert false, err.msg()
		return
	}
	mut prod_flag := ''
	$if prod {
		prod_flag = '-prod'
	}
	mut subsystem_flag := ''
	$if windows {
		subsystem_flag = '-subsystem console'
	}
	compile_result :=
		os.execute('${os.quoted_path(@VEXE)} ${prod_flag} ${subsystem_flag} -cc ${os.quoted_path(@CCOMPILER)} -no-parallel -no-retry-compilation -skip-running -run-only test_weighted_contract_dispatch -o ${os.quoted_path(probe_binary)} ${os.quoted_path(probe_source)}')
	assert compile_result.exit_code == 0, 'probe compile exit_code=${compile_result.exit_code} output=${compile_result.output}'
	cases := [
		['test_weighted_zero', 'gui.weighted: weight must be finite and greater than zero'],
		['test_weighted_negative', 'gui.weighted: weight must be finite and greater than zero'],
		['test_weighted_nan', 'gui.weighted: weight must be finite and greater than zero'],
		['test_weighted_inf', 'gui.weighted: weight must be finite and greater than zero'],
		['test_weighted_negative_inf', 'gui.weighted: weight must be finite and greater than zero'],
		['test_weighted_double', 'gui.weighted: a view cannot be weighted more than once'],
		['test_weighted_root', 'gui.weighted: weighted view requires a parent with a main axis'],
		['test_weighted_float', 'gui.weighted: decorated view must participate in normal layout flow'],
		['test_weighted_none', 'gui.weighted: decorated view must participate in normal layout flow'],
		['test_weighted_over_draw',
			'gui.weighted: decorated view must participate in normal layout flow'],
		['test_weighted_fixed',
			'gui.weighted: weighted child cannot use fixed sizing on its parent main axis'],
		['test_weighted_parent_none',
			'gui.weighted: weighted children require a parent with a main axis'],
		['test_weighted_wrap',
			'gui.weighted: weighted children are not supported in wrap or overflow containers'],
		['test_weighted_overflow',
			'gui.weighted: weighted children are not supported in wrap or overflow containers'],
	]
	for i, case in cases {
		result := os.execute('${os.quoted_path(probe_binary)} ${i}')
		assert result.exit_code != 0, '${case[0]} exit_code=${result.exit_code} output=${result.output}'
		assert result.output.contains(case[1]), '${case[0]} exit_code=${result.exit_code} output=${result.output}'
	}
}

const weighted_contract_probe = r'module gui

import math
import os

struct ContractProbeView implements View {
mut:
	content []View
	is_float bool
	shape_type ShapeType
	over_draw bool
	sizing Sizing
}

fn (mut view ContractProbeView) generate_layout(mut _ Window) Layout {
	return Layout{shape: &Shape{float: view.is_float, shape_type: view.shape_type, over_draw: view.over_draw, sizing: view.sizing}}
}

fn contract_layout(mut layout Layout) {
	layout_parents(mut layout, unsafe { nil })
	layout_fill_widths(mut layout)
}

fn weighted_probe(weight f32) View {
	return weighted(WeightedCfg{weight: weight, view: rectangle(sizing: fill_fill)})
}

fn weighted_probe_row(child View) Layout {
	mut window := Window{}
	mut view := row(width: 100, height: 100, sizing: fixed_fixed, content: [child])
	return generate_layout(mut view, mut window)
}

fn probe_weighted_zero() { _ = weighted_probe(0) }
fn probe_weighted_negative() { _ = weighted_probe(-1) }
fn probe_weighted_nan() { _ = weighted_probe(f32(math.nan())) }
fn probe_weighted_inf() { _ = weighted_probe(f32(math.inf(1))) }
fn probe_weighted_negative_inf() { _ = weighted_probe(f32(math.inf(-1))) }

fn probe_weighted_double() {
	_ = weighted(weight: 1, view: weighted(weight: 1, view: rectangle(sizing: fill_fill)))
}

fn probe_weighted_root() {
	mut window := Window{}
	mut view := weighted_probe(1)
	mut layout := generate_layout(mut view, mut window)
	contract_layout(mut layout)
}

fn probe_weighted_float() {
	mut layout := weighted_probe_row(weighted(WeightedCfg{weight: 1, view: ContractProbeView{is_float: true, shape_type: .rectangle, sizing: fill_fill}}))
	contract_layout(mut layout)
}

fn probe_weighted_none() {
	mut layout := weighted_probe_row(weighted(WeightedCfg{weight: 1, view: ContractProbeView{shape_type: .none, sizing: fill_fill}}))
	contract_layout(mut layout)
}

fn probe_weighted_over_draw() {
	mut layout := weighted_probe_row(weighted(WeightedCfg{weight: 1, view: ContractProbeView{over_draw: true, shape_type: .rectangle, sizing: fill_fill}}))
	contract_layout(mut layout)
}

fn probe_weighted_fixed() {
	mut layout := weighted_probe_row(weighted_probe(1))
	layout.children[0].shape.sizing = fixed_fill
	contract_layout(mut layout)
}

fn probe_weighted_parent_none() {
	mut layout := weighted_probe_row(weighted_probe(1))
	layout.shape.axis = .none
	contract_layout(mut layout)
}

fn probe_weighted_wrap() {
	mut layout := weighted_probe_row(weighted_probe(1))
	layout.shape.wrap = true
	contract_layout(mut layout)
}

fn probe_weighted_overflow() {
	mut layout := weighted_probe_row(weighted_probe(1))
	layout.shape.overflow = true
	contract_layout(mut layout)
}

fn test_weighted_contract_dispatch() {
	if os.args.len < 2 {
		exit(90)
	}
	match os.args[1].int() {
		0 { probe_weighted_zero() }
		1 { probe_weighted_negative() }
		2 { probe_weighted_nan() }
		3 { probe_weighted_inf() }
		4 { probe_weighted_negative_inf() }
		5 { probe_weighted_double() }
		6 { probe_weighted_root() }
		7 { probe_weighted_float() }
		8 { probe_weighted_none() }
		9 { probe_weighted_over_draw() }
		10 { probe_weighted_fixed() }
		11 { probe_weighted_parent_none() }
		12 { probe_weighted_wrap() }
		13 { probe_weighted_overflow() }
		else { exit(91) }
	}
}
'
