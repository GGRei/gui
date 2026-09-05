#!/usr/bin/env bash

set -uo pipefail

if [ "$#" -ne 5 ]; then
	echo "usage: $0 <gcc|clang> <v.exe> <gui-dir> <artifact-dir> <lane>" >&2
	exit 2
fi

cc="$1"
v_exe="$2"
gui_dir="$3"
artifact_root="$4"
lane="$5"
unset VFLAGS CFLAGS CPPFLAGS LDFLAGS

case "$cc" in
	gcc) cxx=g++ ;;
	clang) cxx=clang++ ;;
	*)
		echo "unsupported compiler: $cc" >&2
		exit 2
		;;
esac
case "$lane:$MSYSTEM:$cc:$cxx" in
	ucrt64-gcc:UCRT64:gcc:g++|ucrt64-clang:UCRT64:clang:clang++|clang64-clang:CLANG64:clang:clang++|mingw64-gcc:MINGW64:gcc:g++) ;;
	*) echo "unsupported lane/toolchain tuple: $lane/$MSYSTEM/$cc/$cxx" >&2; exit 2 ;;
esac

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
probe_c="$script_dir/pango_probe.c"
gettext_probe_c="$script_dir/gettext_probe.c"
probe_v="$script_dir/vglyph_probe.v"
windows_collector="$script_dir/collect_windows_diagnostics.ps1"
showcase_v="$gui_dir/examples/showcase.v"

: "${ISSUE74_VERIFY_FINAL_LINK_V1:?ISSUE74_VERIFY_FINAL_LINK_V1 is required}"
: "${ISSUE74_VERIFY_FINAL_LINK_V3:?ISSUE74_VERIFY_FINAL_LINK_V3 is required}"
final_link_parser_v1="$(cygpath -u "$ISSUE74_VERIFY_FINAL_LINK_V1")"
final_link_parser_v3="$(cygpath -u "$ISSUE74_VERIFY_FINAL_LINK_V3")"

: "${MINGW_PREFIX:?MINGW_PREFIX is not set; run this script from an MSYS2 WinGNU shell}"
for required_path in "$v_exe" "$probe_c" "$gettext_probe_c" "$probe_v" "$windows_collector" "$showcase_v"; do
	if [ ! -f "$required_path" ]; then
		echo "required diagnostic input not found: $required_path" >&2
		exit 2
	fi
done
for parser in "$final_link_parser_v1" "$final_link_parser_v3"; do
	if [ ! -f "$parser" ] || [ -L "$parser" ] || [ ! -x "$parser" ]; then
		echo "required final-link parser not found or unsafe: $parser" >&2
		exit 2
	fi
done
objdump_tool="${ISSUE74_OBJDUMP:-objdump}"
case "$objdump_tool" in objdump|llvm-objdump) ;; *) echo "unsupported object inspection tool: $objdump_tool" >&2; exit 2 ;; esac
nm_tool="${ISSUE74_NM:-nm}"
case "$nm_tool" in nm|llvm-nm) ;; *) echo "unsupported symbol inspection tool: $nm_tool" >&2; exit 2 ;; esac
for required_tool in timeout cygpath powershell.exe "$nm_tool" "$objdump_tool"; do
	if ! command -v "$required_tool" >/dev/null 2>&1; then
		echo "required diagnostic tool not found: $required_tool" >&2
		exit 2
	fi
