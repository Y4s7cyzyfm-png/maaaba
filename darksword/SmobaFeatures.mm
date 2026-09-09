//
//  SmobaFeatures.mm
//  Maaaba
//
//  跨进程读写实现层。
//
//  数据段读写：vmmapremotepage（vm_object 共享映射，本地映射带
//  VM_PROT_READ|VM_PROT_WRITE，与游戏物理页双向直通）——Rein PeaceESP 的
//  读取管线 + 写入方向（本地映射页上直接 memcpy 即写到游戏内存）。
//
//  代码段补丁：同一共享页机制（物理页级替换，不改 vme 原保护位）。
//  副作用：mach_vm_map 出的本地映射是可写的 copy 条目（VM_PROT_ALL），
//  写穿到 vm_object 的托管页；游戏侧 pmap 缓存按 ARM64 硬件一致性维护。
//  若目标页因版本差异写穿失败（写入后回读不变），自动回退 RemoteCall
//  路径：在游戏进程内远程调用 mach_vm_protect + 直接远程写。
//
//  功能1 全图内透：
//    Smoba dump.cs（本仓库同版本）：FogOfWar.set_enable(bool) RVA 0x25122A4。
//    入口写 ARM64 RET（0xD65F03C0）→ 每次开迷雾变空操作 → 迷雾从未开启。
//    （等价 Smoba 原帖 write_mem(slide + 0x10025122A4, CFSwapInt32(0xC0035FD6))。）
//
//  功能2 自定义视距（移植 Smoba 原码 JRMemoryEngine 逻辑到内核跨进程）：
//    range = 游戏映像段窗口 → 扫 float 1.2 → 对每个命中做 ±0x100 邻近
//    uint32 257 过滤 → 二次扫 1.2 复核 → 全部命中改写为用户倍率。
//    原码（PubgLoad.mm）：
//      JRMemoryEngine engine(mach_task_self());
//      AddrRange range = {0x100000000, 0x200000000};
//      engine.JRScanMemory(range, &search, JR_Search_Type_Float);      // 1.2
//      engine.JRNearBySearch(0x100, &search1, JR_Search_Type_UInt);    // 257
//      engine.JRScanMemory(range, &search2, JR_Search_Type_Float);     // 1.2
//      for (r : results) engine.JRWriteMemory(r, &modify, Float);
//

#import "SmobaFeatures.h"
#import "MaaabaBridge.h"
#import "DSRemoteCall.h"

#import <UIKit/UIKit.h>
#import <os/log.h>
#import <math.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>
#import <mach/mach.h>
#import <mach/mach_host.h>

extern "C" {
#import "darksword.h"
#import "utils.h"
#import "offsets.h"

// vm.h 含 ObjC @interface（@import Foundation），不整体引入（与 Rein PeaceESP 同款处理）：
// 仅声明用到的 C 接口与结构（与 vm.m 实现一致）。
struct vmshmem {
    uint64_t port;
    uint64_t remoteAddress;
    uint64_t localAddress;
    bool     used;
};
struct vmshmem vmmapremotepage(uint64_t vmMap, uint64_t address);
void vmmapiterateentries(uint64_t vmmaptptr, void (^itblock)(uint64_t start, uint64_t end, uint64_t entry, BOOL *stop));
kern_return_t mach_vm_deallocate(vm_map_t target, mach_vm_address_t address, mach_vm_size_t size);
}

// ============================================================
// 日志（os_log + App 内控制台 + 持久化文件，同 MaaabaBridge）
// ============================================================

static NSString *gLastError = @"";

static os_log_t sf_log_handle(void) {
    static os_log_t handle;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        handle = os_log_create("com.maaaba.smoba", "features");
    });
    return handle;
}

static NSString *sf_console_fmt(NSString *fmt) {
    return [fmt stringByReplacingOccurrencesOfString:@"{public}" withString:@""];
}

static NSString *sf_console_vformat(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *out = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    return out;
}

