// Per-source-line shader cost from a .gputrace with an embedded profile, without Xcode's GUI.
//
// Loads the profile the way Xcode's GPU debugger does (GTShaderProfilerStreamData +
// GTShaderProfilerStreamDataProcessor from GPUDebugger.ideplugin's GTShaderProfiler.framework),
// then asks each shader binary (GTMioShaderBinaryData) for the cost of every MSL line.
// Percentages are Xcode's source-pane figures: (cost.d0 + cost.d1) of the line over the same sum
// for the whole binary in the chosen scope. Function rows are inclusive (every instruction whose
// inline chain passes through the function), shown on the function's declaration line, as Xcode
// does. CPU only: no replay, no GPU. Takes ~15 s to process a 10-frame profile.
//
//   shader_line_costs <x.gputrace> --list
//   shader_line_costs <x.gputrace> --encoder hair_raster [--stage kernel] [--min 0.5] [--top 40]
//   shader_line_costs <x.gputrace> --pipeline 221 [--stage fragment] [--json]
//
// Built and run by the `shader_line_costs` wrapper next to this file. Private API: tested on
// Xcode 27.2 / macOS 27.2 / M5 (Nov 2026).

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <unistd.h>

#define XC "/Applications/Xcode.app/Contents"
#define LLVM_HELPER XC "/Developer/Platforms/MacOSX.platform/Developer/Library/GPUToolsPlatform/PlugIns/GTLLVMHelper"

// {GTMioCostInfo={GTMioCostContext=SS(?=IIIII)(?=QIIIQ)}d[10d]d[10d]Q[10Q]QQQ}. The unions are
// one member wide (4 and 8 bytes). d0 / d1 are the two cost components Xcode adds together.
typedef struct {
    uint16_t kind, sub; uint32_t u1; uint64_t u2;
    double d0, d0_dm[10], d1, d1_dm[10];
    uint64_t samples, samples_dm[10], x, y, z;
} CostInfo;
_Static_assert(sizeof(CostInfo) == 304, "CostInfo layout");
// {GTMioShaderBinaryDebugLocation=IIII}: file string index, function string index, line, column.
typedef struct { uint32_t file, func, line, col; } DebugLoc;
// {GTMioShaderBinaryDebugBinaryRange=IQQII}, stored packed (28-byte stride): first instruction,
// byte offset, byte size, first debug location of the inline chain (outermost first), its length.
typedef struct __attribute__((packed)) { uint32_t firstInstr; uint64_t offset, size; uint32_t locStart, locCount; } DebugRange;
// Function stream records (GPUTools DYFunctionStream): enough to read string arguments.
typedef struct { void *data; uint32_t a, type, size; uint16_t d, e; } FnArg;
typedef struct { int32_t fenum; uint32_t thread; uint16_t x, argc; uint64_t u; FnArg ret; FnArg args[16]; } CoreFn;

enum { ScopeTrace = 0, ScopeEncoder = 2, ScopePipeline = 3 };

#define SEL_(s) sel_registerName(s)
static id msg(id o, const char *s) { return ((id(*)(id, SEL))objc_msgSend)(o, SEL_(s)); }
static void call(id o, const char *s) { ((void(*)(id, SEL))objc_msgSend)(o, SEL_(s)); }
static uint64_t u64(id o, NSString *k) { return [[o valueForKey:k] unsignedLongLongValue]; }
/// A JSON number with `places` decimals (NSJSONSerialization prints doubles as 92.010000000000005).
static NSNumber *dec(double x, int places) { return [NSDecimalNumber decimalNumberWithString:[NSString stringWithFormat:@"%.*f", places, x]]; }

/// Our own messages. stderr itself stays pointed at a log after loading: the frameworks keep
/// printing (llvm-mca warnings, "Task 0 terminated") after the processor returns.
static int gErr = 2;

