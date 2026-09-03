module main

import encoding.utf8.validate
import os

struct ContractRow {
	case_name string
	phase     string
	required  string
	exit_code string
}

struct Evaluation {
	report string
	errors []string
}

fn add_expected(mut expected []ContractRow, name string, phase string, required string) {
	expected << ContractRow{
		case_name: name
		phase: phase
		required: required
	}
}

fn expected_rows(compiler string) []ContractRow {
	cc := compiler.replace('\\', '/').all_after_last('/')
	mut expected := []ContractRow{}
	add_expected(mut expected, 'vglyph_module_check', 'check', 'yes')
	add_expected(mut expected, 'c_dynamic_build', 'build', 'yes')
	add_expected(mut expected, 'c_dynamic_run', 'run', 'yes')
	add_expected(mut expected, 'pango_static_compile', 'build', 'yes')
	add_expected(mut expected, 'pango_static_noiconv_build', 'build', 'no')
	add_expected(mut expected, 'pango_static_iconv_build', 'build', 'yes')
	add_expected(mut expected, 'pango_static_noiconv_iconv_boundary', 'oracle', 'yes')
	add_expected(mut expected, 'pango_static_iconv_run', 'run', 'yes')
	add_expected(mut expected, 'gettext_static_noiconv_build', 'build', 'no')
	add_expected(mut expected, 'gettext_static_iconv_build', 'build', 'yes')
	add_expected(mut expected, 'gettext_static_noiconv_iconv_boundary', 'oracle', 'yes')
	add_expected(mut expected, 'gettext_static_iconv_run', 'run', 'yes')
	for generation in ['v1', 'v3'] {
		for linkage in ['dynamic', 'static'] {
			for profile in ['dev', 's2', 's3'] {
				for build_pass in ['cold', 'warm'] {
					name := 'vglyph_${generation}_${linkage}_${profile}_${build_pass}'
					add_expected(mut expected, '${name}_build', 'build', 'yes')
					if linkage == 'static' {
						add_expected(mut expected, '${name}_static_pe', 'pe', 'yes')
					}
					add_expected(mut expected, '${name}_final_link', 'oracle', 'yes')
					add_expected(mut expected, '${name}_run', 'run', 'yes')
					if profile == 's2' {
						add_expected(mut expected, '${name}_absent_flto', 'flags', 'yes')
					}
					expect_flto := cc == 'gcc' || generation == 'v3'
					if profile == 's3' {
						suffix := if expect_flto { 'present_flto' } else { 'absent_flto' }
						add_expected(mut expected, '${name}_${suffix}', 'flags', 'yes')
					}
					add_expected(mut expected, '${name}_generated_c', 'artifact', 'yes')
					add_expected(mut expected, '${name}_response_file', 'artifact', 'no')
					if profile == 's3' {
						show := 'showcase_${generation}_${linkage}_${profile}_${build_pass}'
						add_expected(mut expected, '${show}_build', 'build', 'yes')
						if linkage == 'static' {
							add_expected(mut expected, '${show}_static_pe', 'pe', 'yes')
						}
						add_expected(mut expected, '${show}_final_link', 'oracle', 'yes')
						suffix := if expect_flto { 'present_flto' } else { 'absent_flto' }
						add_expected(mut expected, '${show}_${suffix}', 'flags', 'yes')
						add_expected(mut expected, '${show}_generated_c', 'artifact', 'yes')
						add_expected(mut expected, '${show}_response_file', 'artifact', 'no')
					}
				}
			}
		}
	}
	add_expected(mut expected, 'windows_error_reporting', 'collect', 'yes')
	return expected
}

fn row_key(row ContractRow) string {
	return '${row.case_name}\t${row.phase}\t${row.required}'
}

fn tuple_text(key string) string {
	parts := key.split('\t')
	return "('${parts[0]}', '${parts[1]}', '${parts[2]}')"
}