done
for inspection_tool in "$nm_tool" "$objdump_tool"; do
	inspection_path="$(realpath "$(command -v "${inspection_tool}.exe")")"
	case "$inspection_path" in
		"$MINGW_PREFIX"/bin/*.exe) ;;
		*) echo "$inspection_tool escaped $MINGW_PREFIX/bin: $inspection_path" >&2; exit 2 ;;
	esac
done
: "${VMODULES:?VMODULES is not set; point it at the Windows-visible V modules directory}"
vmodules_dir="$(cygpath -u "$VMODULES")"
vmodules_windows="$(cygpath -w "$vmodules_dir")"
export VMODULES="$vmodules_windows"
if [ ! -f "$vmodules_dir/vglyph/v.mod" ]; then
	echo "vglyph module not found below VMODULES: $vmodules_dir/vglyph/v.mod" >&2
	exit 2
fi
if ! command -v "$cxx" >/dev/null 2>&1; then
	echo "required C++ linker driver not found: $cxx" >&2
	exit 2
fi
cc_exe="$(realpath "$(command -v "${cc}.exe")")"
cxx_exe="$(realpath "$(command -v "${cxx}.exe")")"
if [ ! -f "$cc_exe" ] || [ ! -x "$cc_exe" ] || [ ! -f "$cxx_exe" ] || [ ! -x "$cxx_exe" ]; then
	echo "native compiler pair is not executable: $cc_exe / $cxx_exe" >&2
	exit 2
fi
case "$cc_exe:$cxx_exe" in
	"$MINGW_PREFIX"/bin/*.exe:"$MINGW_PREFIX"/bin/*.exe) ;;
	*) echo "native compiler pair escaped $MINGW_PREFIX/bin: $cc_exe / $cxx_exe" >&2; exit 2 ;;
esac
cc_windows="$(cygpath -w "$cc_exe")"
cxx_windows="$(cygpath -w "$cxx_exe")"

out_dir="$artifact_root/$cc"
logs_dir="$out_dir/logs"
bin_dir="$out_dir/bin"
pe_dir="$out_dir/pe"
pkgconfig_dir="$out_dir/pkgconfig"
generated_dir="$out_dir/generated"
probes_dir="$out_dir/probes"
windows_dir="$out_dir/windows"
results_file="$out_dir/results.tsv"
summary_file="$out_dir/summary.md"
marker_file="$out_dir/.diagnostic-start"
diagnostic_start_utc="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

mkdir -p "$logs_dir" "$bin_dir" "$pe_dir" "$pkgconfig_dir" "$generated_dir" "$probes_dir" "$windows_dir" || exit 2
touch "$marker_file"
cp "$probe_c" "$gettext_probe_c" "$probe_v" "$windows_collector" "$probes_dir/"
printf 'case\tphase\trequired\texit_code\n' > "$results_file"

declare -A case_rc=()
declare -a pango_cflags=()
declare -a pango_dynamic_libs=()
declare -a pango_static_libs=()
declare -a required_v_artifact_cases=()
declare -A artifact_output_stem=()
required_failures=0
last_rc=0

to_unix_path() {
	local path="$1"
	if [[ "$path" =~ ^[A-Za-z]:[\\/] ]] && command -v cygpath >/dev/null 2>&1; then
		cygpath -u "$path"
	else
		printf '%s\n' "$path"
	fi
}

record_result() {
	local name="$1"
	local phase="$2"
	local required="$3"
	local command_rc="$4"
	printf '%s\t%s\t%s\t%s\n' "$name" "$phase" "$required" "$command_rc" >> "$results_file"
	case_rc["$name"]="$command_rc"
	last_rc="$command_rc"
	if [ "$required" = yes ] && [ "$command_rc" != 0 ]; then
		required_failures=$((required_failures + 1))
	fi
}

run_command() {
	local name="$1"
	local phase="$2"
	local required="$3"
	shift 3
	local log_file="$logs_dir/$name.log"
	local command_rc
	local timeout_seconds
	case "$phase:$name" in
		build:showcase_*) timeout_seconds=480 ;;
		build:*) timeout_seconds=240 ;;
		run:*) timeout_seconds=45 ;;
		collect:*) timeout_seconds=120 ;;
		*) timeout_seconds=120 ;;
	esac

	{
		printf 'case: %s\nphase: %s\nrequired: %s\ntimeout_seconds: %s\ncommand:' "$name" "$phase" "$required" "$timeout_seconds"
		printf ' %q' "$@"
		printf '\n'
	} | tee "$log_file"

	timeout --signal=TERM --kill-after=15s "${timeout_seconds}s" "$@" 2>&1 | tee -a "$log_file"
	command_rc=${PIPESTATUS[0]}
	printf 'exit_code: %s\n' "$command_rc" | tee -a "$log_file"
	record_result "$name" "$phase" "$required" "$command_rc"
	return 0
}

record_skipped() {
	local name="$1"
	local phase="$2"
	local required="$3"
	local reason="$4"
	printf 'case: %s\nphase: %s\nrequired: %s\nskipped: %s\n' "$name" "$phase" "$required" "$reason" | tee "$logs_dir/$name.log"
	record_result "$name" "$phase" "$required" skipped
}

capture_compact_pe() {
	local executable="$1"
	local report="$2"
	local -a pipeline_status=()
	local architecture_count
	local subsystem_count
	local dll_count
	{
		echo "file: $executable"
		if command -v file >/dev/null 2>&1; then
			file "$executable"
		fi
		sha256sum "$executable"
		stat -c 'size_bytes: %s' "$executable"
	} > "$report"
	timeout --signal=TERM --kill-after=5s 60s "$objdump_tool" -f -p "$executable" 2>&1 \
		| awk '
			{
				line = $0
				sub(/\r$/, "", line)
				lower = tolower(line)
				if (lower ~ /file format|^[[:space:]]*format:/) {
					if (lower ~ /file format[[:space:]]+(pei|coff)-x86-64/ || lower ~ /^[[:space:]]*format:[[:space:]]*coff-x86-64[[:space:]]*$/) {
						print "architecture: x86-64"
						next
					}
					exit 42
				}
				if (lower ~ /architecture:|^[[:space:]]*arch:/) {
					if (lower ~ /architecture:[[:space:]]*(i386:x86-64|x86_64)/ || lower ~ /^[[:space:]]*arch:[[:space:]]*x86_64[[:space:]]*$/) {
						print "architecture: x86-64"
						next
					}
					exit 42
				}
				if (lower ~ /^[[:space:]]*subsystem/) {
					if (lower ~ /^[[:space:]]*subsystem[[:space:]]+0*2[[:space:]]+\(windows gui\)[[:space:]]*$/) {
						print "subsystem: gui"
						next
					}
					if (lower ~ /^[[:space:]]*subsystem[[:space:]]+0*3[[:space:]]+\(windows cui\)[[:space:]]*$/) {
						print "subsystem: console"
						next
					}
					exit 42
				}
				if (line ~ /DLL Name:/) {
					if (line !~ /^[[:space:]]*DLL Name:[[:space:]]*[^[:space:]]+[[:space:]]*$/) exit 42
					sub(/^[[:space:]]*DLL Name:[[:space:]]*/, "DLL Name: ", line)
					sub(/[[:space:]]*$/, "", line)
					print line
				}
			}' \
		| tee -a "$report"
	pipeline_status=("${PIPESTATUS[@]}")
	if [ "${#pipeline_status[@]}" -ne 3 ] \
		|| [ "${pipeline_status[0]}" -ne 0 ] \
		|| [ "${pipeline_status[1]}" -ne 0 ] \
		|| [ "${pipeline_status[2]}" -ne 0 ]; then
		echo "compact PE pipeline failed: ${pipeline_status[*]}" >&2
		return 1
	fi
	architecture_count="$(grep -c '^architecture: x86-64$' "$report" || true)"
	subsystem_count="$(grep -Ec '^subsystem: (gui|console)$' "$report" || true)"
	dll_count="$(grep -c '^DLL Name: ' "$report" || true)"
	if [ "$architecture_count" -lt 1 ] || [ "$architecture_count" -gt 2 ] \
		|| [ "$subsystem_count" -ne 1 ] || [ "$dll_count" -lt 1 ] || [ "$dll_count" -gt 256 ] \
		|| [ "$(stat -c '%s' "$report")" -gt 32768 ]; then
		echo "compact PE evidence is out of bounds: arch=$architecture_count subsystem=$subsystem_count dll=$dll_count" >&2
		return 1
	fi
	return 0
}

inspect_pe() {
	local name="$1"
	local executable="$2"
	local report="$pe_dir/$name.txt"
	if [ ! -f "$executable" ]; then
		return 0
	fi
	if ! capture_compact_pe "$executable" "$report"; then
		return 1
	fi
	echo "PE imports for $name:"
	grep -i 'DLL Name' "$report" || true
}

check_static_pe() {
	local name="$1"
	local required="$2"
	local executable="$3"
	local build_rc="$4"
	local expected_subsystem="$5"
	local log_file="$logs_dir/${name}_static_pe.log"
	local report="$pe_dir/$name.txt"
	local dll_name
	local lower_name
	local gate_rc=0
	local -a third_party_imports=()

	if [ "$build_rc" -ne 0 ]; then
		record_skipped "${name}_static_pe" pe no "build exit code $build_rc"
		return 0
	fi
	if [ ! -f "$executable" ]; then
		record_skipped "${name}_static_pe" pe "$required" 'build returned 0 but the PE output is missing'
		return 0
	fi

	if [ ! -s "$report" ]; then
		gate_rc=2
	fi
	if ! grep -Fxq 'architecture: x86-64' "$report"; then
		gate_rc=3
	fi
	case "$expected_subsystem" in
		gui)
			if ! grep -Fxq 'subsystem: gui' "$report"; then
				gate_rc=4
			fi
			;;
		console)
			if ! grep -Fxq 'subsystem: console' "$report"; then
				gate_rc=4
			fi
			;;
		*)
			echo "unsupported expected PE subsystem: $expected_subsystem" >&2
			gate_rc=4
			;;
	esac

	while IFS= read -r dll_name; do
		dll_name="${dll_name#*:}"
		dll_name="${dll_name#"${dll_name%%[![:space:]]*}"}"
		dll_name="${dll_name%$'\r'}"
		[ -n "$dll_name" ] || continue
		lower_name="${dll_name,,}"
		if [ -f "$MINGW_PREFIX/bin/$dll_name" ] || [[ "$lower_name" == lib*.dll ]] || [ "$lower_name" = zlib1.dll ]; then
			third_party_imports+=("$dll_name")
		fi
	done < <(grep '^DLL Name: ' "$report" || true)
	if [ "${#third_party_imports[@]}" -ne 0 ]; then
		gate_rc=5
	fi

	{
		echo "file: $executable"
		echo "expected_subsystem: $expected_subsystem"
		echo "third_party_imports: ${third_party_imports[*]:-none}"
		echo "gate_exit_code: $gate_rc"
	} | tee "$log_file"
	record_result "${name}_static_pe" pe "$required" "$gate_rc"
}

