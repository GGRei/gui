module main

import os

fn main() {
	println('mingw console smoke main started')
	println('cwd: ${os.getwd()}')
	println('args: ${os.args.len}')
	println('mingw console smoke completed')
}
