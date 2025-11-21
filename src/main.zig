const std = @import("std");
const posix = std.posix;

const c = @cImport(@cInclude("chibicc.h"));
const c_error = @field(c, "error");

const FileType = enum(c_int) {
    FILE_NONE,
    FILE_C,
    FILE_ASM,
    FILE_OBJ,
    FILE_AR,
    FILE_DSO,
};

// Globals consumed from C.
pub export var include_paths: c.StringArray = .{ .data = null, .capacity = 0, .len = 0 };
pub export var opt_fcommon: bool = true;
pub export var opt_fpic: bool = false;
pub export var base_file: [*c]u8 = null;

// Driver-only state.
var opt_x: FileType = .FILE_NONE;
var opt_include: c.StringArray = .{ .data = null, .capacity = 0, .len = 0 };
var opt_E: bool = false;
var opt_M: bool = false;
var opt_MD: bool = false;
var opt_MMD: bool = false;
var opt_MP: bool = false;
var opt_S: bool = false;
var opt_c_flag: bool = false;
var opt_cc1: bool = false;
var opt_hash_hash_hash: bool = false;
var opt_static: bool = false;
var opt_shared: bool = false;
var opt_MF: [*c]u8 = null;
var opt_MT: [*c]u8 = null;
var opt_o: [*c]u8 = null;

var ld_extra_args: c.StringArray = .{ .data = null, .capacity = 0, .len = 0 };
var std_include_paths: c.StringArray = .{ .data = null, .capacity = 0, .len = 0 };

var input_paths: c.StringArray = .{ .data = null, .capacity = 0, .len = 0 };
var tmpfiles: c.StringArray = .{ .data = null, .capacity = 0, .len = 0 };

const allocator = std.heap.c_allocator;

fn usage(status: c_int) noreturn {
    _ = c.fprintf(c.stderr, "chibicc [ -o <path> ] <file>\n");
    std.process.exit(@as(u8, @intCast(status)));
}

fn take_arg(arg: [*c]const u8) bool {
    const opts = [_][*c]const u8{
        "-o",
        "-I",
        "-idirafter",
        "-include",
        "-x",
        "-MF",
        "-MT",
        "-Xlinker",
    };

    var i: usize = 0;
    while (i < opts.len) : (i += 1) {
        if (c.strcmp(arg, opts[i]) == 0) return true;
    }
    return false;
}

inline fn argAt(argv: [*c][*c]u8, idx: c_int) [*c]u8 {
    return argv[@as(usize, @intCast(idx))];
}

inline fn cfmt(comptime s: []const u8) [*c]u8 {
    return @as([*c]u8, @ptrCast(@constCast(s.ptr)));
}

inline fn errnoToCInt(err: posix.E) c_int {
    return @as(c_int, @intCast(@intFromEnum(err)));
}

fn add_default_include_paths(argv0: [*c]u8) void {
    const include_fmt: [*c]u8 = cfmt("%s/include");
    // We expect that chibicc-specific include files are installed
    // to ./include relative to argv[0].
    c.strarray_push(&include_paths, c.format(include_fmt, c.dirname(c.strdup(argv0))));

    // Add standard include paths.
    c.strarray_push(&include_paths, cfmt("/usr/local/include"));
    c.strarray_push(&include_paths, cfmt("/usr/include/x86_64-linux-gnu"));
    c.strarray_push(&include_paths, cfmt("/usr/include"));

    // Keep a copy of the standard include paths for -MMD option.
    var i: usize = 0;
    while (i < @as(usize, @intCast(include_paths.len))) : (i += 1) {
        c.strarray_push(&std_include_paths, include_paths.data[i]);
    }
}

fn define_macro_option(str: [*c]u8) void {
    const eq = c.strchr(str, '=');
    if (eq != null) {
        const len = @as(usize, @intCast(eq - str));
        const name = c.strndup(str, len);
        c.define_macro(name, eq + 1);
    } else {
        c.define_macro(str, cfmt("1"));
    }
}

fn parse_opt_x(s: [*c]const u8) FileType {
    if (c.strcmp(s, "c") == 0) return .FILE_C;
    if (c.strcmp(s, "assembler") == 0) return .FILE_ASM;
    if (c.strcmp(s, "none") == 0) return .FILE_NONE;
    c_error(cfmt("<command line>: unknown argument for -x: %s"), s);
}