run_built_executable() {
	local name="$1"
	local required="$2"
	local executable="$3"
	local build_rc="$4"
	if [ "$build_rc" -ne 0 ]; then
		record_skipped "${name}_run" run no "build exit code $build_rc"
	elif [ ! -f "$executable" ]; then
		record_skipped "${name}_run" run "$required" 'build returned 0 but the executable is missing'
	else
		run_command "${name}_run" run "$required" "$executable"
	fi
}

run_v_build() {
	local name="$1"
	local required="$2"
	local source="$3"
	shift 3
	local executable="$bin_dir/${output_stem:-$name}.exe"
	local build_rc
	local proof_required="$required"
	local -a command=(
		"${active_v_exe:-$v_exe}"
		-cc "$cc_windows"
		-d sokol_d3d11
		-keepc
		-no-retry-compilation
		-showcc
		-show-c-output
	)
	command+=("$@")
	command+=(-o "$executable" "$source")
	run_command "${name}_build" build "$required" "${command[@]}"
	build_rc="$last_rc"
	if [ "$build_rc" -eq 0 ]; then
		proof_required=yes
	fi
	if ! inspect_pe "$name" "$executable"; then
		required_failures=$((required_failures + 1))
	fi
	if [ "$proof_required" = yes ]; then
		required_v_artifact_cases+=("$name")
		artifact_output_stem["$name"]="${output_stem:-$name}"
	fi
	case "$name" in
		*_static_*)
			if [[ "$name" == showcase_* ]]; then
				check_static_pe "$name" "$proof_required" "$executable" "$build_rc" gui
			else
				check_static_pe "$name" "$proof_required" "$executable" "$build_rc" console
			fi
			;;
	esac
	last_rc="$build_rc"
}

write_environment_report() {
	local report="$out_dir/environment.txt"
	local name
	local linker_driver
	{
		echo '=== runner ==='
		cmd.exe /c ver 2>&1 || true
		uname -a || true
		printf 'nproc: '
		nproc 2>/dev/null || true
		df -h . || true
		powershell.exe -NoProfile -Command \
			'Get-CimInstance Win32_ComputerSystem | Select-Object NumberOfLogicalProcessors,TotalPhysicalMemory | Format-List; Get-PSDrive -PSProvider FileSystem | Format-Table -AutoSize' \
			2>&1 || true

		echo
		echo '=== selected environment ==='
		for name in MSYSTEM MINGW_PREFIX MSYS2_LOCATION VMODULES HOME USERPROFILE PKG_CONFIG_PATH PKG_CONFIG_LIBDIR CFLAGS CPPFLAGS LDFLAGS VFLAGS ImageOS ImageVersion RUNNER_OS RUNNER_ARCH; do
			printf '%s=%s\n' "$name" "${!name-}"
		done

		echo
		echo '=== command resolution ==='
			for name in v gcc g++ clang clang++ ld "$nm_tool" "$objdump_tool" pkg-config pkgconf; do
			printf '%s: ' "$name"
			command -v "$name" 2>&1 || true
		done
		where.exe v.exe gcc.exe clang.exe ld.exe pkg-config.exe pkgconf.exe 2>&1 || true

		echo
		echo '=== versions and revisions ==='
		"$v_exe" version 2>&1 || true
		"$cc" --version 2>&1 || true
		"$cxx" --version 2>&1 || true
		"$cc" -dumpmachine 2>&1 || true
		"$cc" --print-target-triple 2>&1 || true
		linker_driver="$("$cc" -print-prog-name=ld 2>&1 || true)"
		printf 'driver_linker: %s\n' "$linker_driver"
		if [ -n "$linker_driver" ]; then
			"$linker_driver" --version 2>&1 || true
		fi
		for name in collect2 lto1 lto-wrapper as; do
			printf 'driver_%s: ' "$name"
			"$cc" "-print-prog-name=$name" 2>&1 || true
		done
		"$cc" -print-search-dirs 2>&1 || true
		gcc --version 2>&1 || true
		clang --version 2>&1 || true
		ld --version 2>&1 || true
		pkgconf --version 2>&1 || true
		git -C "$(dirname "$v_exe")" rev-parse HEAD 2>&1 || true
		git -C "$gui_dir" rev-parse HEAD 2>&1 || true
		git -C "$vmodules_dir/vglyph" rev-parse HEAD 2>&1 || true

		echo
		echo '=== installed packages ==='
		pacman -Q | sort
		for name in \
			"$MINGW_PREFIX/lib/libintl.a" \
			"$MINGW_PREFIX/lib/libiconv.a" \
			"$MINGW_PREFIX/lib/libpangoft2-1.0.a"; do
			pacman -Qo "$name" 2>&1 || true
		done

		echo
		echo '=== pkgconf pangoft2 ==='
		pkgconf --modversion pangoft2 2>&1 || true
		pkgconf --variable=prefix pangoft2 2>&1 || true
		pkgconf --path pangoft2 pango gobject-2.0 glib-2.0 2>&1 || true
		pkgconf --print-requires pangoft2 2>&1 || true
		pkgconf --print-requires-private pangoft2 2>&1 || true
		pkgconf --cflags --libs pangoft2 2>&1 || true
		pkgconf --static --cflags --libs pangoft2 2>&1 || true
		pkgconf --static --simulate pangoft2 2>&1 || true
		pkgconf --static --digraph pangoft2 2>&1 || true

		echo
		echo '=== libintl/libiconv symbol boundary ==='
			"$nm_tool" -u "$MINGW_PREFIX/lib/libintl.a" 2>&1 | grep -Ei 'iconv' || true
			"$nm_tool" -g --defined-only "$MINGW_PREFIX/lib/libiconv.a" 2>&1 | grep -Ei 'iconv' || true
	} > "$report" 2>&1
	cat "$report"
}

