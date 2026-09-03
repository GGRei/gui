module main

import os

const max_compare_file_size = u64(8 * 1024 * 1024)

struct VerifyConfig {
	log_path          string
	output            string
	generation        string
	mode              string
	profile           string
	lane              string
	cc                string
	cxx               string
	report_path       string
	normalized_output string
	normalized_cc     string
	normalized_cxx    string
}

struct ResponseHeader {
	matched bool
	path    string
	key     string
}

struct ParsedCommand {
	line_index int
	tokens     []string
mut:
	has_response    bool
	response_path   string
	response_tokens []string
}

struct Verification {
	report string
	errors []string
}

struct CompareChildResult {
	exit_code int
	stdout    string
	stderr    string
}

fn bytes_equal(left []u8, right []u8) bool {
	if left.len != right.len {
		return false
	}
	for index in 0 .. left.len {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}

fn same_file_identity(left os.Stat, right os.Stat) bool {
	// Reading may update atime. Every other stable identity and content field is
	// required to remain unchanged across lstat/open/read/lstat.
	return left.dev == right.dev && left.inode == right.inode && left.mode == right.mode
		&& left.nlink == right.nlink && left.uid == right.uid && left.gid == right.gid
		&& left.rdev == right.rdev && left.size == right.size && left.mtime == right.mtime
		&& left.ctime == right.ctime
}

fn read_open_file_bounded(path string, ordinal int, expected_size int) ![]u8 {
	mut file := os.open(path) or {
		return error('compare-files input ${ordinal} open failed')
	}
	defer {
		file.close()
	}
	mut content := []u8{len: expected_size + 1}
	mut content_len := 0
	for content_len < content.len {
		read_count := file.read(mut content[content_len..]) or {
			if err is os.Eof {
				break
			}
			return error('compare-files input ${ordinal} read failed')
		}
		if read_count <= 0 {
			return error('compare-files input ${ordinal} returned an invalid read length')
		}
		content_len += read_count
	}
	if content_len != expected_size {
		return error('compare-files input ${ordinal} changed size while being read')
	}
	return content[..content_len].clone()
}

fn read_compare_file(path string, ordinal int) ![]u8 {
	if path == '' {
		return error('compare-files input ${ordinal} is not a regular non-link file')
	}
	before := os.lstat(path) or {
		return error('compare-files input ${ordinal} metadata read failed')
	}
	if before.get_filetype() != .regular || os.is_link(path) {
		return error('compare-files input ${ordinal} is not a regular non-link file')
	}
	if before.size > max_compare_file_size {
		return error('compare-files input ${ordinal} exceeds 8388608 bytes')
	}
	first_content := read_open_file_bounded(path, ordinal, int(before.size))!
	after_first_read := os.lstat(path) or {
		return error('compare-files input ${ordinal} metadata re-read failed')
	}
	if after_first_read.get_filetype() != .regular || os.is_link(path)
		|| !same_file_identity(before, after_first_read) {
		return error('compare-files input ${ordinal} changed identity while being read')
	}
	second_content := read_open_file_bounded(path, ordinal, int(before.size))!
	after_second_read := os.lstat(path) or {
		return error('compare-files input ${ordinal} metadata re-read failed')
	}
	if after_second_read.get_filetype() != .regular || os.is_link(path)
		|| !same_file_identity(before, after_second_read) {
		return error('compare-files input ${ordinal} changed identity while being read')
	}
	if !bytes_equal(first_content, second_content) {
		return error('compare-files input ${ordinal} changed content while being read')
	}
	return first_content
}

fn compare_files_cli(arguments []string) int {
	if arguments.len < 2 || arguments.len % 2 != 0 {
		eprintln('usage: verify_final_link compare-files <left> <right> [<left> <right> ...]')
		return 2
	}
	for pair_start := 0; pair_start < arguments.len; pair_start += 2 {
		pair_number := pair_start / 2 + 1
		left := read_compare_file(arguments[pair_start], pair_number * 2 - 1) or {
			eprintln(err.msg())
			return 2
		}
		right := read_compare_file(arguments[pair_start + 1], pair_number * 2) or {
			eprintln(err.msg())
			return 2
		}
		if !bytes_equal(left, right) {
			eprintln('compare-files pair ${pair_number} differs')
			return 1
		}
	}
	return 0
}

fn append_replacement(mut output []u8) {
	output << u8(0xef)
	output << u8(0xbf)
	output << u8(0xbd)
}

fn is_continuation(value u8) bool {
	return value & u8(0xc0) == u8(0x80)
}

// decode_utf8_replace follows the maximal-subpart replacement behavior used
// by the reference UTF-8 decoder with replacement enabled. The parser only interprets
// ASCII syntax after this conversion; valid non-ASCII text remains untouched.
fn decode_utf8_replace(input []u8) string {
	mut output := []u8{cap: input.len}
	mut index := 0
	for index < input.len {
		first := input[index]
		if first < u8(0x80) {
			output << first
			index++
			continue
		}
		if first < u8(0xc2) || first > u8(0xf4) {
			append_replacement(mut output)
			index++
			continue
		}
		width := if first < u8(0xe0) {
			2
		} else if first < u8(0xf0) {
			3
		} else {
			4
		}
		if index + 1 >= input.len {
			append_replacement(mut output)
			index++
			continue
		}
		second := input[index + 1]
		if !is_continuation(second) || (first == u8(0xe0) && second < u8(0xa0))
			|| (first == u8(0xed) && second >= u8(0xa0))
			|| (first == u8(0xf0) && second < u8(0x90))
			|| (first == u8(0xf4) && second > u8(0x8f)) {
			append_replacement(mut output)
			index++
			continue
		}
		if width == 2 {
			output << first
			output << second
			index += 2
			continue
		}
		if index + 2 >= input.len {
			append_replacement(mut output)
			index += 2
			continue
		}
		third := input[index + 2]
		if !is_continuation(third) {
			append_replacement(mut output)
			index += 2
			continue
		}
		if width == 3 {
			output << first
			output << second
			output << third
			index += 3
			continue
		}
		if index + 3 >= input.len {
			append_replacement(mut output)
			index += 3
			continue
		}
		fourth := input[index + 3]
		if !is_continuation(fourth) {
			append_replacement(mut output)
			index += 3
			continue
		}
		output << first
		output << second
		output << third
		output << fourth
		index += 4
	}
	return output.bytestr()
}

fn split_lines(text string) []string {
	mut lines := []string{}
	mut start := 0
	mut index := 0
	for index < text.len {
		mut separator_size := 0
		value := text[index]
		if value == `\r` {
			separator_size = if index + 1 < text.len && text[index + 1] == `\n` { 2 } else { 1 }
		} else if value == `\n` || value == u8(0x0b) || value == u8(0x0c)
			|| value == u8(0x1c) || value == u8(0x1d) || value == u8(0x1e) {
			separator_size = 1
		} else if value == u8(0xc2) && index + 1 < text.len
			&& text[index + 1] == u8(0x85) {
			separator_size = 2
		} else if value == u8(0xe2) && index + 2 < text.len
			&& text[index + 1] == u8(0x80)
			&& (text[index + 2] == u8(0xa8) || text[index + 2] == u8(0xa9)) {
			separator_size = 3
		}
		if separator_size == 0 {
			index++
			continue
		}
		lines << text[start..index]
		index += separator_size
		start = index
	}
	if start < text.len {
		lines << text[start..]
	}
	return lines
}

fn is_word_space(value u8) bool {
	return value == ` ` || value == `\t` || value == `\r` || value == `\n`
}

fn split_words(text string) ![]string {
	mut result := []string{}
	mut token := []u8{}
	mut quote := u8(0)
	mut started := false
	mut index := 0
	for index < text.len {
		value := text[index]
		if quote == u8(0) && is_word_space(value) {
			if started {
				result << token.bytestr()
				token = []u8{}
				started = false
			}
			index++
			continue
		}
		if value == `'` || value == `"` {
			if quote == u8(0) {
				quote = value
				started = true
				index++
				continue
			}
			if quote == value {
				quote = u8(0)
				index++
				continue
			}
		}
		if value == `\\` && quote != `'` && index + 1 < text.len {
			next := text[index + 1]
			escapable := if quote == `"` {
				next == `"` || next == `\\`
			} else {
				is_word_space(next) || next == `'` || next == `"` || next == `\\`
			}
			if escapable {
				token << next
				started = true
				index += 2
				continue
			}
		}
		token << value
		started = true
		index++
	}
	if quote != u8(0) {
		return error('unterminated quote in showcc text')
	}
	if started {
		result << token.bytestr()
	}
	return result
}

// All paths compared by this workflow are controlled GitHub/MSYS paths. Reject
// non-ASCII or control bytes before normalization so ASCII lowercasing is
// exactly equivalent to Unicode case folding on the accepted ASCII domain.
fn lexical_path(path string) !string {
	mut normalized := []u8{cap: path.len}
	mut previous_slash := false
	for index in 0 .. path.len {
		value := path[index]
		if value < u8(0x20) || value == u8(0x7f) || value >= u8(0x80) {
			return error('non-ASCII or control byte in lexical path')
		}
		mut output := value
		if output == `\\` {
			output = `/`
		}
		if output >= `A` && output <= `Z` {
			output += u8(32)
		}
		if output == `/` {
			if previous_slash {
				continue
			}
			previous_slash = true
		} else {
			previous_slash = false
		}
		normalized << output
	}
	mut end := normalized.len
	for end > 0 && normalized[end - 1] == `/` {
		end--
	}
	return normalized[..end].bytestr()
}

fn token_count(tokens []string, expected string) int {
	mut count := 0
	for token in tokens {
		if token == expected {
			count++
		}
	}
	return count
}

fn has_token(tokens []string, expected string) bool {
	return token_count(tokens, expected) > 0
}

fn define_count(tokens []string, macro string) !int {
	combined := '-D' + macro
	mut count := token_count(tokens, combined)
	for token in tokens {
		if token.starts_with(combined + '=') {
			return error('assigned value is not allowed for -D${macro}')
		}
	}
	for index, token in tokens {
		if token != '-D' {
			continue
		}
		if index + 1 >= tokens.len {
			return error('dangling -D in final invocation')
		}
		operand := tokens[index + 1]
		if operand.starts_with(macro + '=') {
			return error('assigned value is not allowed for -D ${macro}')
		}
		if operand == macro {
			count++
		}
	}
	return count
}

fn response_header(line string, line_number int, marker string) !ResponseHeader {
	if !line.starts_with(marker) {
		return ResponseHeader{}
	}
	prefix := marker + ' "'
	if !line.starts_with(prefix) || !line.ends_with('":') {
		return error('malformed response-file header at line ${line_number}')
	}
	path := line[prefix.len..line.len - 2]
	if path == '' || path.contains('"') {
		return error('malformed response-file path at line ${line_number}')
	}
	key := lexical_path(path) or {
		return error('${err.msg()} at line ${line_number}')
	}
	return ResponseHeader{
		matched: true
		path: path
		key: key
	}
}

fn is_v1_response_terminator(line string, command_prefix string, response_marker string) bool {
	return line.starts_with(command_prefix) || line.starts_with(response_marker)
		|| line.starts_with('case:') || line.starts_with('phase:')
		|| line.starts_with('required:') || line.starts_with('timeout_seconds:')
		|| line.starts_with('command:') || line.starts_with('exit_code:')
		|| line.starts_with('========')
}

fn validate_config(arguments []string) !VerifyConfig {
	if arguments.len != 10 {
		return error('usage: verify_final_link.v <log> <output> <v1|v3> <dynamic|static> <dev|s2|s3> <lane> <cc> <cxx> <report>')
	}
	generation := arguments[3]
	mode := arguments[4]
	profile := arguments[5]
	lane := arguments[6]
	if generation != 'v1' && generation != 'v3' {
		return error('unsupported compiler generation: ${generation}')
	}
	if mode != 'dynamic' && mode != 'static' {
		return error('unsupported link mode: ${mode}')
	}
	if profile != 'dev' && profile != 's2' && profile != 's3' {
		return error('unsupported build profile: ${profile}')
	}
	if lane != 'ucrt64-gcc' && lane != 'ucrt64-clang' && lane != 'clang64-clang'
		&& lane != 'mingw64-gcc' {
		return error('unsupported toolchain lane: ${lane}')
	}
	normalized_output := lexical_path(arguments[2]) or { return error(err.msg()) }
	normalized_cc := lexical_path(arguments[7]) or { return error(err.msg()) }
	normalized_cxx := lexical_path(arguments[8]) or { return error(err.msg()) }
	return VerifyConfig{
		log_path: arguments[1]
		output: arguments[2]
		generation: generation
		mode: mode
		profile: profile
		lane: lane
		cc: arguments[7]
		cxx: arguments[8]
		report_path: arguments[9]
		normalized_output: normalized_output
		normalized_cc: normalized_cc
		normalized_cxx: normalized_cxx
	}
}

fn expected_lld_count(config VerifyConfig) int {
	if config.generation == 'v3' && config.profile == 's3' && config.lane == 'ucrt64-clang' {
		return 1
	}
	return 0
}

fn verify_content(content string, config VerifyConfig) !Verification {
	command_prefix := if config.generation == 'v1' { '> C compiler cmd: ' } else { '  > ' }
	response_marker := if config.generation == 'v1' {
		'> C compiler response file'
	} else {
		'  > C++ linker response file'
	}
	lines := split_lines(content)
	mut commands := []ParsedCommand{}
	mut seen_response_paths := map[string]bool{}
	mut index := 0
	for index < lines.len {
		line := lines[index]
		line_number := index + 1
		header := response_header(line, line_number, response_marker) or {
			return error(err.msg())
		}
		if header.matched {
			if commands.len == 0 || commands[commands.len - 1].line_index != index - 1 {
				return error('orphan response-file block at line ${line_number}')
			}
			if header.key in seen_response_paths {
				return error('duplicate response-file block at line ${line_number}')
			}
			last_index := commands.len - 1
			mut command := commands[last_index]
			if command.has_response {
				return error('duplicate response-file block at line ${line_number}')
			}
			mut response_tokens := []string{}
			if config.generation == 'v1' {
				index++
				if index >= lines.len {
					return error('truncated response-file block at line ${line_number}')
				}
				response_content := lines[index]
				if is_v1_response_terminator(response_content, command_prefix, response_marker) {
					return error('truncated response-file block at line ${line_number}')
				}
				response_tokens = split_words(response_content) or {
					return error('malformed response-file content at line ${index + 1}: ${err.msg()}')
				}
				if response_tokens.len == 0 {
					return error('empty response-file block at line ${line_number}')
				}
			} else {
				index++
				for index < lines.len && lines[index].starts_with('"') {
					response_content := lines[index]
					if !response_content.ends_with('"') {
						return error('malformed response-file argument at line ${index + 1}')
					}
					parsed := split_words(response_content) or {
						return error('malformed response-file argument at line ${index + 1}: ${err.msg()}')
					}
					if parsed.len != 1 {
						return error('expected one response-file argument at line ${index + 1}')
					}
					response_tokens << parsed
					index++
				}
				if response_tokens.len == 0 {
					return error('truncated response-file block at line ${line_number}')
				}
				index--
			}
			seen_response_paths[header.key] = true
			command.has_response = true
			command.response_path = header.path
			command.response_tokens = response_tokens
			commands[last_index] = command
		} else if line.starts_with(command_prefix) {
			text := line[command_prefix.len..]
			tokens := split_words(text) or {
				return error('malformed showcc command at line ${line_number}: ${err.msg()}')
			}
			if tokens.len == 0 {
				return error('empty showcc command at line ${line_number}')
			}
			commands << ParsedCommand{
				line_index: index
				tokens: tokens
			}
		}
		index++
	}
	if commands.len == 0 {
		return error('no ${config.generation} showcc commands found')
	}

	mut expanded_commands := [][]string{}
	for command in commands {
		mut tokens := command.tokens.clone()
		mut response_indexes := []int{}
		for position, token in tokens {
			if token.starts_with('@') {
				response_indexes << position
			}
		}
		if response_indexes.len > 1 {
			return error('expected at most one response file per linker invocation')
		}
		if response_indexes.len == 1 {
			if !command.has_response {
				return error('showcc invocation references a response file without a log block')
			}
			response_index := response_indexes[0]
			response_token := tokens[response_index]
			if response_token.len <= 1 {
				return error('response-file command/header path mismatch')
			}
			response_key := lexical_path(response_token[1..]) or { return error(err.msg()) }
			header_key := lexical_path(command.response_path) or { return error(err.msg()) }
			if response_key != header_key {
				return error('response-file command/header path mismatch')
			}
			for response_token_item in command.response_tokens {
				if response_token_item.starts_with('@') {
					return error('nested response files are not allowed')
				}
			}
			mut expanded := []string{cap: tokens.len + command.response_tokens.len - 1}
			for before in 0 .. response_index {
				expanded << tokens[before]
			}
			expanded << command.response_tokens
			for after in response_index + 1 .. tokens.len {
				expanded << tokens[after]
			}
			tokens = expanded
		} else if command.has_response {
			return error('response-file log block has no matching command reference')
		}
		for token in tokens {
			if token.starts_with('@') {
				return error('unexpanded response-file reference')
			}
		}
		expanded_commands << tokens
	}

	for tokens in expanded_commands {
		if has_token(tokens, '-c') {
			for token_index in 1 .. tokens.len {
				if tokens[token_index] == '-fuse-ld=lld' {
					return error('LLD selection flag leaked into a compile-only command')
				}
			}
		}
	}

	expected_output := if config.generation == 'v1' { config.normalized_output } else { 'out' }
	mut candidates := [][]string{}
	for tokens in expanded_commands {
		mut output_indexes := []int{}
		for position, token in tokens {
			if token == '-o' {
				output_indexes << position
			}
		}
		if output_indexes.len != 1 {
			return error('expected exactly one -o operand in showcc command, found ${output_indexes.len}')
		}
		output_index := output_indexes[0]
		if output_index + 1 >= tokens.len {
			return error('missing operand after -o in showcc command')
		}
		observed_output := lexical_path(tokens[output_index + 1]) or { return error(err.msg()) }
		if observed_output == expected_output && !has_token(tokens, '-c') {
			candidates << tokens
		}
	}
	if candidates.len != 1 {
		return error('expected exactly one final invocation, found ${candidates.len}')
	}

	argv := candidates[0]
	expected_lld := expected_lld_count(config)
	observed_lld_count := token_count(argv, '-fuse-ld=lld')
	if observed_lld_count != expected_lld {
		return error('LLD selection cardinality mismatch: ${observed_lld_count}')
	}
	driver := lexical_path(argv[0]) or { return error(err.msg()) }
	expected_driver := if config.mode == 'static' { config.normalized_cxx } else { config.normalized_cc }
	mut errors := []string{}
	if config.mode == 'static' {
		if token_count(argv, '-static') != 1 {
			errors << '-static cardinality'
		}
		if token_count(argv, '-liconv') != 1 {
			errors << '-liconv cardinality'
		}
		for macro in ['GLIB_STATIC_COMPILATION', 'GOBJECT_STATIC_COMPILATION'] {
			count := define_count(argv, macro) or { return error(err.msg()) }
			if count != 1 {
				errors << '-D${macro} cardinality'
			}
		}
		if token_count(argv, '-lintl') < 1 {
			errors << 'missing -lintl'
		}
		mut last_lintl := -1
		mut first_liconv := -1
		for token_index, token in argv {
			if token == '-lintl' {
				last_lintl = token_index
			}
			if token == '-liconv' && first_liconv < 0 {
				first_liconv = token_index
			}
		}
		if last_lintl >= 0 && first_liconv >= 0 && first_liconv <= last_lintl {
			errors << '-liconv order'
		}
		if driver != expected_driver {
			errors << 'not expected C++ driver'
		}
	} else {
		for token in ['-static', '-liconv'] {
			if token_count(argv, token) > 0 {
				errors << 'unexpected ${token}'
			}
		}
		for macro in ['GLIB_STATIC_COMPILATION', 'GOBJECT_STATIC_COMPILATION'] {
			count := define_count(argv, macro) or { return error(err.msg()) }
			if count > 0 {
				errors << 'unexpected -D${macro}'
			}
		}
		if driver != expected_driver {
			errors << 'not expected C driver'
		}
	}
	report := 'generation=${config.generation}\n' + 'profile=${config.profile}\n' + 'lane=${config.lane}\n'
		+ 'requested_output=${config.normalized_output}\n' + 'driver=${driver}\n'
		+ 'argv=${argv.join('\t')}\n' + 'errors=${errors.join(',')}\n'
	return Verification{
		report: report
		errors: errors
	}
}

fn verify_cli(arguments []string) int {
	config := validate_config(arguments) or {
		eprintln(err.msg())
		return 1
	}
	raw_log := os.read_bytes(config.log_path) or {
		eprintln('failed to read final-link log')
		return 1
	}
	verification := verify_content(decode_utf8_replace(raw_log), config) or {
		eprintln(err.msg())
		return 1
	}
	os.write_file(config.report_path, verification.report) or {
		eprintln('failed to write final-link report')
		return 1
	}
	if verification.errors.len > 0 {
		eprintln(verification.errors.join('; '))
		return 1
	}
	return 0
}

fn self_expect(condition bool, message string) ! {
	if !condition {
		return error('selftest failed: ${message}')
	}
}

fn words_fail(text string, expected string) bool {
	split_words(text) or { return err.msg().contains(expected) }
	return false
}

fn lexical_fail(text string) bool {
	lexical_path(text) or { return err.msg() == 'non-ASCII or control byte in lexical path' }
	return false
}

fn verify_fail(content string, config VerifyConfig, expected string) bool {
	verify_content(content, config) or { return err.msg().contains(expected) }
	return false
}

fn define_fail(tokens []string, macro string, expected string) bool {
	define_count(tokens, macro) or { return err.msg().contains(expected) }
	return false
}

fn config_fail(arguments []string, expected string) bool {
	validate_config(arguments) or { return err.msg().contains(expected) }
	return false
}

fn config_for_test(generation string, mode string, profile string, lane string, output string,
	cc string, cxx string) !VerifyConfig {
	return validate_config(['verify_final_link.v', 'input.log', output, generation, mode, profile,
		lane, cc, cxx, 'report.txt'])
}

fn run_compare_files_child(arguments []string) !CompareChildResult {
	executable := os.executable()
	metadata := os.lstat(executable) or {
		return error('selftest executable metadata read failed')
	}
	if metadata.get_filetype() != .regular || os.is_link(executable) {
		return error('selftest executable is not a regular non-link file')
	}
	mut child_arguments := ['compare-files']
	child_arguments << arguments
	mut process := os.new_process(executable)
	process.set_args(child_arguments)
	process.set_redirect_stdio()
	process.run()
	process.wait()
	stdout := process.stdout_slurp()
	stderr := process.stderr_slurp()
	exit_code := process.code
	status := process.status
	process_error := process.err
	process.close()
	if status != .exited || exit_code < 0 || process_error != '' {
		return error('selftest compare-files child process failed to execute')
	}
	return CompareChildResult{
		exit_code: exit_code
		stdout: stdout
		stderr: stderr
	}
}

fn expect_compare_files_child(arguments []string, expected_code int, expected_stderr string) ! {
	result := run_compare_files_child(arguments)!
	if result.exit_code != expected_code || result.stdout != ''
		|| result.stderr.trim_space() != expected_stderr {
		return error('selftest compare-files child result mismatch')
	}
}

fn selftest_write_file(path string, content []u8) ! {
	if os.exists(path) || os.is_link(path) {
		return error('selftest fixture path already exists')
	}
	os.write_file_array(path, content) or {
		return error('selftest fixture write failed')
	}
	metadata := os.lstat(path) or {
		return error('selftest fixture metadata read failed')
	}
	if metadata.get_filetype() != .regular || os.is_link(path)
		|| metadata.size != u64(content.len) {
		return error('selftest fixture is not the expected regular file')
	}
}

fn cleanup_selftest_directory(directory string, files []string, directories []string) ! {
	for path in files {
		if os.is_link(path) || os.exists(path) {
			os.rm(path) or { return error('selftest fixture cleanup failed') }
		}
	}
	for path in directories {
		if os.is_link(path) {
			return error('selftest directory fixture changed into a link')
		}
		if os.exists(path) {
			os.rmdir(path) or { return error('selftest directory fixture cleanup failed') }
		}
	}
	remaining := os.ls(directory) or { return error('selftest directory listing failed') }
	if remaining.len != 0 {
		return error('selftest directory is not empty after fixture cleanup')
	}
	os.rmdir(directory) or { return error('selftest directory cleanup failed') }
}

fn run_compare_files_selftest() ! {
	runner_temp := os.getenv('RUNNER_TEMP')
	if runner_temp == '' {
		return error('selftest requires RUNNER_TEMP')
	}
	runner_metadata := os.lstat(runner_temp) or {
		return error('selftest RUNNER_TEMP metadata read failed')
	}
	if runner_metadata.get_filetype() != .directory || os.is_link(runner_temp) {
		return error('selftest RUNNER_TEMP is not a real directory')
	}
	directory := os.join_path(runner_temp, 'issue74-verify-final-link-selftest-${os.getpid()}')
	if os.exists(directory) || os.is_link(directory) {
		return error('selftest directory already exists')
	}
	empty_left := os.join_path(directory, 'empty-left.bin')
	empty_right := os.join_path(directory, 'empty-right.bin')
	binary_left := os.join_path(directory, 'binary-left.bin')
	binary_right := os.join_path(directory, 'binary-right.bin')
	diff_begin := os.join_path(directory, 'diff-begin.bin')
	diff_middle := os.join_path(directory, 'diff-middle.bin')
	diff_end := os.join_path(directory, 'diff-end.bin')
	diff_size := os.join_path(directory, 'diff-size.bin')
	over_cap := os.join_path(directory, 'over-cap.bin')
	link_path := os.join_path(directory, 'input-link.bin')
	directory_input := os.join_path(directory, 'directory-input')
	missing := os.join_path(directory, 'missing.bin')
	files := [link_path, over_cap, diff_size, diff_end, diff_middle, diff_begin, binary_right,
		binary_left, empty_right, empty_left]
	directories := [directory_input]
	os.mkdir(directory) or { return error('selftest directory creation failed') }
	mut cleanup_required := true
	defer {
		if cleanup_required {
			cleanup_selftest_directory(directory, files, directories) or {}
		}
	}
	directory_metadata := os.lstat(directory) or {
		return error('selftest directory metadata read failed')
	}
	if directory_metadata.get_filetype() != .directory || os.is_link(directory) {
		return error('selftest directory is not a real directory')
	}

	selftest_write_file(empty_left, [])!
	selftest_write_file(empty_right, [])!
	selftest_write_file(binary_left, [u8(0), u8(0xff), u8(1)])!
	selftest_write_file(binary_right, [u8(0), u8(0xff), u8(1)])!
	selftest_write_file(diff_begin, [u8(9), u8(0xff), u8(1)])!
	selftest_write_file(diff_middle, [u8(0), u8(9), u8(1)])!
	selftest_write_file(diff_end, [u8(0), u8(0xff), u8(9)])!
	selftest_write_file(diff_size, [u8(0), u8(0xff)])!
	selftest_write_file(over_cap, []u8{len: int(max_compare_file_size) + 1})!
	os.mkdir(directory_input) or { return error('selftest directory fixture creation failed') }
	os.symlink(empty_left, link_path) or { return error('selftest symlink fixture creation failed') }
	if !os.is_link(link_path) {
		return error('selftest symlink fixture is not a link')
	}

	expect_compare_files_child([empty_left, empty_right], 0, '')!
	expect_compare_files_child([binary_left, binary_right], 0, '')!
	expect_compare_files_child([empty_left, empty_right, binary_left, binary_right], 0, '')!
	expect_compare_files_child([empty_left, empty_right, binary_left, diff_begin], 1,
		'compare-files pair 2 differs')!
	expect_compare_files_child([binary_left, diff_begin], 1, 'compare-files pair 1 differs')!
	expect_compare_files_child([binary_left, diff_middle], 1, 'compare-files pair 1 differs')!
	expect_compare_files_child([binary_left, diff_end], 1, 'compare-files pair 1 differs')!
	expect_compare_files_child([binary_left, diff_size], 1, 'compare-files pair 1 differs')!
	expect_compare_files_child([], 2,
		'usage: verify_final_link compare-files <left> <right> [<left> <right> ...]')!
	expect_compare_files_child([empty_left], 2,
		'usage: verify_final_link compare-files <left> <right> [<left> <right> ...]')!
	expect_compare_files_child([missing, empty_left], 2,
		'compare-files input 1 metadata read failed')!
	expect_compare_files_child([directory_input, empty_left], 2,
		'compare-files input 1 is not a regular non-link file')!
	expect_compare_files_child([link_path, empty_left], 2,
		'compare-files input 1 is not a regular non-link file')!
	expect_compare_files_child([over_cap, empty_left], 2,
		'compare-files input 1 exceeds 8388608 bytes')!

	cleanup_selftest_directory(directory, files, directories)!
	cleanup_required = false
}

fn run_selftest() ! {
	replacement := [u8(0xef), u8(0xbf), u8(0xbd)].bytestr()
	self_expect(decode_utf8_replace('plain'.bytes()) == 'plain', 'ASCII UTF-8 decoding')!
	self_expect(decode_utf8_replace([u8(0xc3), u8(0xa9)]) == 'é', 'valid UTF-8 decoding')!
	self_expect(decode_utf8_replace([u8(0xff)]) == replacement, 'invalid UTF-8 replacement')!
	self_expect(decode_utf8_replace([u8(0xe1), u8(0x80)]) == replacement,
		'truncated UTF-8 maximal subpart')!
	self_expect(decode_utf8_replace([u8(0xe1), u8(0x80), `A`]) == replacement + 'A',
		'invalid UTF-8 maximal subpart')!
	self_expect(decode_utf8_replace([u8(0xe0), u8(0x80), u8(0x80)]) == replacement.repeat(3),
		'overlong UTF-8 rejection')!
	self_expect(split_lines('a\r\nb\nc\rd\v\n') == ['a', 'b', 'c', 'd', ''],
		'reference split-lines separators')!
	words := split_words('one "two three" \'four five\' six\\ seven ""') or {
		return error('selftest failed: word lexer rejected valid input')
	}
	self_expect(words == ['one', 'two three', 'four five', 'six seven', ''],
		'word lexer quoting and escaping')!
	self_expect(words_fail('"unterminated', 'unterminated quote'), 'unterminated quote rejection')!
	normalized_test_path := lexical_path('D:\\A//B/') or {
		return error('selftest failed: valid lexical path rejected')
	}
	self_expect(normalized_test_path == 'd:/a/b', 'lexical path normalization')!
	bad_non_ascii := [u8(`D`), u8(`:`), u8(`/`), u8(0xc3), u8(0xa9)].bytestr()
	self_expect(lexical_fail(bad_non_ascii), 'non-ASCII path rejection')!
	self_expect(lexical_fail('D:/bad\tpath'), 'control path rejection')!
	self_expect(bytes_equal([], []), 'empty byte equality')!
	self_expect(bytes_equal([u8(0), u8(0xff)], [u8(0), u8(0xff)]), 'binary byte equality')!
	self_expect(!bytes_equal([u8(0)], [u8(1)]) && !bytes_equal([u8(0)], [u8(0), u8(1)]),
		'binary byte difference')!
	run_compare_files_selftest()!

	cc := 'C:\\msys64\\ucrt64\\bin\\gcc.exe'
	cxx := 'C:\\msys64\\ucrt64\\bin\\g++.exe'
	output := 'D:\\tmp\\app.exe'
	v1_dynamic := config_for_test('v1', 'dynamic', 'dev', 'ucrt64-gcc', output, cc, cxx) or {
		return error('selftest failed: V1 dynamic config')
	}
	v1_log := '> C compiler cmd: ${cc} input.o -o ${output}'
	v1_result := verify_content(v1_log, v1_dynamic) or {
		return error('selftest failed: V1 direct command: ${err.msg()}')
	}
	expected_v1_report := 'generation=v1\nprofile=dev\nlane=ucrt64-gcc\nrequested_output=d:/tmp/app.exe\n'
		+ 'driver=c:/msys64/ucrt64/bin/gcc.exe\nargv=${cc}\tinput.o\t-o\t${output}\nerrors=\n'
	self_expect(v1_result.errors.len == 0 && v1_result.report == expected_v1_report,
		'V1 direct report')!

	v1_response_log := '> C compiler cmd: ${cc} @"D:\\tmp\\args.rsp"\n'
		+ '> C compiler response file "D:\\tmp\\args.rsp":\ninput.o -o ${output}'
	v1_response := verify_content(v1_response_log, v1_dynamic) or {
		return error('selftest failed: V1 response file: ${err.msg()}')
	}
	self_expect(v1_response.errors.len == 0, 'V1 response-file expansion')!

	v1_static := config_for_test('v1', 'static', 's3', 'ucrt64-gcc', output, cc, cxx) or {
		return error('selftest failed: V1 static config')
	}
	static_log := '> C compiler cmd: ${cxx} -static -DGLIB_STATIC_COMPILATION -D GOBJECT_STATIC_COMPILATION -lintl input.o -liconv -o ${output}'
	static_result := verify_content(static_log, v1_static) or {
		return error('selftest failed: static contract: ${err.msg()}')
	}
	self_expect(static_result.errors.len == 0, 'static driver and flag contract')!

	clang := 'C:\\msys64\\ucrt64\\bin\\clang.exe'
	clangxx := 'C:\\msys64\\ucrt64\\bin\\clang++.exe'
	v3_dynamic := config_for_test('v3', 'dynamic', 's3', 'ucrt64-clang', output, clang,
		clangxx) or { return error('selftest failed: V3 dynamic config') }
	v3_log := '  > ${clang} input.o -o out -fuse-ld=lld'
	v3_result := verify_content(v3_log, v3_dynamic) or {
		return error('selftest failed: V3 LLD command: ${err.msg()}')
	}
	self_expect(v3_result.errors.len == 0 && expected_lld_count(v3_dynamic) == 1,
		'V3 LLD link-only contract')!

	v1_lld_flip := config_for_test('v1', 'dynamic', 's3', 'ucrt64-clang', output, clang,
		clangxx) or { return error('selftest failed: V1 LLD generation flip config') }
	v1_lld_flip_result := verify_content('> C compiler cmd: ${clang} input.o -o ${output}',
		v1_lld_flip) or { return error('selftest failed: V1 LLD generation flip') }
	v3_profile_flip := config_for_test('v3', 'dynamic', 'dev', 'ucrt64-clang', output, clang,
		clangxx) or { return error('selftest failed: V3 LLD profile flip config') }
	v3_profile_flip_result := verify_content('  > ${clang} input.o -o out', v3_profile_flip) or {
		return error('selftest failed: V3 LLD profile flip')
	}
	v3_lane_flip := config_for_test('v3', 'dynamic', 's3', 'clang64-clang', output, clang,
		clangxx) or { return error('selftest failed: V3 LLD lane flip config') }
	v3_lane_flip_result := verify_content('  > ${clang} input.o -o out', v3_lane_flip) or {
		return error('selftest failed: V3 LLD lane flip')
	}
	self_expect(expected_lld_count(v1_lld_flip) == 0
		&& expected_lld_count(v3_profile_flip) == 0 && expected_lld_count(v3_lane_flip) == 0
		&& v1_lld_flip_result.errors.len == 0 && v3_profile_flip_result.errors.len == 0
		&& v3_lane_flip_result.errors.len == 0, 'LLD predicate orthogonal negatives')!
	self_expect(verify_fail('  > ${clang} input.o -o out -fuse-ld=lld', v3_profile_flip,
		'LLD selection cardinality mismatch'), 'unexpected LLD rejection')!

	v3_static := config_for_test('v3', 'static', 'dev', 'clang64-clang', output, clang,
		clangxx) or { return error('selftest failed: V3 static config') }
	v3_response_log := '  > ${clangxx} @D:\\tmp\\link.rsp\n'
		+ '  > C++ linker response file "D:\\tmp\\link.rsp":\n'
		+ '"input.o"\n"-static"\n"-DGLIB_STATIC_COMPILATION"\n"-D"\n'
		+ '"GOBJECT_STATIC_COMPILATION"\n"-lintl"\n"-liconv"\n"-o"\n"out"'
	v3_response := verify_content(v3_response_log, v3_static) or {
		return error('selftest failed: V3 response file: ${err.msg()}')
	}
	self_expect(v3_response.errors.len == 0, 'V3 response-file expansion')!

	self_expect(verify_fail('', v1_dynamic, 'no v1 showcc commands'), 'missing command rejection')!
	self_expect(verify_fail('> C compiler cmd: "unterminated', v1_dynamic,
		'malformed showcc command'), 'malformed command rejection')!
	self_expect(verify_fail('> C compiler response file "D:\\tmp\\a.rsp":\nx', v1_dynamic,
		'orphan response-file block'), 'orphan response rejection')!
	duplicate_response := '> C compiler cmd: ${cc} @D:\\tmp\\a.rsp\n'
		+ '> C compiler response file "D:\\tmp\\a.rsp":\ninput.o -o ${output}\n'
		+ '> C compiler cmd: ${cc} @d:/tmp/a.rsp\n'
		+ '> C compiler response file "d:/tmp/a.rsp":\ninput.o -o ${output}'
	self_expect(verify_fail(duplicate_response, v1_dynamic, 'duplicate response-file block'),
		'duplicate response rejection')!
	self_expect(verify_fail('> C compiler cmd: ${cc} @D:\\tmp\\a.rsp\n'
		+ '> C compiler response file "D:\\tmp\\b.rsp":\ninput.o -o ${output}', v1_dynamic,
		'path mismatch'), 'response path mismatch rejection')!
	self_expect(verify_fail('> C compiler cmd: ${cc} @D:\\tmp\\a.rsp\n'
		+ '> C compiler response file "D:\\tmp\\a.rsp":\n@nested -o ${output}', v1_dynamic,
		'nested response files'), 'nested response rejection')!
	self_expect(verify_fail('> C compiler cmd: ${cc} input.o', v1_dynamic,
		'exactly one -o operand'), 'missing output rejection')!
	self_expect(verify_fail('> C compiler cmd: ${cc} -o ${output} -o other input.o', v1_dynamic,
		'found 2'), 'duplicate output rejection')!
	self_expect(verify_fail('> C compiler cmd: ${cc} input.o -o other.exe', v1_dynamic,
		'exactly one final invocation'), 'wrong final output rejection')!
	compile_lld := '  > ${clang} source.c -c -fuse-ld=lld -o object.o\n'
		+ '  > ${clang} object.o -o out -fuse-ld=lld'
	self_expect(verify_fail(compile_lld, v3_dynamic, 'leaked into a compile-only command'),
		'compile-only LLD rejection')!
	self_expect(verify_fail('  > ${clang} input.o -o out', v3_dynamic,
		'LLD selection cardinality mismatch'), 'missing LLD rejection')!

	joint := define_count(['-DNAME'], 'NAME') or { -1 }
	split := define_count(['-D', 'NAME'], 'NAME') or { -1 }
	duplicate := define_count(['-DNAME', '-D', 'NAME'], 'NAME') or { -1 }
	prefix_suffix := define_count(['-DNAMESPACE', '-D', 'NAME_SUFFIX'], 'NAME') or { -1 }
	self_expect(joint == 1 && split == 1 && duplicate == 2 && prefix_suffix == 0,
		'define cardinality forms')!
	assigned_joint_failed := define_fail(['-DNAME=1'], 'NAME', 'assigned value')
	assigned_split_failed := define_fail(['-D', 'NAME=1'], 'NAME', 'assigned value')
	dangling_failed := define_fail(['-D'], 'NAME', 'dangling -D')
	self_expect(assigned_joint_failed && assigned_split_failed && dangling_failed,
		'assigned and dangling define rejection')!

	bad_driver := verify_content('> C compiler cmd: ${cxx} input.o -o ${output}', v1_dynamic) or {
		return error('selftest failed: bad driver did not produce a report')
	}
	self_expect(bad_driver.errors == ['not expected C driver'], 'semantic error report')!
	bad_path_arguments := ['verify_final_link.v', 'input.log', bad_non_ascii, 'v1', 'dynamic',
		'dev', 'ucrt64-gcc', cc, cxx, 'report.txt']
	bad_path_failed := config_fail(bad_path_arguments, 'non-ASCII or control byte in lexical path')
	self_expect(bad_path_failed, 'config path domain rejection')!
}

fn selftest_cli(arguments []string) int {
	if arguments.len != 2 {
		eprintln('usage: verify_final_link --selftest')
		return 2
	}
	run_selftest() or {
		eprintln(err.msg())
		return 1
	}
	println('verify_final_link selftest ok')
	return 0
}

fn main() {
	if os.args.len >= 2 && os.args[1] == 'compare-files' {
		exit(compare_files_cli(os.args[2..]))
	}
	if os.args.len >= 2 && os.args[1] == '--selftest' {
		exit(selftest_cli(os.args))
	}
	exit(verify_cli(os.args))
}