fn quote_makefile(s: [*c]const u8) [*c]u8 {
    const len = c.strlen(s);
    const buf: [*c]u8 = @ptrCast(c.calloc(len * 2 + 1, 1));
    var i: usize = 0;
    var j: usize = 0;
    while (s[i] != 0) : (i += 1) {
        switch (s[i]) {
            '$' => {
                buf[j] = '$';
                buf[j + 1] = '$';
                j += 2;
            },
            '#' => {
                buf[j] = '\\';
                buf[j + 1] = '#';
                j += 2;
            },
            ' ', '\t' => {
                var k: isize = @as(isize, @intCast(i)) - 1;
                while (k >= 0 and s[@as(usize, @intCast(k))] == '\\') : (k -= 1) {
                    buf[j] = '\\';
                    j += 1;
                }
                buf[j] = '\\';
                buf[j + 1] = s[i];
                j += 2;
            },
            else => {
                buf[j] = s[i];
                j += 1;
            },
        }
    }
    return buf;
}

fn parse_args(argc: c_int, argv: [*c][*c]u8) void {
    // Make sure that all command line options that take an argument have an argument.
    var i: c_int = 1;
    while (i < argc) : (i += 1) {
        const arg = argAt(argv, i);
        if (take_arg(arg)) {
            if (i + 1 >= argc) usage(1);
            i += 1;
        }
    }

    var idirafter = c.StringArray{ .data = null, .capacity = 0, .len = 0 };

    i = 1;
    while (i < argc) : (i += 1) {
        const arg = argAt(argv, i);
        if (c.strcmp(arg, "-###") == 0) {
            opt_hash_hash_hash = true;
            continue;
        }
        if (c.strcmp(arg, "-cc1") == 0) {
            opt_cc1 = true;
            continue;
        }
        if (c.strcmp(arg, "--help") == 0) usage(0);
        if (c.strcmp(arg, "-o") == 0) {
            i += 1;
            opt_o = argAt(argv, i);
            continue;
        }
        if (c.strncmp(arg, "-o", 2) == 0) {
            opt_o = arg + 2;
            continue;
        }
        if (c.strcmp(arg, "-S") == 0) {
            opt_S = true;
            continue;
        }
        if (c.strcmp(arg, "-fcommon") == 0) {
            opt_fcommon = true;
            continue;
        }
        if (c.strcmp(arg, "-fno-common") == 0) {
            opt_fcommon = false;
            continue;
        }
        if (c.strcmp(arg, "-c") == 0) {
            opt_c_flag = true;
            continue;
        }
        if (c.strcmp(arg, "-E") == 0) {
            opt_E = true;
            continue;
        }
        if (c.strncmp(arg, "-I", 2) == 0) {
            c.strarray_push(&include_paths, arg + 2);
            continue;
        }
        if (c.strcmp(arg, "-D") == 0) {
            i += 1;
            define_macro_option(argAt(argv, i));
            continue;
        }
        if (c.strncmp(arg, "-D", 2) == 0) {
            define_macro_option(arg + 2);
            continue;
        }
        if (c.strcmp(arg, "-U") == 0) {
            i += 1;
            c.undef_macro(argAt(argv, i));
            continue;
        }
        if (c.strncmp(arg, "-U", 2) == 0) {
            c.undef_macro(arg + 2);
            continue;
        }
        if (c.strcmp(arg, "-include") == 0) {
            i += 1;
            c.strarray_push(&opt_include, argAt(argv, i));
            continue;
        }
        if (c.strcmp(arg, "-x") == 0) {
            i += 1;
            opt_x = parse_opt_x(argAt(argv, i));
            continue;
        }
        if (c.strncmp(arg, "-x", 2) == 0) {
            opt_x = parse_opt_x(arg + 2);
            continue;
        }
        if (c.strncmp(arg, "-l", 2) == 0 or c.strncmp(arg, "-Wl,", 4) == 0) {
            c.strarray_push(&input_paths, arg);
            continue;
        }
        if (c.strcmp(arg, "-Xlinker") == 0) {
            i += 1;
            c.strarray_push(&ld_extra_args, argAt(argv, i));
            continue;
        }
        if (c.strcmp(arg, "-s") == 0) {
            c.strarray_push(&ld_extra_args, cfmt("-s"));
            continue;
        }
        if (c.strcmp(arg, "-M") == 0) {
            opt_M = true;
            continue;
        }
        if (c.strcmp(arg, "-MF") == 0) {
            i += 1;
            opt_MF = argAt(argv, i);
            continue;
        }
        if (c.strcmp(arg, "-MP") == 0) {
            opt_MP = true;
            continue;
        }
        if (c.strcmp(arg, "-MT") == 0) {
            i += 1;
            if (opt_MT == null) {
                opt_MT = argAt(argv, i);
            } else {
                opt_MT = c.format(cfmt("%s %s"), opt_MT, argAt(argv, i));
            }
            continue;
        }
        if (c.strcmp(arg, "-MD") == 0) {
            opt_MD = true;
            continue;
        }
        if (c.strcmp(arg, "-MQ") == 0) {
            i += 1;
            if (opt_MT == null) {
                opt_MT = quote_makefile(argAt(argv, i));
            } else {
                opt_MT = c.format(cfmt("%s %s"), opt_MT, quote_makefile(argAt(argv, i)));
            }
            continue;
        }
        if (c.strcmp(arg, "-MMD") == 0) {
            opt_MD = true;
            opt_MMD = true;
            continue;
        }
        if (c.strcmp(arg, "-fpic") == 0 or c.strcmp(arg, "-fPIC") == 0) {
            opt_fpic = true;
            continue;
        }
        if (c.strcmp(arg, "-cc1-input") == 0) {
            i += 1;
            base_file = argAt(argv, i);
            continue;
        }
        if (c.strcmp(arg, "-cc1-output") == 0) {
            i += 1;
            opt_o = argAt(argv, i);
            continue;
        }
        if (c.strcmp(arg, "-idirafter") == 0) {
            i += 1;
            c.strarray_push(&idirafter, argAt(argv, i));
            continue;
        }
        if (c.strcmp(arg, "-static") == 0) {
            opt_static = true;
            c.strarray_push(&ld_extra_args, cfmt("-static"));
            continue;
        }
        if (c.strcmp(arg, "-shared") == 0) {
            opt_shared = true;
            c.strarray_push(&ld_extra_args, cfmt("-shared"));
            continue;
        }
        if (c.strcmp(arg, "-L") == 0) {
            i += 1;
            c.strarray_push(&ld_extra_args, cfmt("-L"));
            c.strarray_push(&ld_extra_args, argAt(argv, i));
            continue;
        }
        if (c.strncmp(arg, "-L", 2) == 0) {
            c.strarray_push(&ld_extra_args, cfmt("-L"));
            c.strarray_push(&ld_extra_args, arg + 2);
            continue;
        }
        if (c.strcmp(arg, "-hashmap-test") == 0) {
            c.hashmap_test();
            std.process.exit(0);
        }
        // Ignore currently unsupported flags for now.
        if (c.strncmp(arg, "-O", 2) == 0 or c.strncmp(arg, "-W", 2) == 0 or c.strncmp(arg, "-g", 2) == 0 or
            c.strncmp(arg, "-std=", 5) == 0 or c.strcmp(arg, "-ffreestanding") == 0 or c.strcmp(arg, "-fno-builtin") == 0 or
            c.strcmp(arg, "-fno-omit-frame-pointer") == 0 or c.strcmp(arg, "-fno-stack-protector") == 0 or
            c.strcmp(arg, "-fno-strict-aliasing") == 0 or c.strcmp(arg, "-m64") == 0 or c.strcmp(arg, "-mno-red-zone") == 0 or
            c.strcmp(arg, "-w") == 0)
        {
            continue;
        }

        if (arg[0] == '-' and arg[1] != 0) c_error(cfmt("unknown argument: %s"), arg);
        c.strarray_push(&input_paths, arg);
    }

    var j: usize = 0;
    while (j < @as(usize, @intCast(idirafter.len))) : (j += 1) {
        c.strarray_push(&include_paths, idirafter.data[j]);
    }

    if (input_paths.len == 0) c_error(cfmt("no input files"));

    // -E implies that the input is the C macro language.
    if (opt_E) opt_x = .FILE_C;
}