collect_text_import_mapping() {
	local prefix="$1"
	local cxx_driver="$2"
	local dlltool=''
	local candidate token name archive resolved pkgconfig_output group tool_rc count=0
	local -a roots=(freetype2 harfbuzz fribidi fontconfig pango pangoft2 gobject-2.0 glib-2.0)
	local -a text_tokens=()
	local -a tokens=()
	local -A seen=()
	prefix="$(realpath "$prefix")" || return 1
	printf 'diagnostic_only=true\nruntime_private_coverage=partial\nprefix=%s\n' "$prefix"
	printf 'roots: %s\n' "${roots[*]}"
	printf 'declared_fallback=-liconv\nprivate_runtime_candidates=stdc++,c++,winpthread,gcc_s,unwind\n'
	for candidate in "$prefix/bin/dlltool.exe" "$prefix/bin/llvm-dlltool.exe"; do
		if [ -f "$candidate" ] && [ -x "$candidate" ] && [ ! -L "$candidate" ]; then
			dlltool="$(realpath "$candidate")" || return 1
			[[ "$dlltool" == "$prefix/bin/"* ]] || return 1
			break
		fi
	done
	[ -n "$dlltool" ] || { echo 'incomplete: no regular triplet dlltool'; return 1; }
	printf 'dlltool=%s\n' "$dlltool"
	timeout --foreground --kill-after=1s 4s "$dlltool" --version
	tool_rc=$?
	printf 'dlltool_version_rc=%s (not supported by every LLVM dlltool)\n' "$tool_rc"
	timeout --foreground --kill-after=1s 4s sha256sum -- "$dlltool" || return 1
	timeout --foreground --kill-after=1s 4s pacman -Qo -- "$dlltool" || return 1
	pkgconfig_output="$(timeout --foreground --kill-after=1s 4s "$prefix/bin/pkgconf.exe" \
		--static --libs-only-l "${roots[@]}" 2>&1)"
	tool_rc=$?
	printf 'pkgconf_rc=%s\npkgconf_output=%s\n' "$tool_rc" "$pkgconfig_output"
	[ "$tool_rc" -eq 0 ] || return 1
	read -r -a text_tokens <<< "$pkgconfig_output"
	text_tokens+=(-liconv)
	for group in pkgconfig_and_declared_fallback private_runtime_candidates; do
		if [ "$group" = pkgconfig_and_declared_fallback ]; then
			tokens=("${text_tokens[@]}")
		else
			# Observations only: this is not an exhaustive C++ runtime closure.
			tokens=(-lstdc++ -lc++ -lwinpthread -lgcc_s -lunwind)
		fi
		for token in "${tokens[@]}"; do
			[ -z "${seen[$group:$token]+present}" ] || continue
			seen["$group:$token"]=1
			count=$((count + 1))
			[ "$count" -le 128 ] || { echo 'incomplete: token limit 128 reached'; return 1; }
			printf '\ngroup=%s token=%s\n' "$group" "$token"
			if [[ ! "$token" =~ ^-l[A-Za-z0-9_+.-]+$ ]]; then
				echo 'incomplete: unsupported library token; no filename inferred'
				continue
			fi
			name="${token#-l}"
			for candidate in "lib$name.dll.a" "lib$name.a"; do
				archive="$prefix/lib/$candidate"
				if [ "$group" = private_runtime_candidates ]; then
					resolved="$(timeout --foreground --kill-after=1s 4s "$cxx_driver" \
						"-print-file-name=$candidate" 2>&1)"
					tool_rc=$?
					printf 'driver_lookup=%s rc=%s result=%s\n' "$candidate" "$tool_rc" "$resolved"
					[ "$tool_rc" -eq 0 ] && [ "$resolved" != "$candidate" ] || continue
					archive="$(cygpath -u "$resolved")" || return 1
				fi
				if [ ! -f "$archive" ] || [ -L "$archive" ]; then
					printf 'unavailable_regular_archive=%s\n' "$archive"
					continue
				fi
				archive="$(realpath "$archive")" || return 1
				if [[ "$archive" != "$prefix/"* ]]; then
					printf 'incomplete: archive outside triplet: %s\n' "$archive"
					continue
				fi
				printf 'archive=%s size_bytes=%s\n' "$archive" "$(stat -c %s "$archive")"
				timeout --foreground --kill-after=1s 4s sha256sum -- "$archive"
				printf 'sha256_rc=%s\n' "$?"
				timeout --foreground --kill-after=1s 4s pacman -Qo -- "$archive"
				printf 'package_owner_rc=%s\n' "$?"
				timeout --foreground --kill-after=1s 4s "$dlltool" -I "$archive"
				printf 'identify_rc=%s\n' "$?"
			done
		done
	done
	printf '\ncollection_end=true\nruntime_private_coverage=partial\n'
}

copy_pkgconfig_metadata() {
	local pc_root
	local destination
	for pc_root in "$MINGW_PREFIX/lib/pkgconfig" "$MINGW_PREFIX/share/pkgconfig"; do
		[ -d "$pc_root" ] || continue
		destination="$pkgconfig_dir/$(basename "$(dirname "$pc_root")")"
		mkdir -p "$destination"
		find "$pc_root" -maxdepth 1 -type f -name '*.pc' -exec cp '{}' "$destination/" \;
	done
	pkgconf --cflags pangoft2 > "$pkgconfig_dir/pangoft2.cflags.txt" 2>&1 || true
	pkgconf --libs pangoft2 > "$pkgconfig_dir/pangoft2.dynamic-libs.txt" 2>&1 || true
	pkgconf --static --libs pangoft2 > "$pkgconfig_dir/pangoft2.static-libs.txt" 2>&1 || true
	find "$pkgconfig_dir" -type f -name '*.pc' -print | sort > "$pkgconfig_dir/pc-manifest.txt"
	local mapping_report="$pkgconfig_dir/text-import-mapping.txt"
	local mapping_status="$pkgconfig_dir/text-import-mapping-status.txt"
	local mapping_bytes capture_complete=no
	local -a mapping_rc=()
	if [ ! -e "$mapping_report" ]; then
		# The outer timeout controls the process group, including internal tools.
		# No result row or gate is derived from this deliberately partial inventory.
		(
			export -f collect_text_import_mapping
			timeout --kill-after=2s 118s bash -c 'collect_text_import_mapping "$@"' \
				_ "$MINGW_PREFIX" "$cxx_exe"
		) 2>&1 | head -c 8388608 > "$mapping_report"
		mapping_rc=("${PIPESTATUS[@]}")
		mapping_bytes="$(wc -c < "$mapping_report")"
		if [ "${mapping_rc[0]}" -eq 0 ] && [ "${mapping_rc[1]}" -eq 0 ] \
			&& [ "$mapping_bytes" -lt 8388608 ]; then
			capture_complete=yes
		fi
		printf 'diagnostic_only=true\ncapture_complete=%s\ncollector_rc=%s\ncapture_rc=%s\nbytes=%s\nbyte_limit=8388608\ntime_limit_seconds=120\nruntime_private_coverage=partial\n' \
			"$capture_complete" "${mapping_rc[0]}" "${mapping_rc[1]}" "$mapping_bytes" > "$mapping_status"
		cat "$mapping_status"
	fi
}

