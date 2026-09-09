//
//  MaaabaBridge.mm
//  Maaaba
//
//  DarkSword 内核引导 + RemoteCall 生命周期管理。
//  流程与 Rein 的 ReinBridge 一致（ds_run + RemoteCall attach SpringBoard），
//  游戏进程查找目标改为 Smoba 客户端进程。
//

#import "MaaabaBridge.h"
#import "DSRemoteCall.h"
#import "SmobaFeatures.h"

#import <UIKit/UIKit.h>
#import <notify.h>
#import <os/lock.h>
#import <os/log.h>

#include <atomic>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern "C" {
#import "darksword.h"
#import "offsets.h"
#import "utils.h"
}

NSString * const MaaabaBridgeProgressNotification = @"com.maaaba.bridge.progress";

// 游戏进程名：与 Smoba 安装包一致（王者荣耀 iOS 客户端进程）。
// 若设备上进程名不同（如 "Smoba"、"HonorOfKings"），在此数组按序回退匹配。
NSString * const MaaabaGameProcessName = @"Smoba";

static const char *kGameProcNames[] = { "Smoba", "HonorOfKings", "wzry", nullptr };

static os_unfair_lock g_stateLock = OS_UNFAIR_LOCK_INIT;
static NSString *g_lastError = @"";
static NSString *g_stage = @"等待开始";
static pid_t g_remotePID = 0;

static std::atomic_bool g_kernelReady(false);
static std::atomic_bool g_kernelRunning(false);
static std::atomic_bool g_remoteReady(false);
static std::atomic_bool g_remoteRunning(false);
static std::atomic<double> g_progress(0.0);
static std::atomic<int> g_gamePid(0);

static RemoteCall *g_springBoard = nil;

// ---------------------------------------------------------------------------
// In-app console log ring buffer + 持久化文件（Documents/maaaba.log）
// ---------------------------------------------------------------------------

static NSUInteger const kMaaabaConsoleLogHardCap = 1500;
static NSMutableArray<NSString *> *gConsoleLog = nil;

static int maaaba_log_file_fd(void) {
    static int fd = -2;
    if (fd != -2) return fd;

    fd = -1;
    @autoreleasepool {
        NSArray<NSString *> *dirs =
            NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docs = dirs.firstObject;
        if (docs.length == 0) return fd;

        NSString *path = [docs stringByAppendingPathComponent:@"maaaba.log"];
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
        if (attrs.fileSize > 4ULL * 1024 * 1024) {
            NSString *old = [docs stringByAppendingPathComponent:@"maaaba.log.1"];
            [[NSFileManager defaultManager] removeItemAtPath:old error:nil];
            [[NSFileManager defaultManager] moveItemAtPath:path toPath:old error:nil];
        }
        fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) {
            const char *boot = "==== maaaba.log session ====\n";
            write(fd, boot, (size_t)strlen(boot));
        }
    }
    return fd;
}

static NSObject *maaaba_console_lock(void) {
    static NSObject *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = [NSObject new]; });
    return lock;
}

static NSDateFormatter *maaaba_console_date_formatter(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"HH:mm:ss.SSS";
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    });
    return formatter;
}

void MaaabaAppendConsoleLog(NSString *line) {
    if (line.length == 0) return;
    NSString *stamped = [NSString stringWithFormat:@"%@  %@",
        [maaaba_console_date_formatter() stringFromDate:[NSDate date]], line];
    @synchronized (maaaba_console_lock()) {
        if (!gConsoleLog) gConsoleLog = [NSMutableArray array];
        [gConsoleLog addObject:stamped];
        if (gConsoleLog.count > kMaaabaConsoleLogHardCap) {
            [gConsoleLog removeObjectsInRange:
                NSMakeRange(0, gConsoleLog.count - kMaaabaConsoleLogHardCap)];
        }
    }
    int fd = maaaba_log_file_fd();
    if (fd >= 0) {
        const char *utf8 = stamped.UTF8String;
        if (utf8) {
            ssize_t len = (ssize_t)strlen(utf8);
            if (len > 0) {
                write(fd, utf8, (size_t)len);
                write(fd, "\n", 1);
                fsync(fd);
            }
        }
    }
}