fn open_file(path: [*c]u8) *c.FILE {
    if (path == null or c.strcmp(path, cfmt("-")) == 0) return c.stdout.?;
    const out = c.fopen(path, "w");
    if (out == null) {
        const err = posix.errno(-1);
        c_error(cfmt("cannot open output file: %s: %s"), path, c.strerror(errnoToCInt(err)));
    }
    return out.?;
}

fn endswith(p: [*c]const u8, q: [*c]const u8) bool {
    const len1 = c.strlen(p);
    const len2 = c.strlen(q);
    return len1 >= len2 and c.strcmp(p + @as(usize, @intCast(len1 - len2)), q) == 0;
}

fn replace_extn(tmpl: [*c]const u8, extn: [*c]const u8) [*c]u8 {
    const filename = c.basename(c.strdup(tmpl));
    const dot = c.strrchr(filename, '.');
    if (dot != null) dot.* = 0;
    return c.format(cfmt("%s%s"), filename, extn);
}

fn cleanup() void {
    var i: usize = 0;
    while (i < @as(usize, @intCast(tmpfiles.len))) : (i += 1) {
        _ = c.unlink(tmpfiles.data[i]);
    }
}

fn create_tmpfile() [*c]u8 {
    const path = c.strdup("/tmp/chibicc-XXXXXX");
    const fd = c.mkstemp(path);
    if (fd == -1) {
        const err = posix.errno(-1);
        c_error(cfmt("mkstemp failed: %s"), c.strerror(errnoToCInt(err)));
    }
    _ = c.close(fd);
    c.strarray_push(&tmpfiles, path);
    return path;
}