static void die(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void die(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    dprintf(gErr, "shader_line_costs: %s\n", [[[NSString alloc] initWithFormat:fmt arguments:ap] UTF8String]);
    va_end(ap); exit(1);
}

static void loadFrameworks(void) {
    const char *shared[] = {"GPUToolsCore", "GPUTools", "GPUToolsShaderProfiler", "MTLToolsShaderProfiler", "MTLTools"};
    for (int i = 0; i < 5; i++) {
        char p[512]; snprintf(p, sizeof p, XC "/SharedFrameworks/%s.framework/%s", shared[i], shared[i]);
        if (!dlopen(p, RTLD_NOW)) die(@"dlopen %s: %s", p, dlerror());
    }
    const char *gts = XC "/PlugIns/GPUDebugger.ideplugin/Contents/Frameworks/GTShaderProfiler.framework/GTShaderProfiler";
    if (!dlopen(gts, RTLD_NOW)) die(@"dlopen %s: %s", gts, dlerror());
    const char *classes[] = {"GTShaderProfilerStreamData", "GTShaderProfilerStreamDataProcessor", "GTMioShaderBinaryData", "DYCaptureArchive"};
    for (int i = 0; i < 4; i++)
        if (!objc_getClass(classes[i])) die(@"class %s is missing from this Xcode", classes[i]);
    // Struct layouts this tool assumes, checked against the runtime's type encodings.
    Method m = class_getInstanceMethod(objc_getClass("GTMioShaderBinaryData"), SEL_("cost"));
    const char *enc = m ? method_getTypeEncoding(m) : NULL;
    const char *body = enc ? strchr(enc, '{') : NULL;
    NSUInteger size = 0;
    if (body) {
        int depth = 0; size_t n = 0;
        do { depth += body[n] == '{' ? 1 : body[n] == '}' ? -1 : 0; n++; } while (body[n] && depth > 0);
        char buf[512]; snprintf(buf, sizeof buf, "%.*s", (int)n, body);
        NSGetSizeAndAlignment(buf, &size, NULL);
    }
    if (size != sizeof(CostInfo)) die(@"GTMioCostInfo is %lu bytes in this Xcode, expected %lu (%s)", size, sizeof(CostInfo), enc ?: "no -cost");
}

// MARK: - Options

typedef struct {
    NSString *trace, *raw, *encoder, *stage, *sourceOut, *scope;
    long long pipeline; int occurrence, top; double minPct; BOOL list, json, functions, exact;
} Opts;

static void usage(void) {
    fprintf(stderr,
        "usage: shader_line_costs <x.gputrace> --list [--json]\n"
        "       shader_line_costs <x.gputrace> (--encoder LABEL | --pipeline ID) [options]\n"
        "  --encoder LABEL   encoders with this label (exact; substring if none match exactly)\n"
        "  --occurrence N    only the Nth encoder with that label (1-based; default: all, summed)\n"
        "  --pipeline ID     a pipeline state object id from --list\n"
        "  --stage S         kernel | vertex | fragment (default: the stage with the most cost)\n"
        "  --scope S         encoder | pipeline | trace (default: encoder with --encoder, else pipeline)\n"
        "  --min PCT         hide lines below PCT percent (default 0.01)\n"
        "  --top N           only the N most expensive lines, sorted by cost\n"
        "  --no-functions    leave out the inclusive per-function rows\n"
        "  --source-out F    write the shader's MSL source to F\n"
        "  --stream DIR      a specific *.gpuprofiler_raw inside the trace (default: the newest)\n"
        "  --json            JSON instead of a table\n");
    exit(2);
}

static Opts parse(int argc, char **argv) {
    Opts o = {0}; o.pipeline = -1; o.minPct = 0.01; o.functions = YES;
    for (int i = 1; i < argc; i++) {
        NSString *a = @(argv[i]);
#define next() (i + 1 < argc ? @(argv[++i]) : (usage(), @""))
        if ([a isEqual:@"--list"]) o.list = YES;
        else if ([a isEqual:@"--json"]) o.json = YES;
        else if ([a isEqual:@"--encoder"]) o.encoder = next();
        else if ([a isEqual:@"--occurrence"]) o.occurrence = next().intValue;
        else if ([a isEqual:@"--pipeline"]) o.pipeline = next().longLongValue;
        else if ([a isEqual:@"--stage"]) o.stage = next();
        else if ([a isEqual:@"--scope"]) o.scope = next();
        else if ([a isEqual:@"--min"]) o.minPct = next().doubleValue;
        else if ([a isEqual:@"--top"]) o.top = next().intValue;
        else if ([a isEqual:@"--no-functions"]) o.functions = NO;
        else if ([a isEqual:@"--source-out"]) o.sourceOut = next();
        else if ([a isEqual:@"--stream"]) o.raw = next();
        else if ([a hasPrefix:@"-"]) usage();
        else if (!o.trace) o.trace = a;
        else usage();
#undef next
    }
    if (!o.trace || (!o.list && !o.encoder && o.pipeline < 0)) usage();
    return o;
}

// MARK: - Loading

/// Runs Xcode's stream-data processor. Its llvm-mca children print warnings on stderr and the
/// framework prints GPU info on stdout, so both go to a log that is shown only on failure.
static id processProfile(NSString *rawDir) {
    id sd = ((id(*)(id, SEL, id))objc_msgSend)(objc_getClass("GTShaderProfilerStreamData"),
        SEL_("dataFromArchivedDataURL:"), [NSURL fileURLWithPath:rawDir]);
    if (!sd) die(@"could not read the profile in %@", rawDir);
    NSString *tmpl = [NSTemporaryDirectory() stringByAppendingPathComponent:@"shader_line_costs.XXXXXX"];
    char logPath[1024]; strlcpy(logPath, tmpl.fileSystemRepresentation, sizeof logPath);
    int logFd = mkstemp(logPath);
    fflush(stdout); fflush(stderr);
    int out = dup(1), err = dup(2);
    dup2(logFd, 1); dup2(logFd, 2);
    // waitUntilFinished returns before the cost tables are loaded (loadingProgress, 0-100, is
    // still 0), so poll until the load reports 100. The processor must outlive every query: its
    // dealloc frees the cost data (pipeline ids read -1, costCount 0, costForLine crashes).
    static id proc;
    proc = ((id(*)(id, SEL, id, id))objc_msgSend)([objc_getClass("GTShaderProfilerStreamDataProcessor") alloc],
        SEL_("initWithStreamData:llvmHelperPath:"), sd, @LLVM_HELPER);
    call(proc, "processStreamData");
    call(proc, "waitUntilFinished");
    id mio = [msg(proc, "result") valueForKey:@"mioData"];
    BOOL loaded = NO;
    for (int i = 0; mio && i < 6000; i++) {   // up to 10 min
        if (![[mio valueForKey:@"loadingCostTimeline"] boolValue] && [[mio valueForKey:@"loadingProgress"] doubleValue] >= 100.0) { loaded = YES; break; }
        usleep(100000);
    }
    fflush(stdout); fflush(stderr);
    dup2(out, 1); close(out); close(logFd);
    gErr = err;   // fd 2 keeps going to the (unlinked) log
    if (mio && !loaded) dprintf(gErr, "shader_line_costs: warning: cost data still loading after 10 min; numbers may be partial\n");
    id result = [msg(proc, "result") valueForKey:@"shaderProfilerResult"];
    if (!result || ![result respondsToSelector:SEL_("mioData")]) {
        NSString *log = [NSString stringWithContentsOfFile:@(logPath) encoding:NSUTF8StringEncoding error:nil];
        unlink(logPath);
        die(@"processing produced %@ (this tool reads the Mio profile format of M-series GPUs on Xcode 27). Log tail:\n%@",
            result ? NSStringFromClass([result class]) : @"no result", [log substringFromIndex:log.length > 3000 ? log.length - 3000 : 0]);
    }
    unlink(logPath);
    return result;
}

/// Encoder function index → label. A label is the string argument of the encoder's setLabel:,
/// which wgpu calls right after creating it (index + 1); a descriptor label sits right before.
static NSDictionary<NSNumber *, NSString *> *encoderLabels(NSString *trace, NSArray *encoderIndices) {
    NSError *e;
    id ar = ((id(*)(id, SEL, id, long, NSError **))objc_msgSend)([objc_getClass("DYCaptureArchive") alloc],
        SEL_("initWithURL:options:error:"), [NSURL fileURLWithPath:trace], 0, &e);
    if (!ar) return @{};
    id file = ((id(*)(id, SEL, id, NSError **))objc_msgSend)(ar, SEL_("openFileWithFilename:error:"), @"capture", &e);
    id stream = file ? ((id(*)(id, SEL, NSError **))objc_msgSend)(file, SEL_("openFunctionStream:"), &e) : nil;
    if (!stream) return @{};
    NSMutableSet *want = [NSMutableSet set];
    uint64_t maxIdx = 0;
    for (NSNumber *n in encoderIndices) {
        uint64_t i = n.unsignedLongLongValue; maxIdx = MAX(maxIdx, i + 1);
        [want addObject:@(i + 1)]; if (i) [want addObject:@(i - 1)];
    }
    NSMutableDictionary *strings = [NSMutableDictionary dictionary];
    uint64_t idx = 0; const CoreFn *fn;
    while (idx <= maxIdx && (fn = ((const CoreFn *(*)(id, SEL))objc_msgSend)(stream, SEL_("readFunction")))) {
        if ([want containsObject:@(idx)] && fn->argc == 2 && fn->args[1].type == 14 && fn->args[1].data) {
            const char *s = fn->args[1].data;
            size_t n = strnlen(s, fn->args[1].size ? fn->args[1].size : 4096);
            strings[@(idx)] = [[NSString alloc] initWithBytes:s length:n encoding:NSUTF8StringEncoding] ?: @"";
        }
        idx++;
    }
    call(ar, "close");
    NSMutableDictionary *labels = [NSMutableDictionary dictionary];
    for (NSNumber *n in encoderIndices) {
        uint64_t i = n.unsignedLongLongValue;
        NSString *l = strings[@(i + 1)] ?: (i ? strings[@(i - 1)] : nil);
        if (l.length) labels[n] = l;
    }
    return labels;
}

static NSString *stageName(uint64_t t) {
    switch (t) { case 1: return @"vertex"; case 2: return @"fragment"; case 3: return @"kernel"; default: return [NSString stringWithFormat:@"type%llu", t]; }
}

// MARK: - Cost queries

typedef struct { unsigned short scope; uint64_t ident; } Scope;

/// The cost queries (even usedInEncoder:) dereference a missing per-scope table and crash when
/// the binary never ran in that scope: a vertex shader seen in only one of two same-label
/// encoders. The binary's cost list says which scopes exist: one kind-3 entry (binary total) per
/// scope, with sub = scope and u2 = its identifier. Read that instead of asking.
static BOOL scopeOK(id bin, Scope s) {
    const CostInfo *c = ((const CostInfo *(*)(id, SEL))objc_msgSend)(bin, SEL_("costs"));
    uint64_t n = u64(bin, @"costCount");
    for (uint64_t i = 0; c && i < n; i++)
        if (c[i].kind == 3 && c[i].sub == s.scope && (s.scope == ScopeTrace || c[i].u2 == s.ident)) return YES;
    return NO;
}

static double totalCost(id bin, NSArray<NSValue *> *scopes) {
    double t = 0;
    for (NSValue *v in scopes) {
        Scope s; [v getValue:&s];
        if (!scopeOK(bin, s)) continue;
        CostInfo c = {0};
        if (((BOOL(*)(id, SEL, unsigned short, uint64_t, CostInfo *))objc_msgSend)(bin, SEL_("costForScope:scopeIdentifier:cost:"), s.scope, s.ident, &c))
            t += c.d0 + c.d1;
    }
    return t;
}

static double lineCost(id bin, uint32_t line, uint32_t fpi, NSArray<NSValue *> *scopes, uint32_t *nInstr) {
    double t = 0; *nInstr = 0;
    for (NSValue *v in scopes) {
        Scope s; [v getValue:&s];
        if (!scopeOK(bin, s)) continue;
        CostInfo c = {0}; uint32_t n = 0;
        if (((BOOL(*)(id, SEL, uint32_t, uint32_t, unsigned short, uint64_t, CostInfo *, uint32_t *))objc_msgSend)(bin,
                SEL_("costForLine:fullPathIndex:scope:scopeIdentifier:cost:numInstructions:"), line, fpi, s.scope, s.ident, &c, &n))
            t += c.d0 + c.d1;
        *nInstr = MAX(*nInstr, n);
    }
    return t;
}

/// Per-instruction cost summed over the scopes. instructionCost:scope:... dereferences a missing
/// table and crashes, so read the table (one CostInfo per instruction) and skip absent ones.
static double *instrCosts(id bin, uint64_t n, NSArray<NSValue *> *scopes) {
    double *out = calloc(n ? n : 1, sizeof(double));
    for (NSValue *v in scopes) {
        Scope s; [v getValue:&s];
        if (!scopeOK(bin, s)) continue;
        const CostInfo *t = ((const CostInfo *(*)(id, SEL, unsigned short, uint64_t))objc_msgSend)(bin,
            SEL_("instructionCostsForScope:scopeIdentifier:"), s.scope, s.ident);
        if (!t) continue;
        for (uint64_t i = 0; i < n; i++) out[i] += t[i].d0 + t[i].d1;
    }
    return out;
}

// MARK: - Source

/// The library source for a binary: the capture stores each MSL source as a text file named by a
/// hash, with no link to the pipeline we can read, so pick the file that names the most of the
/// binary's program_source functions. (Some debug locations point past the end of the file, so
/// the highest line is no filter.)
static NSArray<NSString *> *findSource(NSString *trace, NSArray<NSString *> *funcs, uint32_t maxLine, NSString **name) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray *best = nil; NSInteger bestScore = -1;
    for (NSString *f in [fm contentsOfDirectoryAtPath:trace error:nil]) {
        if (f.length < 8 || f.length > 16 || [f rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEF"] invertedSet]].location != NSNotFound) continue;
        NSData *d = [NSData dataWithContentsOfFile:[trace stringByAppendingPathComponent:f]];
        if (d.length < 2 || !memcmp(d.bytes, "bplist", 6)) continue;
        NSUInteger len = d.length; while (len && ((const char *)d.bytes)[len - 1] == 0) len--;
        NSString *text = [[NSString alloc] initWithBytes:d.bytes length:len encoding:NSUTF8StringEncoding];
        if (!text || [text rangeOfString:@"metal_stdlib"].location == NSNotFound) continue;
        NSArray *lines = [text componentsSeparatedByString:@"\n"];
        NSInteger score = 0;
        for (NSString *fn in funcs) if ([text rangeOfString:[fn stringByAppendingString:@"("]].location != NSNotFound) score++;
        if (score > bestScore) { bestScore = score; best = lines; *name = f; }
    }
    return best;
}

/// Every line (1-based, ascending) that declares a function of this name in the MSL: a return
/// type, the name, "(". Overloads (naga_f2i32 for int and int2) give several.
static NSArray<NSNumber *> *declLines(NSArray<NSString *> *src, NSString *fn) {
    NSString *pat = [NSString stringWithFormat:@"^(?:static\\s+|inline\\s+|kernel\\s+|vertex\\s+|fragment\\s+|\\[\\[[^\\]]*\\]\\]\\s*)*[A-Za-z_][\\w:<>, ]*[\\s\\*&]%@\\s*\\(", [NSRegularExpression escapedPatternForString:fn]];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pat options:0 error:nil];
    NSMutableArray *out = [NSMutableArray array];
    for (NSUInteger i = 0; i < src.count; i++) {
        NSString *l = src[i];
        if ([l rangeOfString:fn].location == NSNotFound) continue;
        if ([l hasPrefix:@" "] || [l hasPrefix:@"\t"] || [l hasPrefix:@"return"]) continue;   // statements are indented
        if ([re firstMatchInString:l options:0 range:NSMakeRange(0, l.length)]) [out addObject:@(i + 1)];
    }
    return out;
}

// MARK: - Main

int main(int argc, char **argv) {
    @autoreleasepool {
        Opts o = parse(argc, argv);
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *trace = o.trace.stringByStandardizingPath;
        if (!o.raw) {
            NSArray *raws = [[[fm contentsOfDirectoryAtPath:trace error:nil] filteredArrayUsingPredicate:
                [NSPredicate predicateWithFormat:@"SELF ENDSWITH '.gpuprofiler_raw'"]] sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
                    NSDate *da = [fm attributesOfItemAtPath:[trace stringByAppendingPathComponent:a] error:nil].fileModificationDate;
                    NSDate *db = [fm attributesOfItemAtPath:[trace stringByAppendingPathComponent:b] error:nil].fileModificationDate;
                    return [da compare:db];
                }];
            if (!raws.count) die(@"%@ has no embedded profile (*.gpuprofiler_raw); run `gpudebug --oneshot -q -t <trace> -c \"profile run --exec serial --gpu-state high --embed\"` first", trace);
            o.raw = [trace stringByAppendingPathComponent:raws.lastObject];
        } else if (!o.raw.isAbsolutePath) o.raw = [trace stringByAppendingPathComponent:o.raw];

        loadFrameworks();
        id result = processProfile(o.raw);
        NSArray *encoders = [result valueForKey:@"encoders"], *commands = [result valueForKey:@"gpuCommands"];
        NSArray *pipelines = [result valueForKey:@"pipelineStates"];
        NSDictionary *binaries = [result valueForKey:@"shaderBinaries"];

        NSMutableArray *encIdx = [NSMutableArray array];
        for (id e in encoders) [encIdx addObject:[e valueForKey:@"functionIndex"]];
        NSDictionary *labels = encoderLabels(trace, encIdx);

        // Per encoder: label, the pipelines its GPU commands use, and each stage's binary key.
        NSMutableDictionary *pipeByOid = [NSMutableDictionary dictionary];
        NSMutableDictionary *pipeByIdx = [NSMutableDictionary dictionary];
        for (id p in pipelines) { pipeByOid[[p valueForKey:@"objectId"]] = p; pipeByIdx[[p valueForKey:@"index"]] = p; }
        NSMutableArray *encRows = [NSMutableArray array];
        for (id e in encoders) {
            uint64_t fi = u64(e, @"functionIndex"), start = u64(e, @"gpuCommandStartIndex"), n = u64(e, @"numGPUCommands");
            NSMutableOrderedSet *pipes = [NSMutableOrderedSet orderedSet];
            id timing = [e valueForKey:@"timingInfo"];
            for (uint64_t k = start; k < start + n && k < commands.count; k++) {
                id p = pipeByIdx[[commands[k] valueForKey:@"pipelineInfoIndex"]];
                if (p) [pipes addObject:[p valueForKey:@"objectId"]];
            }
            [encRows addObject:@{@"function_index": @(fi), @"label": labels[@(fi)] ?: @"", @"pipelines": pipes.array,
                                 @"gpu_commands": @(n), @"time_ns": @(timing ? u64(timing, @"time") : 0)}];
        }

        NSMutableArray *(^stagesOf)(id) = ^NSMutableArray *(id p) {
            NSMutableArray *out = [NSMutableArray array];
            NSDictionary *keys = [p valueForKey:@"binaryKeys"], *fns = [p valueForKey:@"shaderFunctions"];
            for (NSNumber *t in [keys.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
                id bin = binaries[keys[t]];
                [out addObject:@{@"stage": stageName(t.unsignedLongLongValue), @"function": [fns[t] valueForKey:@"name"] ?: @"?",
                                 @"binary": bin ?: [NSNull null], @"instructions": bin ? [bin valueForKey:@"instructionInfoCount"] : @0,
                                 @"has_debug_info": @([[bin valueForKey:@"debugLocationCount"] unsignedLongLongValue] > 0)}];
            }
            return out;
        };

        if (o.list) {
            NSMutableArray *rows = [NSMutableArray array];
            for (NSDictionary *r in encRows) {
                NSMutableArray *ps = [NSMutableArray array];
                for (NSNumber *oid in r[@"pipelines"]) {
                    NSMutableArray *st = [NSMutableArray array];
                    for (NSDictionary *s in stagesOf(pipeByOid[oid]))
                        [st addObject:@{@"stage": s[@"stage"], @"function": s[@"function"], @"instructions": s[@"instructions"], @"has_debug_info": s[@"has_debug_info"]}];
                    [ps addObject:@{@"pipeline": oid, @"stages": st}];
                }
                [rows addObject:@{@"label": r[@"label"], @"function_index": r[@"function_index"], @"time_ms": dec([r[@"time_ns"] doubleValue] / 1e6, 4),
                                  @"gpu_commands": r[@"gpu_commands"], @"pipelines": ps}];
            }
            if (o.json) {
                NSData *d = [NSJSONSerialization dataWithJSONObject:@{@"encoders": rows} options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
                fwrite(d.bytes, 1, d.length, stdout); printf("\n"); return 0;
            }
            printf("%-8s %-36s %9s  %s\n", "fn_idx", "encoder label", "time_ms", "pipeline: stage function (instructions, * = no debug info)");
            for (NSDictionary *r in rows) {
                NSMutableString *ps = [NSMutableString string];
                for (NSDictionary *p in r[@"pipelines"]) {
                    [ps appendFormat:@"%@%@:", ps.length ? @"  " : @"", p[@"pipeline"]];
                    for (NSDictionary *s in p[@"stages"]) [ps appendFormat:@" %@ %@ (%@%@)", s[@"stage"], s[@"function"], s[@"instructions"], [s[@"has_debug_info"] boolValue] ? @"" : @"*"];
                }
                printf("%-8s %-36s %9.3f  %s\n", [[r[@"function_index"] description] UTF8String], [r[@"label"] UTF8String], [r[@"time_ms"] doubleValue], ps.UTF8String);
            }
            return 0;
        }

        // Select encoders and a pipeline.
        NSArray *selEnc = @[];
        if (o.encoder) {
            NSPredicate *exact = [NSPredicate predicateWithFormat:@"label == %@", o.encoder];
            selEnc = [encRows filteredArrayUsingPredicate:exact];
            if (!selEnc.count) selEnc = [encRows filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"label CONTAINS[c] %@", o.encoder]];
            if (!selEnc.count) die(@"no encoder labelled %@ (see --list)", o.encoder);
            NSSet *names = [NSSet setWithArray:[selEnc valueForKey:@"label"]];
            if (names.count > 1) die(@"%@ matches several labels: %@", o.encoder, [names.allObjects componentsJoinedByString:@", "]);
            if (o.occurrence) {
                if (o.occurrence < 1 || o.occurrence > (int)selEnc.count) die(@"--occurrence %d: only %lu encoders", o.occurrence, selEnc.count);
                selEnc = @[selEnc[o.occurrence - 1]];
            }
        }
        NSArray *candPipes;
        if (o.pipeline >= 0) {
            if (!pipeByOid[@(o.pipeline)]) die(@"no pipeline %lld (see --list)", o.pipeline);
            candPipes = @[@(o.pipeline)];
            if (selEnc.count) {
                selEnc = [selEnc filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"%@ IN pipelines", @(o.pipeline)]];
                if (!selEnc.count) die(@"no %@ encoder uses pipeline %lld", o.encoder, o.pipeline);
            }
        } else {
            NSMutableOrderedSet *ps = [NSMutableOrderedSet orderedSet];
            for (NSDictionary *r in selEnc) [ps addObjectsFromArray:r[@"pipelines"]];
            if (!ps.count) die(@"encoder %@ has no profiled pipeline", o.encoder);
            candPipes = ps.array;
        }

        NSString *scopeName = o.scope ?: (selEnc.count ? @"encoder" : @"pipeline");
        if (![@[@"encoder", @"pipeline", @"trace"] containsObject:scopeName]) usage();
        if ([scopeName isEqual:@"encoder"] && !selEnc.count) die(@"--scope encoder needs --encoder");
        NSMutableArray<NSValue *> * (^scopesFor)(NSNumber *) = ^NSMutableArray<NSValue *> *(NSNumber *oid) {
            NSMutableArray *sc = [NSMutableArray array];
            Scope s;
            if ([scopeName isEqual:@"encoder"])
                for (NSDictionary *r in selEnc) { s = (Scope){ScopeEncoder, [r[@"function_index"] unsignedLongLongValue]}; [sc addObject:[NSValue valueWithBytes:&s objCType:@encode(Scope)]]; }
            else if ([scopeName isEqual:@"pipeline"]) { s = (Scope){ScopePipeline, oid.unsignedLongLongValue}; [sc addObject:[NSValue valueWithBytes:&s objCType:@encode(Scope)]]; }
            else { s = (Scope){ScopeTrace, 0}; [sc addObject:[NSValue valueWithBytes:&s objCType:@encode(Scope)]]; }
            return sc;
        };

        // Pipeline and stage: as asked, else the costliest in scope. The others go in a note.
        NSNumber *pipeOid = nil; NSDictionary *stage = nil; double stageTotal = -1;
        NSMutableArray *others = [NSMutableArray array];
        for (NSNumber *oid in candPipes) for (NSDictionary *s in stagesOf(pipeByOid[oid])) {
            if (o.stage && ![s[@"stage"] isEqual:o.stage]) continue;
            double t = s[@"binary"] != [NSNull null] ? totalCost(s[@"binary"], scopesFor(oid)) : 0;
            [others addObject:@{@"pipeline": oid, @"stage": s[@"stage"], @"function": s[@"function"], @"instructions": s[@"instructions"], @"cost": dec(t, 4)}];
            if (t > stageTotal) { stageTotal = t; stage = s; pipeOid = oid; }
        }
        if (!stage) die(@"no %@ stage in pipeline(s) %@", o.stage, [candPipes componentsJoinedByString:@", "]);
        [others filterUsingPredicate:[NSPredicate predicateWithFormat:@"NOT (pipeline == %@ AND stage == %@)", pipeOid, stage[@"stage"]]];
        NSArray<NSValue *> *scopes = scopesFor(pipeOid);
        id bin = stage[@"binary"];
        if (bin == [NSNull null]) die(@"no binary for the %@ stage", stage[@"stage"]);
        if (stageTotal <= 0) die(@"the %@ stage of pipeline %@ has no sampled cost in this scope", stage[@"stage"], pipeOid);
        if (![stage[@"has_debug_info"] boolValue]) die(@"the %@ binary has no debug info, so costs can't be mapped to lines (compile shaders with debug info / keep source in the capture)", stage[@"stage"]);

        // Debug info: the program_source file, its functions, their inline chains.
        NSArray *dstr = [bin valueForKey:@"debugStrings"];
        uint32_t fpi = ((uint32_t(*)(id, SEL, id))objc_msgSend)(bin, SEL_("fullPathIndexForFilePath:"), @"/program_source");
        // The string table can hold "/program_source" more than once: compare by value.
        NSMutableIndexSet *srcFile = [NSMutableIndexSet indexSet];
        [dstr enumerateObjectsUsingBlock:^(id x, NSUInteger i, BOOL *stop) { if ([x isEqual:@"/program_source"]) [srcFile addIndex:i]; }];
        const DebugLoc *locs = ((const DebugLoc *(*)(id, SEL))objc_msgSend)(bin, SEL_("debugLocations"));
        uint64_t nLoc = u64(bin, @"debugLocationCount");
        const DebugRange *ranges = ((const DebugRange *(*)(id, SEL))objc_msgSend)(bin, SEL_("debugBinaryRanges"));
        uint64_t nRange = u64(bin, @"debugBinaryRangeCount"), nInstr = u64(bin, @"instructionInfoCount");
        uint32_t maxLine = 0;
        NSMutableOrderedSet *srcFuncs = [NSMutableOrderedSet orderedSet];
        for (uint64_t i = 0; i < nLoc; i++) if ([srcFile containsIndex:locs[i].file]) {
            maxLine = MAX(maxLine, locs[i].line);
            if (locs[i].func < dstr.count) [srcFuncs addObject:dstr[locs[i].func]];
        }

        NSString *srcName = nil;
        NSArray<NSString *> *src = findSource(trace, srcFuncs.array, maxLine, &srcName);
        BOOL sourceSaved = o.sourceOut && src && [[src componentsJoinedByString:@"\n"] writeToFile:o.sourceOut atomically:YES encoding:NSUTF8StringEncoding error:nil];

        // Per-line cost.
        NSMutableArray *rows = [NSMutableArray array];
        for (uint32_t line = 1; line <= maxLine; line++) {
            uint32_t n = 0; double c = lineCost(bin, line, fpi, scopes, &n);
            if (n == 0 && c == 0) continue;
            double pct = 100 * c / stageTotal;
            if (pct < o.minPct) continue;
            [rows addObject:[@{@"line": @(line), @"pct": @(pct), @"instructions": @(n), @"kind": @"line"} mutableCopy]];
        }

        // Inclusive per-function cost from the inline chains. Validate the packed range layout first.
        NSMutableArray *funcRows = [NSMutableArray array];
        BOOL rangesOK = nRange > 0;
        for (uint64_t r = 0; r < nRange && rangesOK; r++)
            if (ranges[r].locStart + ranges[r].locCount > nLoc || ranges[r].firstInstr >= nInstr || (r && ranges[r].firstInstr < ranges[r - 1].firstInstr)) rangesOK = NO;
        if (o.functions && rangesOK) {
            // A location's line lies inside its own function, so for an overloaded name the nearest
            // declaration at or above it says which overload it is. Library functions get line 0.
            NSMutableDictionary<NSString *, NSArray *> *declCache = [NSMutableDictionary dictionary];
            uint32_t (^declFor)(const DebugLoc *) = ^uint32_t(const DebugLoc *l) {
                if (!src) return 0;
                NSString *f = dstr[l->func];
                NSArray *ds = declCache[f] ?: (declCache[f] = declLines(src, f));
                if (!ds.count) return 0;
                uint32_t best = [ds[0] unsignedIntValue];   // one declaration, or a line-0 / header location
                if (ds.count > 1 && [srcFile containsIndex:l->file])
                    for (NSNumber *d in ds) if (d.unsignedIntValue <= l->line) best = d.unsignedIntValue;
                return best;
            };
            NSString * (^keyOf)(const DebugLoc *) = ^NSString *(const DebugLoc *l) {
                return [NSString stringWithFormat:@"%@\t%u", dstr[l->func], declFor(l)];
            };
            // Each range's inline chain as function keys, outermost (the chain root) first.
            NSMutableArray<NSOrderedSet *> *chains = [NSMutableArray arrayWithCapacity:nRange];
            for (uint64_t r = 0; r < nRange; r++) {
                NSMutableOrderedSet *c = [NSMutableOrderedSet orderedSet];
                for (uint32_t k = ranges[r].locStart; k < ranges[r].locStart + ranges[r].locCount; k++)
                    if (locs[k].func < dstr.count) [c addObject:keyOf(&locs[k])];
                [chains addObject:c];
            }
            // Functions the compiler kept as real calls start chains of their own (the root is not
            // the entry point), so their cost never appears in their callers' chains. Xcode's call
            // tree hangs each such function under its first call site (in instruction order) and
            // adds its inclusive cost to every function on that call site's chain: with dom_depth
            // called from channel_depth (inlined three times) and from fs, all of dom_depth went
            // to channel_depth. A declaration line then shows one node of that tree: the
            // function's cost under the entry point if it is inlined there (not the copies inside
            // called functions), else under the first called function that holds it.
            NSString *entryKey = nil;
            uint32_t r0 = ((uint32_t(*)(id, SEL, uint32_t))objc_msgSend)(bin, SEL_("binaryRangeIndexForInstructionIndex:"), 0);
            if (r0 < nRange && chains[r0].count) entryKey = chains[r0].firstObject;
            NSMutableOrderedSet *roots = [NSMutableOrderedSet orderedSet];   // in instruction order
            for (NSOrderedSet *c in chains) if (c.count) [roots addObject:c.firstObject];
            if (!entryKey) entryKey = roots.firstObject;
            NSMutableDictionary<NSString *, NSOrderedSet *> *firstCall = [NSMutableDictionary dictionary];
            NSMutableArray *unresolved = [NSMutableArray array];
            for (NSString *f in roots) {
                if ([f isEqual:entryKey]) continue;
                NSString *name = [f componentsSeparatedByString:@"\t"][0];
                NSRegularExpression *call = [NSRegularExpression regularExpressionWithPattern:
                    [NSString stringWithFormat:@"(^|[^\\w])%@\\s*\\(", [NSRegularExpression escapedPatternForString:name]] options:0 error:nil];
                for (uint64_t r = 0; r < nRange && src; r++) {
                    if (!ranges[r].locCount || [chains[r] containsObject:f]) continue;
                    const DebugLoc *in = &locs[ranges[r].locStart + ranges[r].locCount - 1];   // innermost
                    if (![srcFile containsIndex:in->file] || !in->line || in->line > src.count) continue;
                    NSString *text = src[in->line - 1];
                    if ([call firstMatchInString:text options:0 range:NSMakeRange(0, text.length)]) { firstCall[f] = chains[r]; break; }
                }
                if (!firstCall[f]) [unresolved addObject:name];
            }
            // Per root: each function's cost on chains with that root.
            NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSNumber *> *> *rootCost = [NSMutableDictionary dictionary];
            for (NSString *rk in roots) rootCost[rk] = [NSMutableDictionary dictionary];
            double *ic = instrCosts(bin, nInstr, scopes);
            for (uint32_t i = 0; i < nInstr; i++) {
                uint32_t r = ((uint32_t(*)(id, SEL, uint32_t))objc_msgSend)(bin, SEL_("binaryRangeIndexForInstructionIndex:"), i);
                if (r >= nRange || ic[i] == 0 || !chains[r].count) continue;
                NSMutableDictionary *rc = rootCost[chains[r].firstObject];
                for (NSString *key in chains[r]) rc[key] = @([rc[key] doubleValue] + ic[i]);
            }
            free(ic);
            // Roll called functions into their call sites, innermost first (memoized; no cycles in MSL).
            NSMutableSet *rolled = [NSMutableSet set];
            __block void (^__weak weakRoll)(NSString *, int);
            void (^roll)(NSString *, int) = ^(NSString *g, int depth) {
                if ([rolled containsObject:g] || depth > 64) return;
                [rolled addObject:g];
                for (NSString *h in firstCall) if ([firstCall[h].firstObject isEqual:g]) weakRoll(h, depth + 1);
                NSOrderedSet *site = firstCall[g];
                if (!site) return;
                double inc = [rootCost[g][g] doubleValue];
                NSMutableDictionary *rc = rootCost[site.firstObject];
                for (NSString *key in site) rc[key] = @([rc[key] doubleValue] + inc);
            };
            weakRoll = roll;
            for (NSString *rk in roots) if (![rk isEqual:entryKey]) roll(rk, 0);
            NSMutableDictionary<NSString *, NSNumber *> *fcost = [NSMutableDictionary dictionary];
            for (NSString *rk in roots)   // entry point first (it holds instruction 0), then in order
                for (NSString *key in rootCost[rk]) if (!fcost[key]) fcost[key] = rootCost[rk][key];
            if (unresolved.count && !o.json)
                dprintf(gErr, "shader_line_costs: no call site found for %s; their cost is not added to their callers\n", [[unresolved componentsJoinedByString:@", "] UTF8String]);
            for (NSString *key in fcost) {
                double pct = 100 * fcost[key].doubleValue / stageTotal;
                if (pct < o.minPct) continue;
                NSArray *parts = [key componentsSeparatedByString:@"\t"];
                [funcRows addObject:[@{@"function": parts[0], @"pct": @(pct), @"line": @([parts[1] intValue]), @"kind": @"function"} mutableCopy]];
            }
            [funcRows sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"pct" ascending:NO]]];
        }

        for (NSMutableDictionary *r in rows) {
            uint32_t l = [r[@"line"] unsignedIntValue];
            if (src && l <= src.count) r[@"text"] = [src[l - 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        }
        NSMutableArray *merged = [rows mutableCopy];
        for (NSMutableDictionary *f in funcRows) {
            uint32_t l = [f[@"line"] unsignedIntValue];
            if (!l) continue;
            if (src && l <= src.count) f[@"text"] = [src[l - 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            [merged addObject:f];
        }
        if (o.top > 0) {
            [merged sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"pct" ascending:NO]]];
            if ((int)merged.count > o.top) [merged removeObjectsInRange:NSMakeRange(o.top, merged.count - o.top)];
        } else {
            [merged sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                NSComparisonResult c = [a[@"line"] compare:b[@"line"]];
                return c != NSOrderedSame ? c : [b[@"kind"] compare:a[@"kind"]];   // "line" before "function"
            }];
        }

        NSString *label = selEnc.count ? [selEnc.firstObject objectForKey:@"label"] : @"";
        NSArray *encFis = [selEnc valueForKey:@"function_index"];
        if (o.json) {
            NSMutableArray *outLines = [NSMutableArray array];
            for (NSDictionary *r in merged) {
                NSMutableDictionary *d = [r mutableCopy];
                d[@"pct"] = dec([r[@"pct"] doubleValue], 2);
                [outLines addObject:d];
            }
            NSMutableArray *outFns = [NSMutableArray array];
            for (NSDictionary *f in funcRows) [outFns addObject:@{@"function": f[@"function"], @"pct": dec([f[@"pct"] doubleValue], 2), @"line": f[@"line"]}];
            NSDictionary *out = @{@"encoder_label": label, @"encoder_function_indices": encFis ?: @[], @"pipeline": pipeOid,
                                  @"stage": stage[@"stage"], @"function": stage[@"function"], @"instructions": stage[@"instructions"],
                                  @"scope": scopeName, @"source_file": srcName ? [trace stringByAppendingPathComponent:srcName] : [NSNull null], @"source_saved_to": sourceSaved ? o.sourceOut : [NSNull null], @"other_stages": others, @"lines": outLines, @"functions": outFns};
            NSData *d = [NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
            fwrite(d.bytes, 1, d.length, stdout); printf("\n");
            return 0;
        }
        printf("# %s%spipeline %s, %s %s, %s instructions, scope %s%s\n", label.UTF8String, label.length ? ": " : "",
               [pipeOid description].UTF8String, [stage[@"stage"] UTF8String], [stage[@"function"] UTF8String],
               [[stage[@"instructions"] description] UTF8String], scopeName.UTF8String,
               selEnc.count ? [[NSString stringWithFormat:@" (encoders at %@)", [encFis componentsJoinedByString:@", "]] UTF8String] : "");
        printf("# MSL source: %s. pct = share of the shader's sampled cost, as in Xcode's source pane; f = function (inclusive) at its declaration\n",
               srcName ? [trace stringByAppendingPathComponent:srcName].UTF8String : "not found in the trace");
        if (sourceSaved) printf("# source saved to %s\n", o.sourceOut.UTF8String);
        double allCost = stageTotal; for (NSDictionary *x in others) allCost += [x[@"cost"] doubleValue];
        for (NSDictionary *x in others)
            printf("# also in scope: pipeline %s %s %s (%s instructions), %.1f%% of the sampled cost; pick it with --pipeline / --stage\n",
                   [[x[@"pipeline"] description] UTF8String], [x[@"stage"] UTF8String], [x[@"function"] UTF8String],
                   [[x[@"instructions"] description] UTF8String], allCost > 0 ? 100 * [x[@"cost"] doubleValue] / allCost : 0);
        for (NSDictionary *r in merged) {
            BOOL fn = [r[@"kind"] isEqual:@"function"];
            NSString *text = r[@"text"] ?: (fn ? r[@"function"] : @"");
            if (text.length > 160) text = [[text substringToIndex:157] stringByAppendingString:@"..."];   // --json has it whole
            printf("%5u %7.2f%% %5s  %s\n", [r[@"line"] unsignedIntValue], [r[@"pct"] doubleValue],
                   fn ? "f" : [[r[@"instructions"] description] UTF8String], text.UTF8String);
        }
        if (o.functions && !rangesOK) printf("# per-function costs unavailable: unexpected debug range layout\n");
        NSArray *unplaced = [funcRows filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"line == 0"]];
        if (unplaced.count && !o.top) {
            printf("# functions with no declaration line in the source (inlined library code), inclusive:\n");
            for (NSDictionary *f in unplaced) printf("#   %7.2f%%  %s\n", [f[@"pct"] doubleValue], [f[@"function"] UTF8String]);
        }
    }
    return 0;
}