NSArray<NSString *> *MaaabaConsoleLogLines(void) {
    @synchronized (maaaba_console_lock()) {
        return gConsoleLog ? [gConsoleLog copy] : @[];
    }
}

void MaaabaClearConsoleLog(void) {
    @synchronized (maaaba_console_lock()) {
        if (gConsoleLog) [gConsoleLog removeAllObjects];
    }
}

int MaaabaLogFileFD(void) {
    return maaaba_log_file_fd();
}

static NSString *maaaba_console_fmt(NSString *fmt) {
    return [fmt stringByReplacingOccurrencesOfString:@"{public}" withString:@""];
}

static NSString *maaaba_console_vformat(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *out = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    return out;
}

#define MB_LOG(fmt, ...) \
    do { \
        _Pragma("clang diagnostic push") \
        _Pragma("clang diagnostic ignored \"-Wformat-security\"") \
        NSString *mb_log_line = \
            maaaba_console_vformat(maaaba_console_fmt(@"[Maaaba] " fmt), ##__VA_ARGS__); \
        os_log(OS_LOG_DEFAULT, "[Maaaba] %{public}s", mb_log_line.UTF8String ?: "(null)"); \
        MaaabaAppendConsoleLog(mb_log_line); \
        _Pragma("clang diagnostic pop") \
    } while (0)

#define MB_LOG_ERROR(fmt, ...) \
    do { \
        _Pragma("clang diagnostic push") \
        _Pragma("clang diagnostic ignored \"-Wformat-security\"") \
        NSString *mb_log_line = \
            maaaba_console_vformat(maaaba_console_fmt(@"[Maaaba] " fmt), ##__VA_ARGS__); \
        os_log_error(OS_LOG_DEFAULT, "[Maaaba] %{public}s", mb_log_line.UTF8String ?: "(null)"); \
        MaaabaAppendConsoleLog(mb_log_line); \
        _Pragma("clang diagnostic pop") \
    } while (0)

// ---------------------------------------------------------------------------
// kernelcache prefetch（与 Rein 同款：网络预热 + dlkcache）
// ---------------------------------------------------------------------------

static std::atomic<int> g_kernelPrefetchState(0); // 0 idle, 1 running, 2 ready, 3 failed
static dispatch_group_t g_kernelPrefetchGroup = nil;
static std::atomic<int> g_networkWarmupState(0);
static dispatch_group_t g_networkWarmupGroup = nil;
static const NSTimeInterval kNetworkWarmupTimeout = 180.0;
static const NSTimeInterval kNetworkRetryDelay = 3.0;

static dispatch_queue_t maaaba_bridge_queue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.maaaba.darksword", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static void maaaba_set_stage(NSString *stage) {
    os_unfair_lock_lock(&g_stateLock);
    g_stage = [stage copy] ?: @"";
    os_unfair_lock_unlock(&g_stateLock);
    MB_LOG("stage: %{public}@", g_stage);
}

static void maaaba_set_error(NSString *message) {
    os_unfair_lock_lock(&g_stateLock);
    g_lastError = [message copy] ?: @"";
    os_unfair_lock_unlock(&g_stateLock);
    if (g_lastError.length > 0) {
        MB_LOG_ERROR("%{public}@", g_lastError);
    }
}

static void maaaba_post_progress(void) {
    notify_post("com.maaaba.bridge.progress");
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:MaaabaBridgeProgressNotification object:nil];
    });
}

static void maaaba_bridge_log(const char *message) {
    if (message && message[0]) {
        MB_LOG("%{public}s", message);
    }
}

static void maaaba_bridge_progress(double progress) {
    g_progress.store(progress);
    maaaba_post_progress();
}

static BOOL maaaba_has_symbol_offsets(void) {
    return kernel_symbol_offsets_are_current();
}

static dispatch_group_t maaaba_kernel_prefetch_group(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ g_kernelPrefetchGroup = dispatch_group_create(); });
    return g_kernelPrefetchGroup;
}