fn run_subprocess(argv: [*c][*c]u8) void {
    // If -### is given, dump the subprocess's command line.
    if (opt_hash_hash_hash) {
        var idx: usize = 0;
        while (argv[idx] != null) : (idx += 1) {
            if (idx == 0) {
                _ = c.fprintf(c.stderr, "%s", argv[idx]);
            } else {
                _ = c.fprintf(c.stderr, " %s", argv[idx]);
            }
        }
        _ = c.fprintf(c.stderr, "\n");
    }

    const pid = c.fork();
    if (pid == 0) {
        _ = c.execvp(argv[0], argv);
        const err = posix.errno(-1);
        _ = c.fprintf(c.stderr, "exec failed: %s: %s\n", argv[0], c.strerror(errnoToCInt(err)));
        c._exit(1);
    }

    var status: c_int = 0;
    while (c.wait(&status) > 0) {}
    if (status != 0) std.process.exit(1);
}

fn run_cc1(argc: c_int, argv: [*c][*c]u8, input: ?[*c]u8, output: ?[*c]u8) void {
    const base_count = @as(usize, @intCast(argc));
    const total = base_count + 10;
    var args_list = allocator.alloc([*c]u8, total) catch unreachable;
    defer allocator.free(args_list);

    var idx: usize = 0;
    while (idx < base_count) : (idx += 1) {
        args_list[idx] = argv[idx];
    }

    args_list[idx] = cfmt("-cc1");
    idx += 1;

    if (input) |inp| {
        args_list[idx] = cfmt("-cc1-input");
        args_list[idx + 1] = inp;
        idx += 2;
    }

    if (output) |outp| {
        args_list[idx] = cfmt("-cc1-output");
        args_list[idx + 1] = outp;
        idx += 2;
    }

    args_list[idx] = null;
    const args_ptr: [*c][*c]u8 = @as([*c][*c]u8, @ptrCast(args_list.ptr));
    run_subprocess(args_ptr);
}

fn print_tokens(tok_start: *c.Token) void {
    const out_file = open_file(if (opt_o != null) opt_o else cfmt("-"));
    var tok = tok_start;
    var line: c_int = 1;
    while (tok.*.kind != c.TK_EOF) : (tok = tok.*.next) {
        if (line > 1 and tok.*.at_bol) _ = c.fprintf(out_file, "\n");
        if (tok.*.has_space and !tok.*.at_bol) _ = c.fprintf(out_file, " ");
        _ = c.fprintf(out_file, "%.*s", tok.*.len, tok.*.loc);
        line += 1;
    }
    _ = c.fprintf(out_file, "\n");
}