copy_generated_files() {
	local -a roots=("$PWD")
	local candidate
	local destination
	local manifest="$generated_dir/manifest.tsv"
	local generated_dir_abs
	local unix_candidate
	local source_file
	local index=0
	generated_dir_abs="$(cd "$generated_dir" && pwd)"
	printf 'index\tsource\tartifact\n' > "$manifest"
	for candidate in "${RUNNER_TEMP-}" "${TMP-}" "${TEMP-}"; do
		[ -n "$candidate" ] || continue
		unix_candidate="$(to_unix_path "$candidate")"
		if [ -d "$unix_candidate" ]; then
			roots+=("$unix_candidate")
		fi
	done
	while IFS= read -r -d '' source_file; do
		index=$((index + 1))
		destination="$(printf '%03d' "$index")_$(basename "$source_file")"
		cp "$source_file" "$generated_dir/$destination"
		printf '%s\t%s\t%s\n' "$index" "$source_file" "$destination" >> "$manifest"
	done < <(
		find "${roots[@]}" -maxdepth 8 -type f -newer "$marker_file" \
			! -path "$generated_dir_abs/*" \
			\( -name '*.tmp.c' -o -name '*.tmp.c.rsp' -o -name '*.rsp' \) \
			-print0 2>/dev/null || true
	)
}

verify_expected_iconv_outcome() {
	local negative_name="$1"
	local positive_name="$2"
	local required="$3"
	local negative_build_name="${negative_name}_build"
	local positive_build_name="${positive_name}_build"
	local negative_rc="${case_rc[$negative_build_name]:-not-run}"
	local positive_rc="${case_rc[$positive_build_name]:-not-run}"
	local negative_log="$logs_dir/$negative_build_name.log"
	local verify_log="$logs_dir/${negative_name}_iconv_boundary.log"
	local verify_rc=0
	local undefined_pattern='undefined reference|undefined symbol|unresolved external'
	local allowed_iconv_pattern='(libiconv_set_relocation_prefix|libiconv_open|libiconv_close|libiconv)'
	local root_error_pattern='cannot import|cannot find|cannot open|no such file or directory|file format not recognized|file not recognized|permission denied|timed out|internal compiler error|segmentation fault|fatal error'
	local line
	local -a undefined_lines=()
	local -a non_iconv_lines=()

	if [ "$positive_rc" != 0 ]; then
		verify_rc=1
		printf 'The positive control %s failed with exit %s; the iconv boundary is indeterminate.\n' \
			"$positive_name" "$positive_rc" > "$verify_log"
	elif [ "$negative_rc" = 0 ]; then
		echo 'The no-extra-iconv control linked successfully; the package snapshot no longer exposes the expected boundary.' > "$verify_log"
	elif [ "$negative_rc" = 124 ] || [ "$negative_rc" = 137 ]; then
		verify_rc=1
		echo "The no-extra-iconv control timed out or was killed (exit $negative_rc); the iconv boundary is indeterminate." > "$verify_log"
	elif [ ! -f "$negative_log" ]; then
		verify_rc=1
		echo "The no-extra-iconv control failed with exit $negative_rc, but its build log is missing." > "$verify_log"
	elif grep -Eiq "$root_error_pattern" "$negative_log"; then
		verify_rc=1
		{
			echo 'The no-extra-iconv control has a non-linker root error; the iconv boundary is indeterminate:'
			grep -Ei "$root_error_pattern" "$negative_log" || true
		} > "$verify_log"
	else
		mapfile -t undefined_lines < <(grep -Ei "$undefined_pattern" "$negative_log" || true)
		for line in "${undefined_lines[@]}"; do
			if ! grep -Eiq "($undefined_pattern).*([^[:alnum:]_]|^)$allowed_iconv_pattern([^[:alnum:]_]|$)" <<< "$line"; then
				non_iconv_lines+=("$line")
			fi
		done
		if [ "${#undefined_lines[@]}" -eq 0 ]; then
			verify_rc=1
			echo "The no-extra-iconv control failed with exit $negative_rc, but no undefined symbol was found." > "$verify_log"
		elif [ "${#non_iconv_lines[@]}" -ne 0 ]; then
			verify_rc=1
			{
				echo 'The no-extra-iconv control has undefined symbols outside the allowed iconv boundary:'
				printf '%s\n' "${non_iconv_lines[@]}"
			} > "$verify_log"
		else
			{
				echo 'Every undefined symbol in the no-extra-iconv control is at the expected iconv boundary:'
				printf '%s\n' "${undefined_lines[@]}"
			} > "$verify_log"
		fi
	fi
	cat "$verify_log"
	record_result "${negative_name}_iconv_boundary" oracle "$required" "$verify_rc"
}

verify_build_flag() {
	local name="$1"
	local expectation="$2"
	local token="$3"
	local final_link_report="$logs_dir/${name}_final-link.txt"
	local verify_log="$logs_dir/${name}_${expectation}_${token#-}.log"
	local verify_rc=0
	local observed_count=-1
	if [ -f "$final_link_report" ]; then
		observed_count="$(awk -F '\t' -v token="$token" '
			/^argv=/ {
				for (field_index = 2; field_index <= NF; field_index++) if ($field_index == token) count++
			}
			END { print count + 0 }
		' "$final_link_report")"
	fi
	case "$expectation:$observed_count" in
		present:1|absent:0) ;;
		*) verify_rc=1 ;;
	esac
	printf 'final_link_report: %s\nexpected: %s\ntoken: %s\nobserved_count: %s\n' \
		"$final_link_report" "$expectation" "$token" "$observed_count" | tee "$verify_log"
	record_result "${name}_${expectation}_${token#-}" flags yes "$verify_rc"
}

verify_generated_artifacts() {
	local name
	local c_count
	local rsp_count
	local log_file
	local stem
	for name in "${required_v_artifact_cases[@]}"; do
		stem="${artifact_output_stem[$name]}"
		c_count="$(find "$generated_dir" -maxdepth 1 -type f -name "*${stem}.exe*.tmp.c" | wc -l | tr -d '[:space:]')"
		rsp_count="$(find "$generated_dir" -maxdepth 1 -type f -name "*${stem}.exe*.tmp.c.rsp" | wc -l | tr -d '[:space:]')"
		log_file="$logs_dir/${name}_generated_artifacts.log"
		printf 'case: %s\ngenerated_c_count: %s\nresponse_file_count: %s\n' "$name" "$c_count" "$rsp_count" | tee "$log_file"
		if [ "$c_count" -gt 0 ]; then
			record_result "${name}_generated_c" artifact yes 0
		else
			record_result "${name}_generated_c" artifact yes 1
		fi
		# V3 can invoke the linker directly. A response file is evidence, not a
		# prerequisite; the final-link contract is checked from the retained log.
		record_result "${name}_response_file" artifact no "$([ "$rsp_count" -gt 0 ] && echo 0 || echo absent)"
	done
}