static dispatch_group_t maaaba_network_warmup_group(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ g_networkWarmupGroup = dispatch_group_create(); });
    return g_networkWarmupGroup;
}

static BOOL maaaba_mark_network_warmup_ready(void) {
    int expected = 1;
    if (!g_networkWarmupState.compare_exchange_strong(expected, 2)) return NO;
    dispatch_group_leave(maaaba_network_warmup_group());
    return YES;
}

static void maaaba_start_kernel_prefetch(BOOL retryFailed) {
    BOOL hasBuiltinOffsets = install_builtin_kernel_symbol_offsets();
    if (hasBuiltinOffsets || maaaba_has_symbol_offsets()) {
        g_kernelPrefetchState.store(2);
        maaaba_set_stage(@"系统数据就绪");
        return;
    }

    int state = g_kernelPrefetchState.load();
    while (state != 1 && state != 2) {
        if (state == 3 && !retryFailed) return;
        if (g_kernelPrefetchState.compare_exchange_weak(state, 1)) break;
    }
    if (state == 1 || state == 2) return;

    maaaba_set_error(@"");
    maaaba_set_stage(@"正在缓存内核缓存");
    dispatch_group_t group = maaaba_kernel_prefetch_group();
    dispatch_group_enter(group);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL ready = dlkcache();
        g_kernelPrefetchState.store(ready ? 2 : 3);
        if (ready) {
            MB_LOG("kernelcache prefetch ready");
            maaaba_mark_network_warmup_ready();
            maaaba_set_error(@"");
            maaaba_set_stage(@"内核缓存完成");
        } else {
            MB_LOG_ERROR("kernelcache prefetch failed");
            if (g_networkWarmupState.load() == 1) {
                maaaba_set_stage(@"正在请求网络权限");
            } else {
                maaaba_set_stage(@"内核缓存失败");
            }
        }
        dispatch_group_leave(group);
    });
}

static BOOL maaaba_wait_for_kernel_attempt(CFAbsoluteTime deadline) {
    if (maaaba_has_symbol_offsets()) return YES;
    if (g_kernelPrefetchState.load() != 1) return NO;

    NSTimeInterval remaining = MAX(0.0, deadline - CFAbsoluteTimeGetCurrent());
    if (remaining <= 0.0) return NO;
    long waitResult = dispatch_group_wait(
        maaaba_kernel_prefetch_group(),
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC)));
    if (waitResult != 0) {
        MB_LOG_ERROR("kernelcache prefetch timed out");
        return NO;
    }
    return maaaba_has_symbol_offsets();
}

static void maaaba_probe_network_until_ready(CFAbsoluteTime startedAt, NSUInteger attempt) {
    if (g_networkWarmupState.load() != 1) return;

    NSTimeInterval elapsed = MAX(0.0, CFAbsoluteTimeGetCurrent() - startedAt);
    maaaba_set_stage([NSString stringWithFormat:@"等待网络（%.0f 秒，第 %lu 次）",
                    elapsed, (unsigned long)attempt]);

    NSMutableURLRequest *request = [NSMutableURLRequest
        requestWithURL:[NSURL URLWithString:@"https://api.appledb.dev/ios/main.json.xz"]
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
        timeoutInterval:8.0];
    request.HTTPMethod = @"HEAD";
    [[[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(__unused NSData *data, NSURLResponse *response, NSError *error) {
            NSHTTPURLResponse *httpResponse =
                [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
            BOOL httpOK = !httpResponse ||
                (httpResponse.statusCode >= 200 && httpResponse.statusCode < 400);
            if (!error && response && httpOK) {
                if (!maaaba_mark_network_warmup_ready()) return;
                MB_LOG("network access ready after %.0fs",
                       CFAbsoluteTimeGetCurrent() - startedAt);
                maaaba_set_error(@"");
                maaaba_set_stage(@"网络已连接，正在准备内核缓存");
                maaaba_start_kernel_prefetch(YES);
                return;
            }

            NSTimeInterval totalElapsed = MAX(0.0, CFAbsoluteTimeGetCurrent() - startedAt);
            if (g_networkWarmupState.load() != 1) return;
            if (totalElapsed >= kNetworkWarmupTimeout) {
                int expected = 1;
                if (!g_networkWarmupState.compare_exchange_strong(expected, 3)) return;
                NSString *detail = error.localizedDescription;
                if (!detail.length && httpResponse) {
                    detail = [NSString stringWithFormat:@"HTTP %ld", (long)httpResponse.statusCode];
                }
                if (!detail.length) detail = @"无有效响应";
                MB_LOG_ERROR("network warm-up timed out: %{public}@", detail);
                maaaba_set_stage(@"等待网络超时");
                maaaba_set_error([NSString stringWithFormat:
                    @"等待 %.0f 秒后仍无法连接：%@\n请检查网络权限与连接后重试。", totalElapsed, detail]);
                dispatch_group_leave(maaaba_network_warmup_group());
                return;
            }

            maaaba_set_stage([NSString stringWithFormat:
                @"网络未就绪，已等待 %.0f 秒，%.0f 秒后重试", totalElapsed, kNetworkRetryDelay]);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(kNetworkRetryDelay * NSEC_PER_SEC)),
                           dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                maaaba_probe_network_until_ready(startedAt, attempt + 1);
            });
        }] resume];
}