fn in_std_include_path(path: [*c]const u8) bool {
    var i: usize = 0;
    while (i < @as(usize, @intCast(std_include_paths.len))) : (i += 1) {
        const dir = std_include_paths.data[i];
        const len = c.strlen(dir);
        if (c.strncmp(dir, path, len) == 0 and path[len] == '/') return true;
    }
    return false;
}

fn print_dependencies() void {
    var path: [*c]u8 = null;
    if (opt_MF != null) {
        path = opt_MF;
    } else if (opt_MD) {
        path = replace_extn(if (opt_o != null) opt_o else base_file, ".d");
    } else if (opt_o != null) {
        path = opt_o;
    } else {
        path = cfmt("-");
    }

    const out = open_file(path);

    if (opt_MT != null) {
        _ = c.fprintf(out, "%s:", opt_MT);
    } else {
        _ = c.fprintf(out, "%s:", quote_makefile(replace_extn(base_file, ".o")));
    }

    const files = c.get_input_files();
    var i: usize = 0;
    while (files[i] != null) : (i += 1) {
        if (opt_MMD and in_std_include_path(files[i].*.name)) continue;
        _ = c.fprintf(out, " \\\n  %s", files[i].*.name);
    }
    _ = c.fprintf(out, "\n\n");

    if (opt_MP) {
        var j: usize = 1;
        while (files[j] != null) : (j += 1) {
            if (opt_MMD and in_std_include_path(files[j].*.name)) continue;
            _ = c.fprintf(out, "%s:\n\n", quote_makefile(files[j].*.name));
        }
    }
}

fn must_tokenize_file(path: [*c]u8) *c.Token {
    const tok = c.tokenize_file(path);
    if (tok == null) {
        const err = posix.errno(-1);
        c_error(cfmt("%s: %s"), path, c.strerror(errnoToCInt(err)));
    }
    return tok;
}

fn append_tokens(tok1: ?*c.Token, tok2: *c.Token) *c.Token {
    const head = tok1 orelse return tok2;
    if (head.*.kind == c.TK_EOF) return tok2;
    var t = head;
    while (t.*.next.*.kind != c.TK_EOF) {
        t = t.*.next;
    }
    t.*.next = tok2;
    return head;
}

fn cc1() void {
    var tok: ?*c.Token = null;

    var i: usize = 0;
    while (i < @as(usize, @intCast(opt_include.len))) : (i += 1) {
        const incl = opt_include.data[i];
        var path: [*c]u8 = null;
        if (file_exists(incl)) {
            path = incl;
        } else {
            path = c.search_include_paths(incl);
            if (path == null) {
                const err = posix.errno(-1);
                c_error(cfmt("-include: %s: %s"), incl, c.strerror(errnoToCInt(err)));
            }
        }
        const tok2 = must_tokenize_file(path);
        tok = append_tokens(tok, tok2);
    }

    const tok2 = must_tokenize_file(base_file);
    tok = append_tokens(tok, tok2);
    tok = c.preprocess(tok.?);

    if (opt_M or opt_MD) {
        print_dependencies();
        if (opt_M) return;
    }

    const tok_nonnull = tok.?;
    if (opt_E) {
        print_tokens(tok_nonnull);
        return;
    }

    const prog = c.parse(tok_nonnull);

    var buf: [*c]u8 = undefined;
    var buflen: usize = 0;
    const output_buf = c.open_memstream(&buf, &buflen);

    c.codegen(prog, output_buf);
    _ = c.fclose(output_buf);

    const out = open_file(opt_o);
    _ = c.fwrite(buf, buflen, 1, out);
    _ = c.fclose(out);
}

fn assemble(input: [*c]u8, output: [*c]u8) void {
    var cmd = [_][*c]u8{ cfmt("as"), cfmt("-c"), input, cfmt("-o"), output };
    var arr = [_][*c]u8{ cmd[0], cmd[1], cmd[2], cmd[3], cmd[4], null };
    run_subprocess(&arr);
}

fn find_file(pattern: [*c]u8) [*c]u8 {
    var path: [*c]u8 = null;
    var buf: c.glob_t = .{};
    if (c.glob(pattern, 0, null, &buf) == 0) {
        if (buf.gl_pathc > 0) {
            // pick last entry to mirror original behavior
            path = c.strdup(buf.gl_pathv[buf.gl_pathc - 1]);
        }
    }
    c.globfree(&buf);
    return path;
}