verify_final_link_contract() {
	local name="$1"
	local generation="$2"
	local mode="$3"
	local profile="$4"
	local log="$logs_dir/${name}_build.log"
	local flat="$logs_dir/${name}_final-link.txt"
	local expected_output_windows
	local rc=0 rc_v1=0 rc_v3=0 parity_rc=0
	local report_v1="$flat.v1.tmp" report_v3="$flat.v3.tmp"
	local stdout_v1="$flat.v1.stdout.tmp" stdout_v3="$flat.v3.stdout.tmp"
	local stderr_v1="$flat.v1.stderr.tmp" stderr_v3="$flat.v3.stderr.tmp"
	expected_output_windows="$(cygpath -aw "$bin_dir/${output_stem}.exe")" || rc=$?
	if [ "$rc" -eq 0 ]; then
		"$final_link_parser_v1" "$log" "$expected_output_windows" "$generation" "$mode" \
			"$profile" "$lane" "$cc_windows" "$cxx_windows" "$report_v1" \
			>"$stdout_v1" 2>"$stderr_v1" || rc_v1=$?
		"$final_link_parser_v3" "$log" "$expected_output_windows" "$generation" "$mode" \
			"$profile" "$lane" "$cc_windows" "$cxx_windows" "$report_v3" \
			>"$stdout_v3" 2>"$stderr_v3" || rc_v3=$?
		[ "$rc_v1" -eq "$rc_v3" ] || parity_rc=1
		local -a report_pairs=()
		if [ -f "$report_v1" ] && [ -f "$report_v3" ]; then
			report_pairs=("$report_v1" "$report_v3")
		elif [ -e "$report_v1" ] || [ -L "$report_v1" ] || [ -e "$report_v3" ] || [ -L "$report_v3" ]; then
			parity_rc=1
		elif [ "$rc_v1" -eq 0 ]; then
			echo 'final-link parsers succeeded without reports' >&2
			parity_rc=1
		fi
		"$final_link_parser_v1" compare-files "$stdout_v1" "$stdout_v3" "$stderr_v1" "$stderr_v3" \
			"${report_pairs[@]}" || parity_rc=1
		"$final_link_parser_v3" compare-files "$stdout_v1" "$stdout_v3" "$stderr_v1" "$stderr_v3" \
			"${report_pairs[@]}" || parity_rc=1
		cat "$stdout_v1"
		cat "$stderr_v1" >&2
		if [ "$parity_rc" -eq 0 ] && [ "${#report_pairs[@]}" -eq 2 ]; then
			if mv "$report_v1" "$flat"; then
				rm -f "$report_v3"
				if [ ! -f "$flat" ] || [ -L "$flat" ]; then
					echo 'published final-link report is not a regular non-link file' >&2
					parity_rc=1
				fi
			else
				echo 'failed to publish final-link report' >&2
				parity_rc=1
			fi
		fi
		rm -f "$stdout_v1" "$stdout_v3" "$stderr_v1" "$stderr_v3" "$report_v1" "$report_v3"
		if [ "$parity_rc" -ne 0 ]; then
			rc=1
		else
			rc="$rc_v1"
		fi
	fi
	record_result "${name}_final_link" oracle yes "$rc"
}

collect_windows_diagnostics() {
	local collector_windows
	local output_windows
	collector_windows="$(cygpath -w "$windows_collector")"
	output_windows="$(cygpath -w "$windows_dir")"
	run_command windows_error_reporting collect yes \
		powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass \
		-File "$collector_windows" -StartUtc "$diagnostic_start_utc" -OutputDirectory "$output_windows"
}