static void maaaba_warm_up_network_and_prefetch_kernel_cache(void) {
    BOOL hasBuiltinOffsets = install_builtin_kernel_symbol_offsets();
    if (hasBuiltinOffsets || maaaba_has_symbol_offsets()) {
        g_kernelPrefetchState.store(2);
        maaaba_set_error(@"");
        maaaba_set_stage(@"系统数据就绪");
        return;
    }

    BOOL shouldStartProbe = NO;
    int expected = 0;
    if (g_networkWarmupState.compare_exchange_strong(expected, 1)) {
        shouldStartProbe = YES;
    } else if (expected == 3) {
        expected = 3;
        shouldStartProbe = g_networkWarmupState.compare_exchange_strong(expected, 1);
    }

    if (shouldStartProbe) {
        maaaba_set_error(@"");
        maaaba_set_stage(@"正在请求网络权限");
        dispatch_group_enter(maaaba_network_warmup_group());
        maaaba_probe_network_until_ready(CFAbsoluteTimeGetCurrent(), 1);
    }

    maaaba_start_kernel_prefetch(YES);
}

static BOOL maaaba_wait_for_kernel_prefetch(NSTimeInterval timeout, BOOL retryFailed) {
    BOOL hasBuiltinOffsets = install_builtin_kernel_symbol_offsets();
    if (hasBuiltinOffsets || maaaba_has_symbol_offsets()) {
        g_kernelPrefetchState.store(2);
        return YES;
    }

    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + timeout;
    maaaba_warm_up_network_and_prefetch_kernel_cache();
    maaaba_start_kernel_prefetch(retryFailed);
    if (maaaba_wait_for_kernel_attempt(deadline)) return YES;

    if (g_networkWarmupState.load() == 1) {
        NSTimeInterval remaining = MAX(0.0, deadline - CFAbsoluteTimeGetCurrent());
        if (remaining <= 0.0) return NO;
        long networkWaitResult = dispatch_group_wait(
            maaaba_network_warmup_group(),
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC)));
        if (networkWaitResult != 0) {
            MB_LOG_ERROR("network warm-up timed out");
            return NO;
        }
    }
    if (maaaba_has_symbol_offsets()) return YES;
    if (g_networkWarmupState.load() != 2) return NO;

    maaaba_start_kernel_prefetch(retryFailed);
    return maaaba_wait_for_kernel_attempt(deadline);
}

// ---------------------------------------------------------------------------
// DarkSword kernel bootstrap
// ---------------------------------------------------------------------------