// Returns true if a given file exists.
pub export fn file_exists(path: [*c]const u8) bool {
    var st: c.struct_stat = undefined;
    return c.stat(path, &st) == 0;
}

fn find_libpath() [*c]u8 {
    if (file_exists(cfmt("/usr/lib/x86_64-linux-gnu/crti.o"))) return cfmt("/usr/lib/x86_64-linux-gnu");
    if (file_exists(cfmt("/usr/lib64/crti.o"))) return cfmt("/usr/lib64");
    c_error(cfmt("library path is not found"));
}

fn find_gcc_libpath() [*c]u8 {
    const paths = [_][*c]u8{
        cfmt("/usr/lib/gcc/x86_64-linux-gnu/*/crtbegin.o"),
        cfmt("/usr/lib/gcc/x86_64-pc-linux-gnu/*/crtbegin.o"),
        cfmt("/usr/lib/gcc/x86_64-redhat-linux/*/crtbegin.o"),
    };

    var i: usize = 0;
    while (i < paths.len) : (i += 1) {
        const path = find_file(paths[i]);
        if (path != null) return c.dirname(path);
    }

    c_error(cfmt("gcc library path is not found"));
}

fn run_linker(inputs: *c.StringArray, output: [*c]u8) void {
    var arr = c.StringArray{ .data = null, .capacity = 0, .len = 0 };

    c.strarray_push(&arr, cfmt("ld"));
    c.strarray_push(&arr, cfmt("-o"));
    c.strarray_push(&arr, output);
    c.strarray_push(&arr, cfmt("-m"));
    c.strarray_push(&arr, cfmt("elf_x86_64"));

    const libpath = find_libpath();
    const gcc_libpath = find_gcc_libpath();

    if (opt_shared) {
        c.strarray_push(&arr, c.format(cfmt("%s/crti.o"), libpath));
        c.strarray_push(&arr, c.format(cfmt("%s/crtbeginS.o"), gcc_libpath));
    } else {
        c.strarray_push(&arr, c.format(cfmt("%s/crt1.o"), libpath));
        c.strarray_push(&arr, c.format(cfmt("%s/crti.o"), libpath));
        c.strarray_push(&arr, c.format(cfmt("%s/crtbegin.o"), gcc_libpath));
    }

    c.strarray_push(&arr, c.format(cfmt("-L%s"), gcc_libpath));
    c.strarray_push(&arr, cfmt("-L/usr/lib/x86_64-linux-gnu"));
    c.strarray_push(&arr, cfmt("-L/usr/lib64"));
    c.strarray_push(&arr, cfmt("-L/lib64"));
    c.strarray_push(&arr, cfmt("-L/usr/lib/x86_64-linux-gnu"));
    c.strarray_push(&arr, cfmt("-L/usr/lib/x86_64-pc-linux-gnu"));
    c.strarray_push(&arr, cfmt("-L/usr/lib/x86_64-redhat-linux"));
    c.strarray_push(&arr, cfmt("-L/usr/lib"));
    c.strarray_push(&arr, cfmt("-L/lib"));

    if (!opt_static) {
        c.strarray_push(&arr, cfmt("-dynamic-linker"));
        c.strarray_push(&arr, cfmt("/lib64/ld-linux-x86-64.so.2"));
    }

    var i: usize = 0;
    while (i < @as(usize, @intCast(ld_extra_args.len))) : (i += 1) {
        c.strarray_push(&arr, ld_extra_args.data[i]);
    }

    i = 0;
    while (i < @as(usize, @intCast(inputs.len))) : (i += 1) {
        c.strarray_push(&arr, inputs.data[i]);
    }

    if (opt_static) {
        c.strarray_push(&arr, cfmt("--start-group"));
        c.strarray_push(&arr, cfmt("-lgcc"));
        c.strarray_push(&arr, cfmt("-lgcc_eh"));
        c.strarray_push(&arr, cfmt("-lc"));
        c.strarray_push(&arr, cfmt("--end-group"));
    } else {
        c.strarray_push(&arr, cfmt("-lc"));
        c.strarray_push(&arr, cfmt("-lgcc"));
        c.strarray_push(&arr, cfmt("--as-needed"));
        c.strarray_push(&arr, cfmt("-lgcc_s"));
        c.strarray_push(&arr, cfmt("--no-as-needed"));
    }

    if (opt_shared) {
        c.strarray_push(&arr, c.format(cfmt("%s/crtendS.o"), gcc_libpath));
    } else {
        c.strarray_push(&arr, c.format(cfmt("%s/crtend.o"), gcc_libpath));
    }
    c.strarray_push(&arr, c.format(cfmt("%s/crtn.o"), libpath));
    c.strarray_push(&arr, null);

    run_subprocess(arr.data);
}