fn parse_rows(text string) ![]ContractRow {
	if !validate.utf8_string(text) {
		return error('results TSV is not valid UTF-8')
	}
	if text.contains('\r') {
		if text.replace('\r\n', '\n').contains('\r') {
			return error('results TSV contains a bare carriage return')
		}
	}
	mut lines := text.replace('\r\n', '\n').split('\n')
	if lines.len > 0 && lines.last() == '' {
		lines.delete_last()
	}
	if lines.len == 0 || lines[0] != 'case\tphase\trequired\texit_code' {
		return error('invalid results TSV header')
	}
	mut rows := []ContractRow{cap: lines.len - 1}
	for index, line in lines[1..] {
		if line.contains('"') {
			return error('quoted TSV field is not allowed at line ${index + 2}')
		}
		fields := line.split('\t')
		if fields.len != 4 {
			return error('expected four TSV fields at line ${index + 2}')
		}
		if fields.any(it == '') {
			return error('empty TSV field at line ${index + 2}')
		}
		for field in fields {
			if field.bytes().any(it > 0x7f) {
				return error('non-ASCII TSV field at line ${index + 2}')
			}
		}
		rows << ContractRow{
			case_name: fields[0]
			phase: fields[1]
			required: fields[2]
			exit_code: fields[3]
		}
	}
	return rows
}

fn is_ascii_digits(value string) bool {
	if value == '' {
		return false
	}
	for byte in value.bytes() {
		if byte < `0` || byte > `9` {
			return false
		}
	}
	return true
}

fn evaluate(text string, compiler string) !Evaluation {
	rows := parse_rows(text)!
	expected := expected_rows(compiler)
	mut expected_counts := map[string]int{}
	mut actual_counts := map[string]int{}
	for row in expected {
		expected_counts[row_key(row)]++
	}
	for row in rows {
		actual_counts[row_key(row)]++
	}
	mut keys := []string{}
	for key, _ in expected_counts {
		if key !in keys {
			keys << key
		}
	}
	for key, _ in actual_counts {
		if key !in keys {
			keys << key
		}
	}
	keys.sort()
	mut errors := []string{}
	for key in keys {
		missing := expected_counts[key] - actual_counts[key]
		if missing > 0 {
			errors << 'missing ${missing} ${tuple_text(key)}'
		}
	}
	for key in keys {
		extra := actual_counts[key] - expected_counts[key]
		if extra > 0 {
			errors << 'unknown/duplicate ${extra} ${tuple_text(key)}'
		}
	}
	for row in rows {
		value := row.exit_code
		if value in ['skipped', 'panic', ''] {
			errors << 'forbidden status ${row.case_name}=${value}'
		} else if row.required == 'yes' && value != '0' {
			errors << 'required failure ${row.case_name}=${value}'
		} else if row.required == 'no' && value !in ['0', '1', 'absent'] && !is_ascii_digits(value) {
			errors << 'invalid optional status ${row.case_name}=${value}'
		}
	}
	mut report := 'expected=${expected.len}\nactual=${rows.len}\ncomplete=${errors.len == 0}\n'
	for message in errors {
		report += 'error=${message}\n'
	}
	return Evaluation{
		report: report
		errors: errors
	}
}

fn ensure(condition bool, message string) ! {
	if !condition {
		return error('selftest failed: ${message}')
	}
}

fn normalize_cli_arguments(arguments []string) ![]string {
	if arguments.len == 1 && arguments[0] == '--self-test' {
		return ['verify_results', arguments[0]]
	}
	if arguments.len == 2 && arguments[1] == '--self-test' {
		return arguments.clone()
	}
	if arguments.any(it == '--self-test') {
		return error('usage: verify_results.v <results.tsv> <compiler> <report>')
	}
	if arguments.len == 3 {
		mut normalized := ['verify_results']
		normalized << arguments
		return normalized
	}
	if arguments.len == 4 {
		return arguments.clone()
	}
	return error('usage: verify_results.v <results.tsv> <compiler> <report>')
}

fn cli_normalization_fails(arguments []string) bool {
	normalize_cli_arguments(arguments) or { return true }
	return false
}

fn cli_normalization_selftest() ! {
	v1_selftest := ['helper.exe', '--self-test']
	selftest_v3 := ['--self-test']
	ensure(normalize_cli_arguments(v1_selftest)! == v1_selftest, 'V1 selftest argv normalization')!
	ensure(normalize_cli_arguments(selftest_v3)! == ['verify_results', '--self-test'],
		'V3 selftest argv normalization')!
	v3_run := ['results.tsv', 'gcc', 'report.txt']
	mut v1_run := ['helper.exe']
	v1_run << v3_run
	ensure(normalize_cli_arguments(v1_run)! == v1_run, 'V1 run argv normalization')!
	mut expected_v3_run := ['verify_results']
	expected_v3_run << v3_run
	ensure(normalize_cli_arguments(v3_run)! == expected_v3_run, 'V3 run argv normalization')!
	ensure(cli_normalization_fails([]), 'empty argv normalization rejection')!
	ensure(cli_normalization_fails(['helper.exe', '--self-test', 'extra']),
		'extra selftest argv normalization rejection')!
	ensure(cli_normalization_fails(['one', 'two']), 'wrong run argv cardinality rejection')!
}