write_rsp_order_report() {
	local report="$out_dir/rsp-link-order.txt"
	local rsp_file
	local sequence
	local status
	local found=0
	{
		echo 'Expected positive-control order: -lintl ... -liconv'
		for rsp_file in "$generated_dir"/*.rsp; do
			[ -f "$rsp_file" ] || continue
			found=1
			sequence="$(grep -Eo -- '-lintl|-liconv' "$rsp_file" 2>/dev/null | paste -sd ' ' -)"
			case "$sequence" in
				*'-lintl'*'-liconv'*) status='PASS: a later -liconv follows -lintl' ;;
				*'-lintl'*) status='OBSERVED: -lintl without a later -liconv' ;;
				*'-liconv'*) status='OBSERVED: -liconv without -lintl' ;;
				*) status='NOT OBSERVED' ;;
			esac
			printf '\nfile: %s\nsequence: %s\nstatus: %s\n' "$(basename "$rsp_file")" "${sequence:-none}" "$status"
		done
		if [ "$found" -eq 0 ]; then
			echo 'No V response file was retained; inspect the command logs and generated-file manifest.'
		fi
	} > "$report"
	cat "$report"
}

write_summary() {
	local no_iconv_rc="${case_rc[c_static_noiconv_build]:-not-run}"
	local with_iconv_rc="${case_rc[c_static_iconv_build]:-not-run}"
	local raw_pango_oracle_rc="${case_rc[c_static_noiconv_iconv_boundary]:-not-run}"
	local full_no_iconv_rc="${case_rc[c_static_consumer_noiconv_build]:-not-run}"
	local full_with_iconv_rc="${case_rc[c_static_consumer_iconv_build]:-not-run}"
	local full_pango_oracle_rc="${case_rc[c_static_consumer_noiconv_iconv_boundary]:-not-run}"
	local gettext_no_iconv_rc="${case_rc[gettext_static_noiconv_build]:-not-run}"
	local gettext_with_iconv_rc="${case_rc[gettext_static_iconv_build]:-not-run}"
	local gettext_oracle_rc="${case_rc[gettext_static_noiconv_iconv_boundary]:-not-run}"
	local v_no_iconv_rc="${case_rc[vglyph_static_noprod_noiconv_build]:-not-run}"
	local v_with_iconv_rc="${case_rc[vglyph_static_noprod_iconv_build]:-not-run}"
	local v_raw_oracle_rc="${case_rc[vglyph_static_noprod_noiconv_iconv_boundary]:-not-run}"
	local v_manual_no_iconv_rc="${case_rc[vglyph_static_manual_noiconv_build]:-not-run}"
	local v_manual_with_iconv_rc="${case_rc[vglyph_static_manual_iconv_build]:-not-run}"
	local v_manual_oracle_rc="${case_rc[vglyph_static_manual_noiconv_iconv_boundary]:-not-run}"
	local v_s2_rc="${case_rc[vglyph_static_prod_no_prod_options_iconv_build]:-not-run}"
	local v_prod_rc="${case_rc[vglyph_static_prod_iconv_build]:-not-run}"
	local showcase_noprod_rc="${case_rc[showcase_static_noprod_iconv_build]:-not-run}"
	local showcase_s2_rc="${case_rc[showcase_static_prod_no_prod_options_iconv_build]:-not-run}"
	local showcase_prod_rc="${case_rc[showcase_static_prod_iconv_build]:-not-run}"
	local github_summary
	local s3_label='full prod/LTO for V3; full prod without LTO for V1 Windows Clang'
	if [ "$cc" = gcc ]; then
		s3_label='full prod/LTO'
	fi
	{
		echo "## GUI issue #74 — $MSYSTEM $cc"
		echo
		echo '| Case | Phase | Required | Exit |'
		echo '|---|---|---:|---:|'
		awk -F '\t' 'NR > 1 { printf "| `%s` | %s | %s | %s |\n", $1, $2, $3, $4 }' "$results_file"
		echo
		echo '### Discriminating results'
		echo
		echo "- Toolchain: MSYS2 $MSYSTEM $cc."
		echo "- Raw Pango/pkgconf C-driver static: without an explicit final \`-liconv\`=$no_iconv_rc; with it=$with_iconv_rc; exclusive-iconv classification=$raw_pango_oracle_rc."
		echo "- Completed Pango static consumer (GLib static macros + $cxx driver): without \`-liconv\`=$full_no_iconv_rc; with final \`-liconv\`=$full_with_iconv_rc; exclusive-iconv classification=$full_pango_oracle_rc."
		echo "- Direct gettext C static: without \`-liconv\`=$gettext_no_iconv_rc; with it=$gettext_with_iconv_rc; exclusive-iconv classification=$gettext_oracle_rc."
		echo "- Reporter-faithful vglyph static non-prod: without iconv=$v_no_iconv_rc; with iconv=$v_with_iconv_rc; exclusive-iconv classification=$v_raw_oracle_rc."
		echo "- Historical manual-closure fields are retained only for artifact schema compatibility; no concrete C++ runtime is injected."
		echo "- Reporter-flag vglyph with iconv: non-prod=$v_with_iconv_rc; S2 prod/no-prod-options=$v_s2_rc; S3 $s3_label=$v_prod_rc."
		echo "- Reporter-flag showcase with iconv: non-prod=$showcase_noprod_rc; S2 prod/no-prod-options=$showcase_s2_rc; S3 $s3_label=$showcase_prod_rc."
		echo '- Showcase is a public, link-only surrogate for the private application; its GUI executable is not launched on the runner.'
		echo '- Static PE architecture/subsystem/imports, retained C/RSP files, link order, and S2/S3 flags are required gates.'
		echo "- Targeted Event Viewer and textual WER metadata are under \`windows/\`; memory dumps are never uploaded."
		echo "- Required command failures: $required_failures."
		echo
		if [ "$raw_pango_oracle_rc" = 0 ] && [ "$no_iconv_rc" != 0 ] && [ "$no_iconv_rc" != not-run ]; then
			echo '- The raw Pango/pkgconf C-driver pair isolates a missing static iconv edge in external metadata/order.'
		elif [ "$no_iconv_rc" = 0 ]; then
			echo "- The current MSYS2 package snapshot links the raw C oracle without an explicit final \`-liconv\`; inspect pkgconf and symbol artifacts for package drift."
		elif [ "$raw_pango_oracle_rc" != 0 ] && [ "$raw_pango_oracle_rc" != not-run ]; then
			echo '- The raw Pango/pkgconf failure is not exclusively iconv; inspect static GLib import macros and C++ runtime edges separately.'
		fi
		if [ "$full_pango_oracle_rc" = 0 ] && [ "$full_no_iconv_rc" != 0 ] && [ "$full_no_iconv_rc" != not-run ]; then
			echo '- After supplying the documented static-consumer macros and C++ driver, the completed Pango control isolates the final iconv edge.'
		fi
		if [ "$gettext_oracle_rc" = 0 ] && [ "$gettext_no_iconv_rc" != 0 ] && [ "$gettext_no_iconv_rc" != not-run ]; then
			echo '- The direct gettext pair independently isolates the libintl-to-iconv static edge without Pango, GLib, HarfBuzz, or Graphite.'
		fi
		if [ "$v_raw_oracle_rc" != 0 ] && [ "$v_raw_oracle_rc" != not-run ]; then
			echo '- The reporter-faithful V pair is not exclusively an iconv boundary; it remains the end-to-end resolution gate, not the manual closure control.'
		fi
		if [ "$v_manual_oracle_rc" = 0 ] && [ "$v_manual_no_iconv_rc" != 0 ] && [ "$v_manual_no_iconv_rc" != not-run ]; then
			echo '- The separately labelled V manual-closure pair isolates iconv after supplying static GLib/C++ consumer requirements; it is not the reporter command.'
		fi
		if [ "$v_with_iconv_rc" = 0 ] && [ "$v_prod_rc" != 0 ] && [ "$v_prod_rc" != not-run ]; then
			echo "- vglyph passes without \`-prod\` and fails in S3; isolate $cc $s3_label before changing dependency metadata."
		fi
		if [ "$showcase_noprod_rc" = 0 ] && [ "$showcase_prod_rc" != 0 ] && [ "$showcase_prod_rc" != not-run ]; then
			echo '- The large public GUI example isolates the remaining failure to its production build.'
		fi
	} > "$summary_file"
	cat "$summary_file"
	if [ -n "${GITHUB_STEP_SUMMARY-}" ]; then
		github_summary="$(to_unix_path "$GITHUB_STEP_SUMMARY")"
		cat "$summary_file" >> "$github_summary"
	fi
}

write_environment_report
copy_pkgconfig_metadata

read -r -a pango_cflags <<< "$(pkgconf --cflags pangoft2 2>/dev/null || true)"
pango_cflags=()
pango_dynamic_libs=()
pango_static_libs=()
read -r -a pango_cflags <<< "$(pkgconf --cflags pangoft2)"
read -r -a pango_dynamic_libs <<< "$(pkgconf --libs pangoft2)"
read -r -a pango_static_libs <<< "$(pkgconf --static --libs pangoft2)"
run_command vglyph_module_check check yes "$v_exe" -old-compiler -check "$probe_v"

# External-metadata controls: the negative cases classify the boundary, while
# the positive cases must build and run. They never alter a VGlyph invocation.
c_dynamic_exe="$bin_dir/c_dynamic.exe"
run_command c_dynamic_build build yes "$cc" "${pango_cflags[@]}" "$probe_c" \
	-o "$c_dynamic_exe" "${pango_dynamic_libs[@]}"
c_dynamic_rc="$last_rc"
run_built_executable c_dynamic yes "$c_dynamic_exe" "$c_dynamic_rc"

pango_obj="$generated_dir/pango-static.o"
run_command pango_static_compile build yes "$cc" -c -DGLIB_STATIC_COMPILATION \
	-DGOBJECT_STATIC_COMPILATION "${pango_cflags[@]}" "$probe_c" -o "$pango_obj"
run_command pango_static_noiconv_build build no "$cxx" -static "$pango_obj" \
	-o "$bin_dir/pango_static_noiconv.exe" "${pango_static_libs[@]}"
pango_negative_rc="$last_rc"
run_command pango_static_iconv_build build yes "$cxx" -static "$pango_obj" \
	-o "$bin_dir/pango_static_iconv.exe" "${pango_static_libs[@]}" -liconv
pango_positive_rc="$last_rc"
verify_expected_iconv_outcome pango_static_noiconv pango_static_iconv yes
run_built_executable pango_static_iconv yes "$bin_dir/pango_static_iconv.exe" "$pango_positive_rc"

run_command gettext_static_noiconv_build build no "$cc" -static "$gettext_probe_c" \
	-o "$bin_dir/gettext_static_noiconv.exe" -lintl
gettext_negative_rc="$last_rc"
run_command gettext_static_iconv_build build yes "$cc" -static "$gettext_probe_c" \
	-o "$bin_dir/gettext_static_iconv.exe" -lintl -liconv
gettext_positive_rc="$last_rc"
verify_expected_iconv_outcome gettext_static_noiconv gettext_static_iconv yes
run_built_executable gettext_static_iconv yes "$bin_dir/gettext_static_iconv.exe" "$gettext_positive_rc"

if [ -z "${V3_GNU_STANDALONE-}" ]; then
	echo 'V3_GNU_STANDALONE is required' >&2
	exit 2
fi
v3_exe="$(to_unix_path "$V3_GNU_STANDALONE")"
vroot="$(cd -- "$(dirname -- "$v_exe")" && pwd)"
if [ ! -d "$gui_dir" ] || [ -L "$gui_dir" ]; then
	echo "GUI module directory is missing or unsafe: $gui_dir" >&2
	exit 2
fi
gui_parent="$(dirname -- "$(realpath "$gui_dir")")"
if [ ! -d "$gui_parent" ] || [ -L "$gui_parent" ]; then
	echo "GUI module parent is missing or unsafe: $gui_parent" >&2
	exit 2
fi
vlib_path="$(cygpath -aw "$vroot/vlib")|$(cygpath -aw "$gui_parent")|@vlib|@vmodules"
[ -x "$v3_exe" ] || { echo "standalone V3 is not executable: $v3_exe" >&2; exit 2; }

# Candidate builds rely exclusively on pkg-config metadata and VGlyph's generic
# static C++ linker request. No concrete C++ runtime or manual iconv flag is injected.
for generation in v1 v3; do
	if [ "$generation" = v1 ]; then
		active_v_exe="$v_exe"
		generation_args=(-old-compiler)
	else
		active_v_exe="$v3_exe"
		generation_args=(-gc none -path "$vlib_path")
	fi
	for mode in dynamic static; do
		for profile in dev s2 s3; do
			passes=(cold warm)
			for pass in "${passes[@]}"; do
				state_dir="$out_dir/state/$generation/$mode/$profile"
				mkdir -p "$state_dir/vcache" "$state_dir/v3cache" "$state_dir/vtmp"
				export VCACHE="$(cygpath -aw "$state_dir/vcache")"
				export V3CACHE="$(cygpath -aw "$state_dir/v3cache")"
				export VTMP="$(cygpath -aw "$state_dir/vtmp")"
				args=("${generation_args[@]}" -cc "$cc_windows" -c++ "$cxx_windows")
				[ "$mode" = static ] && args+=(-cflags -static)
				case "$profile" in
					dev) ;;
					s2) args+=(-prod -no-prod-options) ;;
					s3) args+=(-prod) ;;
				esac
				if [ "$generation:$profile:$lane" = v3:s3:ucrt64-clang ]; then
					args+=(-ldflags -fuse-ld=lld)
				fi
				name="vglyph_${generation}_${mode}_${profile}_${pass}"
				output_stem="vglyph_${generation}_${mode}_${profile}"
				run_v_build "$name" yes "$probe_v" "${args[@]}"
				rc="$last_rc"
				verify_final_link_contract "$name" "$generation" "$mode" "$profile"
				run_built_executable "$name" yes "$bin_dir/$output_stem.exe" "$rc"
				if [ "$profile" = s2 ]; then
					verify_build_flag "$name" absent -flto
				elif [ "$profile" = s3 ]; then
					if [ "$cc" = gcc ] || [ "$generation" = v3 ]; then
						verify_build_flag "$name" present -flto
					else
						verify_build_flag "$name" absent -flto
					fi
					showcase_name="showcase_${generation}_${mode}_${profile}_${pass}"
					output_stem="$showcase_name"
					showcase_args=("${args[@]}")
					if [ "$generation" = v3 ]; then
						showcase_args+=(-no-memory-limit)
					fi
					run_v_build "$showcase_name" yes "$showcase_v" "${showcase_args[@]}" -ldflags -mwindows
					verify_final_link_contract "$showcase_name" "$generation" "$mode" "$profile"
					if [ "$cc" = gcc ] || [ "$generation" = v3 ]; then
						verify_build_flag "$showcase_name" present -flto
					else
						verify_build_flag "$showcase_name" absent -flto
					fi
				fi
			done
		done
	done
done

copy_generated_files
copy_pkgconfig_metadata
verify_generated_artifacts
write_environment_report
collect_windows_diagnostics
case "$out_dir/state" in "$out_dir"/*) find "$out_dir/state" -depth -delete 2>/dev/null || true ;; esac
{
	echo "## GUI issue #74 — $MSYSTEM $cc"
	echo
	echo '| Case | Phase | Required | Exit |'
	echo '|---|---|---:|---:|'
	awk -F '\t' 'NR > 1 { printf "| `%s` | %s | %s | %s |\n", $1, $2, $3, $4 }' "$results_file"
	echo
	echo "Required command failures: $required_failures."
} > "$summary_file"
cat "$summary_file"
if [ -n "${GITHUB_STEP_SUMMARY-}" ]; then
	cat "$summary_file" >> "$(to_unix_path "$GITHUB_STEP_SUMMARY")"
fi
find "$bin_dir" -maxdepth 1 -type f -name '*.exe' -delete
exit "$required_failures"