fn get_file_type(filename: [*c]const u8) FileType {
    if (opt_x != .FILE_NONE) return opt_x;
    if (endswith(filename, ".a")) return .FILE_AR;
    if (endswith(filename, ".so")) return .FILE_DSO;
    if (endswith(filename, ".o")) return .FILE_OBJ;
    if (endswith(filename, ".c")) return .FILE_C;
    if (endswith(filename, ".s")) return .FILE_ASM;
    c_error(cfmt("<command line>: unknown file extension: %s"), filename);
}

pub fn main() !void {
    // Collect args into null-terminated slices to interop with C.
    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var argv = try allocator.alloc([*c]u8, args.len);
    defer allocator.free(argv);
    for (args, 0..) |arg, idx| {
        argv[idx] = arg.ptr;
    }

    // Run driver.
    defer cleanup();
    c.init_macros();
    parse_args(@as(c_int, @intCast(args.len)), @as([*c][*c]u8, @ptrCast(argv.ptr)));

    if (opt_cc1) {
        add_default_include_paths(argv[0]);
        cc1();
        return;
    }

    if (input_paths.len > 1 and opt_o != null and (opt_c_flag or opt_S or opt_E)) {
        c_error(cfmt("cannot specify '-o' with '-c,' '-S' or '-E' with multiple files"));
    }

    var ld_args = c.StringArray{ .data = null, .capacity = 0, .len = 0 };

    var i: usize = 0;
    while (i < @as(usize, @intCast(input_paths.len))) : (i += 1) {
        const input = input_paths.data[i];
        if (c.strncmp(input, "-l", 2) == 0) {
            c.strarray_push(&ld_args, input);
            continue;
        }
        if (c.strncmp(input, "-Wl,", 4) == 0) {
            const dup = c.strdup(input + 4);
            var arg = c.strtok(dup, ",");
            while (arg != null) {
                c.strarray_push(&ld_args, arg);
                arg = c.strtok(null, ",");
            }
            continue;
        }

        var output: [*c]u8 = undefined;
        if (opt_o != null) {
            output = opt_o;
        } else if (opt_S) {
            output = replace_extn(input, ".s");
        } else {
            output = replace_extn(input, ".o");
        }

        const ftype = get_file_type(input);
        if (ftype == .FILE_OBJ or ftype == .FILE_AR or ftype == .FILE_DSO) {
            c.strarray_push(&ld_args, input);
            continue;
        }
        if (ftype == .FILE_ASM) {
            if (!opt_S) assemble(input, output);
            continue;
        }

        std.debug.assert(ftype == .FILE_C);

        if (opt_E or opt_M) {
            run_cc1(@as(c_int, @intCast(args.len)), @as([*c][*c]u8, @ptrCast(argv.ptr)), input, null);
            continue;
        }
        if (opt_S) {
            run_cc1(@as(c_int, @intCast(args.len)), @as([*c][*c]u8, @ptrCast(argv.ptr)), input, output);
            continue;
        }
        if (opt_c_flag) {
            const tmp = create_tmpfile();
            run_cc1(@as(c_int, @intCast(args.len)), @as([*c][*c]u8, @ptrCast(argv.ptr)), input, tmp);
            assemble(tmp, output);
            continue;
        }

        const tmp1 = create_tmpfile();
        const tmp2 = create_tmpfile();
        run_cc1(@as(c_int, @intCast(args.len)), @as([*c][*c]u8, @ptrCast(argv.ptr)), input, tmp1);
        assemble(tmp1, tmp2);
        c.strarray_push(&ld_args, tmp2);
    }

    if (ld_args.len > 0) {
        run_linker(&ld_args, if (opt_o != null) opt_o else cfmt("a.out"));
    }
}