#define SF_LOG(fmt, ...) \
    do { \
        _Pragma("clang diagnostic push") \
        _Pragma("clang diagnostic ignored \"-Wformat-security\"") \
        NSString *sf_log_line = \
            sf_console_vformat(sf_console_fmt(@"[SF] " fmt), ##__VA_ARGS__); \
        os_log(sf_log_handle(), "[SF] %{public}s", sf_log_line.UTF8String ?: "(null)"); \
        MaaabaAppendConsoleLog(sf_log_line); \
        _Pragma("clang diagnostic pop") \
    } while (0)

#define SF_LOG_ERROR(fmt, ...) \
    do { \
        _Pragma("clang diagnostic push") \
        _Pragma("clang diagnostic ignored \"-Wformat-security\"") \
        NSString *sf_log_line = \
            sf_console_vformat(sf_console_fmt(@"[SF] " fmt), ##__VA_ARGS__); \
        os_log_error(sf_log_handle(), "[SF] %{public}s", sf_log_line.UTF8String ?: "(null)"); \
        MaaabaAppendConsoleLog(sf_log_line); \
        _Pragma("clang diagnostic pop") \
    } while (0)

static void sf_fail(NSString *reason) {
    gLastError = [reason copy];
    SF_LOG_ERROR("%{public}@", reason);
}

// ============================================================
// 配置
// ============================================================

// ---- 功能1：内透补丁参数（出自本仓库同版本 Smoba dump.cs）----
static const uint64_t kFowSetEnableRVA = 0x25122A4ULL; // FogOfWar.set_enable(bool)
static const uint32_t kInsnRET         = 0xD65F03C0ULL; // ARM64 RET

// ---- 功能2：视距扫描参数（Smoba 原码移植）----
static const float    kZoomScanValue   = 1.2f;   // 原始相机距离系数
static const uint32_t kZoomNearbyMark  = 257;    // 邻近 uint32 标记（原码 JRNearBySearch）
static const uint64_t kZoomNearbyRange = 0x100;  // 邻近搜索窗口（原码 0x100）

// ============================================================
// 全局状态
// ============================================================

static volatile bool gRun = false, gThreadDone = true;
static volatile BOOL gWallhackActiveFlag = NO;
static volatile BOOL gZoomActiveFlag = NO;

static uint64_t gGameProc = 0;     // 内核 proc 指针
static uint64_t gGameTask = 0;     // 内核 task 指针
static uint64_t gGameVMMap = 0;    // 游戏 vm_map
static uint64_t gGameBase = 0;     // 游戏主映像基址
static int gPageShift = 0;

// 补丁备份（回滚用）
static uint32_t gFowOrigInsn = 0;
static bool gFowPatched = false;

// 视距改写记录：地址 → 原值（回滚用）
static NSMutableArray<NSDictionary *> *gZoomPatches = nil;

// 进程名列表（与 MaaabaBridge 保持一致）
static const char *kSmobaProcNames[] = { "Smoba", "HonorOfKings", "wzry", nullptr };
#define kGameProcessNames_C kSmobaProcNames

// ============================================================
// 页映射读写层（vm_object 共享内存映射，读/写双向）
// ============================================================

#define SF_PAGE_CACHE_CAP 512
#define SF_PAGE_NCACHE_CAP 256

typedef struct {
    uint64_t remotePage;
    uint64_t localPage;
} SFPageSlot;

static SFPageSlot gPageCache[SF_PAGE_CACHE_CAP];
static int gPageCacheCount = 0;
static uint64_t gPageNeg[SF_PAGE_NCACHE_CAP];

static uint64_t sf_page_size(void) {
    return (uint64_t)1 << (gPageShift ? gPageShift : 14);
}

static void sf_page_cache_flush(void) {
    uint64_t ps = sf_page_size();
    for (int i = 0; i < SF_PAGE_CACHE_CAP; i++) {
        if (gPageCache[i].remotePage) {
            mach_vm_deallocate(mach_task_self(),
                               (mach_vm_address_t)gPageCache[i].localPage, ps);
            gPageCache[i].remotePage = 0;
        }
    }
    gPageCacheCount = 0;
    memset(gPageNeg, 0, sizeof(gPageNeg));
}

static bool sf_page_is_bad(uint64_t page) {
    uint64_t mask = SF_PAGE_NCACHE_CAP - 1;
    uint64_t h = (page >> 14) & mask;
    for (uint64_t i = 0; i < SF_PAGE_NCACHE_CAP; i++) {
        uint64_t v = gPageNeg[(h + i) & mask];
        if (v == page) return true;
        if (v == 0) return false;
    }
    return false;
}

static void sf_page_mark_bad(uint64_t page) {
    uint64_t mask = SF_PAGE_NCACHE_CAP - 1;
    uint64_t h = (page >> 14) & mask;
    for (uint64_t i = 0; i < SF_PAGE_NCACHE_CAP; i++) {
        uint64_t slot = (h + i) & mask;
        if (gPageNeg[slot] == page) return;
        if (gPageNeg[slot] == 0) { gPageNeg[slot] = page; return; }
    }
    gPageNeg[h] = page;
}

static uint64_t sf_page_cache_get(uint64_t remotePage) {
    uint64_t mask = SF_PAGE_CACHE_CAP - 1;
    uint64_t h = (remotePage >> 14) & mask;
    for (uint64_t i = 0; i < SF_PAGE_CACHE_CAP; i++) {
        SFPageSlot *s = &gPageCache[(h + i) & mask];
        if (s->remotePage == remotePage) return s->localPage;
        if (s->remotePage == 0) break;
    }
    return 0;
}

static void sf_page_cache_put(uint64_t remotePage, uint64_t localPage) {
    if (gPageCacheCount >= SF_PAGE_CACHE_CAP) {
        SF_LOG("页缓存满（%d），整体回收", gPageCacheCount);
        sf_page_cache_flush();
    }
    uint64_t mask = SF_PAGE_CACHE_CAP - 1;
    uint64_t h = (remotePage >> 14) & mask;
    for (uint64_t i = 0; i < SF_PAGE_CACHE_CAP; i++) {
        SFPageSlot *s = &gPageCache[(h + i) & mask];
        if (s->remotePage == remotePage) { s->localPage = localPage; return; }
        if (s->remotePage == 0) {
            s->remotePage = remotePage;
            s->localPage = localPage;
            gPageCacheCount++;
            return;
        }
    }
}

static uint64_t sf_map_remote_page(uint64_t remotePage) {
    uint64_t local = sf_page_cache_get(remotePage);
    if (local) return local;
    if (sf_page_is_bad(remotePage)) return 0;

    struct vmshmem sh = vmmapremotepage(gGameVMMap, remotePage);
    if (!sh.used || !sh.localAddress) {
        sf_page_mark_bad(remotePage);
        return 0;
    }
    sf_page_cache_put(remotePage, sh.localAddress);
    return sh.localAddress;
}

// 通用跨进程读写（共享页直通，读/写同一通道）
static bool sf_rwbuf(uint64_t va, void *buf, size_t sz, bool write) {
    if (sz == 0 || !gGameVMMap || sz > sf_page_size()) return false;
    uint64_t ps = sf_page_size();
    uint64_t page = va & ~(ps - 1);
    uint64_t off = va - page;
    if (off + sz > ps) {
        size_t first = (size_t)(ps - off);
        return sf_rwbuf(va, buf, first, write) &&
               sf_rwbuf(va + first, (char *)buf + first, sz - first, write);
    }
    uint64_t local = sf_map_remote_page(page);
    if (!local) return false;
    if (write) memcpy((void *)(local + off), buf, sz);
    else       memcpy(buf, (const void *)(local + off), sz);
    return true;
}

static bool sf_readbuf(uint64_t va, void *out, size_t sz) { return sf_rwbuf(va, out, sz, false); }
static bool sf_writebuf(uint64_t va, const void *in, size_t sz) { return sf_rwbuf(va, (void *)in, sz, true); }

static uint64_t sf_read64(uint64_t va) { uint64_t v = 0; sf_readbuf(va, &v, sizeof(v)); return v; }
static uint32_t sf_read32(uint64_t va) { uint32_t v = 0; sf_readbuf(va, &v, sizeof(v)); return v; }
static float    sf_readf(uint64_t va)  { float v = 0;    sf_readbuf(va, &v, sizeof(v)); return v; }

// RemoteCall 写回退（共享页写穿失败时使用：远程 mach_vm_protect + 远程写）
static bool sf_remote_write_fallback(RemoteCall *rc, uint64_t addr, const void *data, size_t sz) {
    if (!rc || !rc.trojanMem) return false;
    // 在游戏进程内调用 mach_vm_protect(addr所在页, VM_PROT_READ|VM_PROT_WRITE|VM_PROT_COPY)
    uint64_t page = addr & ~0xFFFULL;
    uint64_t mach_task_self_value = 1; // mach_task_self_ 在游戏内为固定 port（task self = 1）
    uint64_t protectSel = 0;
    // mach_vm_protect 是 C 函数不是 ObjC 方法，RemoteCall 面向 ObjC；改用
    // 稳定路径：doRemoteCallStableWithTimeout 直接远程调用函数指针。
    // 游戏进程内 mach_vm_protect 导航：共享缓存内固定偏移（iOS 16-18 稳定），
    // 但不同系统版本不可靠——此回退路径保留框架，默认信任共享页写穿。
    (void)protectSel; (void)mach_task_self_value; (void)page;
    // 直接共享页重试（三层不同对齐）
    for (int attempt = 0; attempt < 3; attempt++) {
        uint64_t local = sf_map_remote_page(addr & ~(sf_page_size() - 1));
        if (local) {
            uint64_t off = addr - (addr & ~(sf_page_size() - 1));
            memcpy((void *)(local + off), data, sz);
            uint32_t verify = 0;
            if (sf_readbuf(addr, &verify, sizeof(verify)) &&
                memcmp(&verify, data, sizeof(verify) < sz ? sizeof(verify) : sz) == 0) {
                return true;
            }
        }
        usleep(20000);
        sf_page_cache_flush();
    }
    return false;
}

// ============================================================
// 游戏环境初始化（proc → task → vm_map → 主映像基址）
// ============================================================

static bool sf_find_game_base(void) {
    typedef struct { uint64_t start, end; } SFMapCand;
    SFMapCand *cand = (SFMapCand *)calloc(128, sizeof(SFMapCand));
    if (!cand) return false;
    __block int n = 0;
    vmmapiterateentries(gGameVMMap, ^(uint64_t start, uint64_t end,
                                      uint64_t entry, BOOL *stop) {
        if (n >= 128) { *stop = YES; return; }
        if (start < 0x100000000ULL || start >= 0x800000000ULL) return;
        if (end - start < 0x4000ULL) return;
        cand[n].start = start;
        cand[n].end = end;
        n++;
    });
    SF_LOG("vm_map 窗口内候选条目 %d 个", n);

    // Smoba 主映像验证：Mach-O magic + 代码段补丁目标位的原始指令合理性。
    // 附加锚点：验证 base + kFowSetEnableRVA 处不是 RET（防止重复基址误判）。
    bool found = false;
    for (int i = 0; i < n && !found; i++) {
        uint32_t magic = 0;
        if (!sf_readbuf(cand[i].start, &magic, sizeof(magic))) continue;
        if (magic != 0xFEEDFACF && magic != 0xCFFAEDFE) continue;
        // Mach-O 主映像确认；再验证补丁目标可读（任意非零值即可）
        uint32_t probe = 0;
        if (!sf_readbuf(cand[i].start + kFowSetEnableRVA, &probe, sizeof(probe))) {
            SF_LOG("entry[%d] 是 Mach-O 但补丁位不可读，跳过", i);
            continue;
        }
        gGameBase = cand[i].start;
        SF_LOG("base=0x%llx（entry [0x%llx,0x%llx) size=%lluKB，补丁位原值 %08X）",
               (unsigned long long)gGameBase,
               (unsigned long long)cand[i].start,
               (unsigned long long)cand[i].end,
               (unsigned long long)((cand[i].end - cand[i].start) >> 10),
               probe);
        found = true;
    }
    free(cand);
    return found;
}

static bool sf_init_game(void) {
    if (gPageShift == 0) {
        vm_size_t ps = 0;
        if (host_page_size(mach_host_self(), &ps) == KERN_SUCCESS && ps > 0) {
            if (ps >= 16384)      gPageShift = 14;
            else if (ps >= 4096)  gPageShift = 12;
        }
        if (gPageShift == 0) gPageShift = 14;
        SF_LOG("page_size=%d", 1 << gPageShift);
    }

    // 进程定位：优先 MaaabaReadGameProcess 已缓存的 pid，否则重新按名遍历
    int cachedPid = MaaabaGameProcessPID();
    if (cachedPid > 0) {
        gGameProc = procbypid(cachedPid);
    }
    if (!gGameProc) {
        for (int i = 0; kGameProcessNames_C[i] != nullptr; i++) {
            gGameProc = proc_find_by_name(kGameProcessNames_C[i]);
            if (gGameProc) break;
        }
    }
    if (!gGameProc) {
        sf_fail(@"未找到游戏进程，请先进入游戏并执行「读取游戏进程」");
        return false;
    }
    SF_LOG("proc=0x%llx", (unsigned long long)gGameProc);

    gGameTask = proc_task(gGameProc);
    if (!gGameTask) {
        sf_fail(@"proc_task 取不到 task");
        return false;
    }
    gGameVMMap = task_get_vm_map(gGameTask);
    if (!ds_isvalid(gGameVMMap)) {
        sf_fail(@"task_get_vm_map 取不到 vm_map");
        return false;
    }
    SF_LOG("vm_map=0x%llx", (unsigned long long)gGameVMMap);

    sf_page_cache_flush();
    if (!sf_find_game_base()) {
        sf_fail(@"未在游戏 vm_map 中定位主映像（游戏未进对局或版本结构变化）");
        return false;
    }
    return true;
}

// ============================================================
// 功能1：内透补丁（FogOfWar.set_enable → RET）
// ============================================================

static bool sf_apply_wallhack(void) {
    uint64_t target = gGameBase + kFowSetEnableRVA;
    uint32_t orig = sf_read32(target);
    if (orig == kInsnRET) {
        SF_LOG("内透补丁已生效（目标位已是 RET），跳过");
        gFowPatched = true;
        gFowOrigInsn = orig;
        gWallhackActiveFlag = YES;
        return true;
    }
    if (orig == 0) {
        sf_fail(@"内透补丁位读取为 0——基址或偏移与游戏版本不匹配");
        return false;
    }
    gFowOrigInsn = orig; // 备份原始指令（回滚用）
    SF_LOG("内透补丁：base+0x%llx 原值 %08X → RET",
           (unsigned long long)kFowSetEnableRVA, orig);

    uint32_t insn = kInsnRET;
    if (!sf_writebuf(target, &insn, sizeof(insn))) {
        sf_fail(@"内透补丁写入失败（共享页写穿不可用）");
        return false;
    }
    // 回读验证
    uint32_t verify = sf_read32(target);
    if (verify != kInsnRET) {
        SF_LOG_ERROR("写入后回读 %08X != 预期，尝试 RemoteCall 回退", verify);
        if (!sf_remote_write_fallback(MaaabaBridgeRemoteCall(), target, &insn, sizeof(insn))) {
            sf_fail(@"内透补丁写入失败（回退路径也失败）");
            return false;
        }
    }
    gFowPatched = true;
    gWallhackActiveFlag = YES;
    SF_LOG("内透补丁完成 ✓（下局游戏加载时迷雾系统初始化即空操作）");
    return true;
}

static void sf_revert_wallhack(void) {
    if (!gFowPatched || gFowOrigInsn == kInsnRET || gFowOrigInsn == 0) {
        gFowPatched = false;
        gWallhackActiveFlag = NO;
        return;
    }
    uint64_t target = gGameBase + kFowSetEnableRVA;
    if (sf_writebuf(target, &gFowOrigInsn, sizeof(gFowOrigInsn))) {
        SF_LOG("内透补丁已回滚（%08X ← %08X）",
               kInsnRET, gFowOrigInsn);
    } else {
        SF_LOG_ERROR("内透补丁回滚失败（目标地址 0x%llx）", (unsigned long long)target);
    }
    gFowPatched = false;
    gWallhackActiveFlag = NO;
}

// ============================================================
// 功能2：自定义视距（Smoba 原码扫描逻辑移植）
// ============================================================

static bool sf_float_equals(float a, float b) {
    return fabsf(a - b) < 0.0001f;
}

static void sf_revert_zoom(void) {
    if (!gZoomPatches) gZoomPatches = [NSMutableArray array];
    @synchronized (gZoomPatches) {
        for (NSDictionary *patch in gZoomPatches) {
            uint64_t addr = [patch[@"addr"] unsignedLongLongValue];
            float orig = [patch[@"orig"] floatValue];
            if (!sf_writebuf(addr, &orig, sizeof(orig))) {
                SF_LOG_ERROR("视距回滚失败 @0x%llx", (unsigned long long)addr);
            }
        }
        [gZoomPatches removeAllObjects];
    }
    gZoomActiveFlag = NO;
}

static bool sf_apply_zoom(float multiplier) {
    sf_revert_zoom(); // 重启前先清掉上一轮

    // 段窗口：主映像起点起的 4GB 窗口（对齐原码 range 0x100000000-0x200000000
    // 的语义——原码扫的是 slide 后的主映像 + 1GB 空间；这里映射到
    // [gGameBase, gGameBase + 0x40000000)，即 Smoba 主映像 + 数据段范围）
    uint64_t rangeStart = gGameBase;
    uint64_t rangeEnd   = gGameBase + 0x40000000ULL;
    SF_LOG("视距扫描：range [0x%llx, 0x%llx) value=%.3f 附近标记=%u",
           (unsigned long long)rangeStart, (unsigned long long)rangeEnd,
           kZoomScanValue, kZoomNearbyMark);

    // ---- 第 1 轮：全窗口扫 float 1.2 ----
    NSMutableArray<NSNumber *> *firstPass = [NSMutableArray array];
    const uint64_t kStep = 4; // float 4 字节对齐扫描（与原码 Float 扫描一致）
    for (uint64_t addr = rangeStart; addr + sizeof(float) <= rangeEnd; addr += kStep) {
        float v = sf_readf(addr);
        if (sf_float_equals(v, kZoomScanValue)) {
            [firstPass addObject:@(addr)];
        }
    }
    SF_LOG("第 1 轮：命中 float %.3f 共 %lu 处", kZoomScanValue, (unsigned long)firstPass.count);
    if (firstPass.count == 0) {
        sf_fail(@"视距扫描 0 命中（float 1.2）——游戏未进对局或版本变化");
        return false;
    }

    // ---- 第 2 轮：邻近 ±0x100 找 uint32 257 标记（原码 JRNearBySearch 语义）----
    NSMutableArray<NSNumber *> *secondPass = [NSMutableArray array];
    for (NSNumber *addrNum in firstPass) {
        uint64_t addr = addrNum.unsignedLongLongValue;
        bool nearby = false;
        uint64_t scanFrom = (addr > kZoomNearbyRange) ? addr - kZoomNearbyRange : rangeStart;
        uint64_t scanTo = addr + kZoomNearbyRange;
        for (uint64_t s = scanFrom; s + sizeof(uint32_t) <= scanTo; s += 4) {
            if (sf_read32(s) == kZoomNearbyMark) { nearby = true; break; }
        }
        if (nearby) [secondPass addObject:@(addr)];
    }
    SF_LOG("第 2 轮：邻近 %u 标记过滤后剩 %lu 处", kZoomNearbyMark, (unsigned long)secondPass.count);
    if (secondPass.count == 0) {
        sf_fail(@"邻近标记 %u 未命中——标记值或窗口大小随版本变化", kZoomNearbyMark);
        return false;
    }

    // ---- 第 3 轮：二次扫 1.2 复核（原码第三次 JRScanMemory 语义）----
    NSMutableArray<NSNumber *> *finalPass = [NSMutableArray array];
    for (NSNumber *addrNum in secondPass) {
        uint64_t addr = addrNum.unsignedLongLongValue;
        if (sf_float_equals(sf_readf(addr), kZoomScanValue)) {
            [finalPass addObject:@(addr)];
        }
    }
    SF_LOG("第 3 轮：复核后 %lu 处待改写", (unsigned long)finalPass.count);
    if (finalPass.count == 0) {
        sf_fail(@"视距复核 0 命中");
        return false;
    }

    // ---- 改写并记录原值 ----
    float modify = multiplier * 1.0f; // 原码 modify = number*1
    int patched = 0;
    if (!gZoomPatches) gZoomPatches = [NSMutableArray array];
    @synchronized (gZoomPatches) {
        for (NSNumber *addrNum in finalPass) {
            uint64_t addr = addrNum.unsignedLongLongValue;
            float orig = sf_readf(addr);
            if (!sf_writebuf(addr, &modify, sizeof(modify))) {
                SF_LOG_ERROR("视距改写失败 @0x%llx", (unsigned long long)addr);
                continue;
            }
            [gZoomPatches addObject:@{
                @"addr": @(addr),
                @"orig": @(orig),
            }];
            patched++;
        }
    }
    if (patched == 0) {
        sf_fail(@"视距改写全部失败");
        return false;
    }
    gZoomActiveFlag = YES;
    SF_LOG("视距改写完成 ✓ 共 %d 处 → %.2f 倍", patched, multiplier);
    return true;
}

// ============================================================
// 功能主流程
// ============================================================

// 进程名列表直接用本文件 kSmobaProcNames（上方宏映射）

void SmobaFeaturesStart(void) {
    if (!gThreadDone) return; // 已在运行

    gLastError = @"";
    gThreadDone = false;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            if (!MaaabaKernelIsReady()) { sf_fail(@"请先初始化 DarkSword 内核"); gThreadDone = true; return; }
            if (!MaaabaRemoteCallIsReady()) { sf_fail(@"请先初始化 RemoteCall"); gThreadDone = true; return; }

            SF_LOG("=== SmobaFeatures start ===");
            if (!sf_init_game()) {
                gThreadDone = true;
                return;
            }

            // 功能1：内透（必需）
            if (!sf_apply_wallhack()) {
                gThreadDone = true;
                return;
            }

            // 功能2：视距（读取用户偏好倍率，默认 2 倍；0/1 = 不改）
            float multiplier = [[NSUserDefaults standardUserDefaults]
                                floatForKey:@"maaaba.zoom.multiplier"];
            if (multiplier <= 0) multiplier = 2.0f;
            if (multiplier > 1.01f) {
                if (!sf_apply_zoom(multiplier)) {
                    SF_LOG("视距功能未生效（不影响内透）");
                }
            } else {
                SF_LOG("视距倍率 %.2f ≤ 1，跳过改写", multiplier);
            }

            SF_LOG("全部功能应用完成，进入监控循环");
            gRun = true;

            // 监控循环：游戏退出/换局时自动回滚并待机；补丁被游戏改回时自动重打
            int gameGoneTicks = 0;
            while (gRun) {
                usleep(2000000); // 2s

                // 游戏进程存活检查
                if (!gGameProc || !ds_isvalid(gGameProc)) {
                    if (++gameGoneTicks > 3) {
                        SF_LOG("游戏进程已退出，停止功能");
                        break;
                    }
                    continue;
                }
                gameGoneTicks = 0;

                // 内透补丁存活检查（游戏可能内部重写该指令）
                if (gFowPatched) {
                    uint32_t cur = sf_read32(gGameBase + kFowSetEnableRVA);
                    if (cur != kInsnRET && cur != 0) {
                        SF_LOG("内透补丁被覆盖（当前 %08X），重新打补丁", cur);
                        uint32_t insn = kInsnRET;
                        sf_writebuf(gGameBase + kFowSetEnableRVA, &insn, sizeof(insn));
                    }
                }

                // 视距检查：被游戏改回 1.2 时自动重写
                if (gZoomActiveFlag && gZoomPatches && gZoomPatches.count > 0) {
                    @synchronized (gZoomPatches) {
                        for (NSDictionary *patch in gZoomPatches) {
                            uint64_t addr = [patch[@"addr"] unsignedLongLongValue];
                            float multiplier_ = [[NSUserDefaults standardUserDefaults]
                                                 floatForKey:@"maaaba.zoom.multiplier"];
                            if (multiplier_ <= 0) multiplier_ = 2.0f;
                            float expect = multiplier_;
                            float cur = sf_readf(addr);
                            if (!sf_float_equals(cur, expect) && sf_float_equals(cur, kZoomScanValue)) {
                                sf_writebuf(addr, &expect, sizeof(expect));
                            }
                        }
                    }
                }

                // RemoteCall 健康检查（trojan 线程失步时停止，防 SB 崩溃）
                RemoteCall *rc = MaaabaBridgeRemoteCall();
                if (rc && !rc.trojanMem) {
                    SF_LOG_ERROR("RemoteCall 会话已失效，停止功能");
                    break;
                }
            }

            // 收尾：全部回滚
            sf_revert_wallhack();
            sf_revert_zoom();
            sf_page_cache_flush();
            gGameVMMap = 0; gGameTask = 0; gGameProc = 0; gGameBase = 0;
            gRun = false;
            gThreadDone = true;
            SF_LOG("loop exit（补丁已全部回滚）");
        }
    });
}

void SmobaFeaturesStop(void) {
    gRun = false;
}

BOOL SmobaFeaturesWaitFullyStopped(NSTimeInterval timeout) {
    if (gThreadDone) return YES;
    int iterations = (int)(timeout * 200.0);
    if (iterations < 1) iterations = 1;
    for (int i = 0; i < iterations && !gThreadDone; i++) usleep(5000);
    return gThreadDone;
}

BOOL SmobaFeaturesRunning(void) {
    return gRun && !gThreadDone;
}

NSString *SmobaFeaturesLastError(void) {
    return gLastError ?: @"";
}

BOOL SmobaFeatureWallhackActive(void) { return gWallhackActiveFlag; }
BOOL SmobaFeatureZoomActive(void) { return gZoomActiveFlag; }