static BOOL maaaba_bootstrap_kernel(void) {
    if (g_kernelReady.load() && ds_is_ready()) return YES;

    ds_set_log_callback(maaaba_bridge_log);
    ds_set_progress_callback(maaaba_bridge_progress);
    MB_LOG("running DarkSword chain off-main-thread");

    init_offsets();
    offsets_init();
    install_builtin_kernel_symbol_offsets();

    maaaba_set_stage(@"正在初始化 DarkSword");
    int result = ds_run();
    if (result != 0 || !ds_is_ready()) {
        maaaba_set_error([NSString stringWithFormat:@"DarkSword 初始化失败（%d）", result]);
        return NO;
    }

    g_kernelReady.store(true);
    maaaba_set_stage(@"DarkSword 初始化完成");
    maaaba_set_error(@"");
    MB_LOG("DarkSword ready");
    return YES;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

BOOL MaaabaKernelIsReady(void) { return g_kernelReady.load() && ds_is_ready(); }
BOOL MaaabaRemoteCallIsReady(void) { return g_remoteReady.load(); }
BOOL MaaabaKernelIsRunning(void) { return g_kernelRunning.load(); }
BOOL MaaabaRemoteCallIsRunning(void) { return g_remoteRunning.load(); }

NSString *MaaabaBridgeLastError(void) {
    os_unfair_lock_lock(&g_stateLock);
    NSString *error = [g_lastError copy] ?: @"";
    os_unfair_lock_unlock(&g_stateLock);
    return error;
}

NSString *MaaabaBridgeStage(void) {
    os_unfair_lock_lock(&g_stateLock);
    NSString *stage = [g_stage copy] ?: @"";
    os_unfair_lock_unlock(&g_stateLock);
    return stage;
}

double MaaabaBridgeProgress(void) { return g_progress.load(); }
pid_t MaaabaRemoteCallPID(void) { return g_remotePID; }

void MaaabaInitializeDarkSwordKernel(void) {
    if (MaaabaKernelIsReady()) {
        maaaba_set_stage(@"DarkSword 已就绪");
        maaaba_post_progress();
        return;
    }
    if (g_kernelRunning.load()) return;

    g_kernelRunning.store(true);
    g_progress.store(0.0);
    maaaba_set_error(@"");
    maaaba_set_stage(@"正在准备启动");
    maaaba_post_progress();

    dispatch_async(maaaba_bridge_queue(), ^{
        @autoreleasepool {
            g_progress.store(0.03);
            maaaba_set_stage(@"正在准备系统数据");
            maaaba_post_progress();

            if (!maaaba_wait_for_kernel_prefetch(240.0, YES)) {
                NSString *preparationError = MaaabaBridgeLastError();
                g_kernelRunning.store(false);
                maaaba_set_stage(@"启动失败");
                maaaba_set_error(preparationError.length > 0 ? preparationError :
                    @"内核缓存下载或解析失败，网络权限可能仍在等待。请检查网络后重试。");
                maaaba_post_progress();
                return;
            }

            if (!maaaba_bootstrap_kernel()) {
                g_kernelRunning.store(false);
                maaaba_set_stage(@"启动失败");
                maaaba_post_progress();
                return;
            }

            g_kernelRunning.store(false);
            g_progress.store(1.0);
            maaaba_set_stage(@"DarkSword 内核就绪");
            maaaba_post_progress();
        }
    });
}

void MaaabaInitializeRemoteCall(void) {
    if (MaaabaRemoteCallIsReady()) {
        maaaba_set_stage(@"RemoteCall 已就绪");
        maaaba_post_progress();
        return;
    }
    if (g_remoteRunning.load()) return;

    if (!MaaabaKernelIsReady()) {
        maaaba_set_error(@"请先初始化 DarkSword 内核，再初始化 RemoteCall。");
        maaaba_set_stage(@"内核未就绪");
        maaaba_post_progress();
        return;
    }

    g_remoteRunning.store(true);
    maaaba_set_stage(@"正在定位 SpringBoard");
    maaaba_post_progress();

    dispatch_async(maaaba_bridge_queue(), ^{
        @autoreleasepool {
            @try {
                uint64_t sbProc = proc_find_by_name("SpringBoard");
                if (!sbProc) {
                    g_remoteRunning.store(false);
                    maaaba_set_stage(@"RemoteCall 失败");
                    maaaba_set_error(@"未找到 SpringBoard 进程，无法建立 RemoteCall。");
                    maaaba_post_progress();
                    return;
                }

                MB_LOG("SpringBoard proc=0x%llx self=0x%llx — starting RemoteCall",
                       (unsigned long long)sbProc, (unsigned long long)ds_get_our_proc());

                maaaba_set_stage(@"正在连接 SpringBoard");
                maaaba_post_progress();

                RemoteCall *process = [[RemoteCall alloc] initWithProcess:@"SpringBoard"
                                                     useMigFilterBypass:NO];
                if (!process || !process.trojanMem || process.pid <= 1) {
                    NSString *remoteError = [RemoteCall lastInitError];
                    if (remoteError.length == 0 && process) remoteError = process.lastError;
                    if (remoteError.length == 0) remoteError = @"RemoteCall 初始化失败（无详细信息）";
                    g_remoteRunning.store(false);
                    maaaba_set_stage(@"RemoteCall 失败");
                    maaaba_set_error([NSString stringWithFormat:@"SpringBoard 连接失败：%@", remoteError]);
                    maaaba_post_progress();
                    return;
                }

                g_springBoard = process;
                g_remotePID = process.pid;
                g_remoteReady.store(true);
                g_remoteRunning.store(false);
                maaaba_set_stage(@"RemoteCall 已连接");
                maaaba_set_error(@"");
                maaaba_post_progress();
                MB_LOG("RemoteCall active (SpringBoard pid=%d)", process.pid);
            } @catch (NSException *exception) {
                g_springBoard = nil;
                g_remoteReady.store(false);
                g_remoteRunning.store(false);
                maaaba_set_stage(@"RemoteCall 失败");
                maaaba_set_error([NSString stringWithFormat:@"RemoteCall 异常：%@", exception.reason]);
                maaaba_post_progress();
            }
        }
    });
}

RemoteCall *MaaabaBridgeRemoteCall(void) {
    return g_springBoard;
}

void MaaabaTeardownRemoteCall(void) {
    dispatch_async(maaaba_bridge_queue(), ^{
        @autoreleasepool {
            SmobaFeaturesStop();
            SmobaFeaturesWaitFullyStopped(20.0);
            @try {
                RemoteCall *process = g_springBoard;
                g_springBoard = nil;
                g_remoteReady.store(false);
                g_remotePID = 0;
                maaaba_set_stage(@"RemoteCall 已断开");
                maaaba_post_progress();
                [process destroyRemoteCall];
                MB_LOG("RemoteCall session torn down");
            } @catch (NSException *exception) {
                maaaba_set_error([NSString stringWithFormat:@"RemoteCall 拆除异常：%@", exception.reason]);
                maaaba_post_progress();
            }
        }
    });
}

BOOL MaaabaReadGameProcess(int *outPid) {
    if (!MaaabaKernelIsReady()) {
        maaaba_set_error(@"请先初始化 DarkSword 内核，再读取游戏进程。");
        maaaba_set_stage(@"内核未就绪");
        maaaba_post_progress();
        return NO;
    }

    uint64_t proc = 0;
    const char *matched = nullptr;
    for (int i = 0; kGameProcNames[i] != nullptr; i++) {
        proc = proc_find_by_name(kGameProcNames[i]);
        if (proc) { matched = kGameProcNames[i]; break; }
    }
    if (!proc) {
        g_gamePid.store(0);
        maaaba_set_error(@"未找到游戏进程，请先进入游戏后重试。");
        maaaba_set_stage(@"游戏进程未找到");
        maaaba_post_progress();
        return NO;
    }

    uint32_t pid = ds_kread32(proc + off_proc_p_pid);
    if (outPid) *outPid = (int)pid;
    g_gamePid.store((int)pid);
    maaaba_set_error(@"");
    maaaba_set_stage([NSString stringWithFormat:@"游戏进程已找到（%s, pid %u）", matched, pid]);
    maaaba_post_progress();
    MB_LOG("game process %s pid=%u proc=0x%llx", matched, pid, (unsigned long long)proc);
    return YES;
}

BOOL MaaabaGameProcessFound(void) {
    return g_gamePid.load() > 0;
}

int MaaabaGameProcessPID(void) {
    return g_gamePid.load();
}
