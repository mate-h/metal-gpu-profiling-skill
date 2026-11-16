"""lldb command `gputrace_capture <out.gputrace> <ms>` used by gputrace_capture.sh.

Expressions use lldb persistent variables ($cd, $cerr): plain names like `d` collide with symbols
in the target and fail with "Multiple internal symbols found".
"""
import lldb, time


def capture(debugger, command, result, internal_dict):
    out, ms = command.split()
    target = debugger.GetSelectedTarget(); process = target.GetProcess()

    def ex(s):
        o = lldb.SBExpressionOptions(); o.SetLanguage(lldb.eLanguageTypeObjC_plus_plus)
        o.SetTimeoutInMicroSeconds(30_000_000); o.SetTryAllThreads(True)
        v = target.EvaluateExpression(s, o)
        err = v.GetError().GetCString() if v.GetError().Fail() else None
        print(">", s[:60], "=>", (err or v.GetObjectDescription() or v.GetValue() or "")[:300])
        return v

    ex('@import Metal; @import Foundation; (int)0')
    ex('id $cd = (id)[MTLCaptureDescriptor new]; (int)0')
    ex('[(MTLCaptureDescriptor *)$cd setCaptureObject:(id)MTLCreateSystemDefaultDevice()]; '
       '[(MTLCaptureDescriptor *)$cd setDestination:(MTLCaptureDestination)2]; (int)0')
    ex(f'[(MTLCaptureDescriptor *)$cd setOutputURL:[NSURL fileURLWithPath:@"{out}"]]; (int)0')
    ok = ex('NSError *$cerr = nil; (BOOL)[(MTLCaptureManager *)[MTLCaptureManager sharedCaptureManager] '
            'startCaptureWithDescriptor:(MTLCaptureDescriptor *)$cd error:&$cerr]')
    if ok.GetValue() != "true":
        ex('(id)[$cerr description]'); process.Detach(); return
    debugger.SetAsync(True); process.Continue(); time.sleep(int(ms) / 1000); process.Stop()
    for _ in range(100):
        if process.GetState() == lldb.eStateStopped:
            break
        time.sleep(0.1)
    debugger.SetAsync(False)
    ex('[(MTLCaptureManager *)[MTLCaptureManager sharedCaptureManager] stopCapture]; (int)0')
    process.Detach()


def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand(f'command script add -f {__name__}.capture gputrace_capture')