fn rows_tsv(rows []ContractRow) string {
	mut text := 'case\tphase\trequired\texit_code\n'
	for row in rows {
		text += '${row.case_name}\t${row.phase}\t${row.required}\t0\n'
	}
	return text
}

fn expect_parse_failure(text string, label string) ! {
	if _ := evaluate(text, 'gcc') {
		return error('selftest failed: ${label} was accepted')
	}
}

fn selftest() ! {
	cli_normalization_selftest()!
	expected := expected_rows('gcc')
	ensure(expected.len == 205, 'expected cardinality is ${expected.len}, not 205')!
	ensure(expected_rows('clang').len == 205, 'clang expected cardinality changed')!
	golden := rows_tsv(expected)
	good := evaluate(golden, 'gcc')!
	ensure(good.errors.len == 0, 'golden matrix has errors')!
	ensure(good.report == 'expected=205\nactual=205\ncomplete=true\n', 'golden report changed')!
	missing := evaluate(rows_tsv(expected[..expected.len - 1]), 'gcc')!
	ensure(missing.errors.len == 1 && missing.errors[0].starts_with('missing 1 '),
		'missing row was not detected')!
	mut duplicate_rows := expected.clone()
	duplicate_rows << expected[0]
	duplicate := evaluate(rows_tsv(duplicate_rows), 'gcc')!
	ensure(duplicate.errors.len == 1 && duplicate.errors[0].starts_with('unknown/duplicate 1 '),
		'duplicate row was not detected')!
	bad_status := golden.replace_once('\tcheck\tyes\t0\n', '\tcheck\tyes\tpanic\n')
	status := evaluate(bad_status, 'gcc')!
	ensure(status.errors.any(it == 'forbidden status vglyph_module_check=panic'),
		'forbidden status was not detected')!
	skipped_status := evaluate(golden.replace_once('\tcheck\tyes\t0\n',
		'\tcheck\tyes\tskipped\n'), 'gcc')!
	ensure(skipped_status.errors.any(it == 'forbidden status vglyph_module_check=skipped'),
		'skipped status was not detected')!
	required_failure := evaluate(golden.replace_once('\tcheck\tyes\t0\n',
		'\tcheck\tyes\t2\n'), 'gcc')!
	ensure(required_failure.errors.any(it == 'required failure vglyph_module_check=2'),
		'required failure was not detected')!
	optional_invalid := evaluate(golden.replace_once('\tbuild\tno\t0\n',
		'\tbuild\tno\tbogus\n'), 'gcc')!
	ensure(optional_invalid.errors.any(it.starts_with('invalid optional status ')),
		'invalid optional status was not detected')!
	expect_parse_failure('wrong\theader\n', 'bad header')!
	expect_parse_failure('case\tphase\trequired\texit_code\n"quoted"\tbuild\tyes\t0\n',
		'quoted field')!
	expect_parse_failure('case\tphase\trequired\texit_code\na\tbuild\tyes\t0\textra\n',
		'extra tab')!
	expect_parse_failure('case\tphase\trequired\texit_code\na\nb\tbuild\tyes\t0\n',
		'multiline field')!
	expect_parse_failure([u8(0xff)].bytestr(), 'invalid UTF-8')!
	expect_parse_failure('case\tphase\trequired\texit_code\nméchant\tbuild\tyes\t0\n',
		'non-ASCII field')!
}

fn run(arguments []string) ! {
	if arguments.len == 2 && arguments[1] == '--self-test' {
		selftest()!
		return
	}
	if arguments.len != 4 {
		return error('usage: verify_results.v <results.tsv> <compiler> <report>')
	}
	bytes := os.read_bytes(arguments[1])!
	if !validate.utf8_data(bytes.data, bytes.len) {
		return error('results TSV is not valid UTF-8')
	}
	result := evaluate(bytes.bytestr(), arguments[2])!
	os.write_file(arguments[3], result.report)!
	if result.errors.len > 0 {
		return error(result.errors.join('\n'))
	}
}

fn main() {
	arguments := normalize_cli_arguments(os.args) or {
		eprintln(err.msg())
		exit(1)
	}
	run(arguments) or {
		eprintln(err.msg())
		exit(1)
	}
}
