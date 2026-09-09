//
//  MaaabaBridge.h
//  Maaaba
//
//  Bridge between Maaaba's UI and the bundled DarkSword runtime
//  (功能与 Rein 的 ReinBridge 同构：内核引导 + RemoteCall 生命周期 + 进程查找)。
//

#import <Foundation/Foundation.h>
#import "DSRemoteCall.h"

NS_ASSUME_NONNULL_BEGIN

/// Posted on any progress / stage / state change (observe on main queue).
OBJC_EXTERN NSString * const MaaabaBridgeProgressNotification;

/// YES after a successful DarkSword kernel bootstrap (KRW ready).
OBJC_EXTERN BOOL MaaabaKernelIsReady(void);

/// YES after a successful RemoteCall attach to SpringBoard.
OBJC_EXTERN BOOL MaaabaRemoteCallIsReady(void);

/// YES while the kernel bootstrap (or kernelcache prefetch) is running.
OBJC_EXTERN BOOL MaaabaKernelIsRunning(void);

/// YES while the RemoteCall initialization is running.
OBJC_EXTERN BOOL MaaabaRemoteCallIsRunning(void);

/// Last human-readable error (may be empty).
OBJC_EXTERN NSString *MaaabaBridgeLastError(void);

/// Current neutral, user-visible stage label (may be empty).
OBJC_EXTERN NSString *MaaabaBridgeStage(void);

/// DarkSword bootstrap progress (0.0 – 1.0).
OBJC_EXTERN double MaaabaBridgeProgress(void);

/// pid of the attached RemoteCall session (0 when not attached).
OBJC_EXTERN pid_t MaaabaRemoteCallPID(void);

/// Button "初始化 DarkSword 内核": network warm-up + kernelcache prefetch +
/// offsets + ds_run(). Asynchronous; observe MaaabaBridgeProgressNotification.
OBJC_EXTERN void MaaabaInitializeDarkSwordKernel(void);

/// Button "初始化 RemoteCall": attach RemoteCall to SpringBoard.
/// Requires the kernel to be ready first. Asynchronous.
OBJC_EXTERN void MaaabaInitializeRemoteCall(void);

/// The live RemoteCall session attached to SpringBoard
/// (NULL until "初始化 RemoteCall" succeeded). Do not destroy it.
OBJC_EXTERN RemoteCall * _Nullable MaaabaBridgeRemoteCall(void);

/// 主动安全拆除 RemoteCall 会话（退后台 / App 退出前必须调用）。
OBJC_EXTERN void MaaabaTeardownRemoteCall(void);

/// Button "读取游戏进程": locate the game process via kernel proc walk.
/// Requires the kernel to be ready. Synchronous (fast). Returns the pid.
OBJC_EXTERN BOOL MaaabaReadGameProcess(int * _Nullable outPid);

/// 游戏进程是否已被「读取游戏进程」定位成功（供功能启动前校验）。
OBJC_EXTERN BOOL MaaabaGameProcessFound(void);

/// 游戏进程 pid（未找到返回 0）。
OBJC_EXTERN int MaaabaGameProcessPID(void);

/// 目标游戏进程名（Smoba 客户端进程）。
OBJC_EXTERN NSString * const MaaabaGameProcessName;

#pragma mark - In-app console log

/// 追加一行日志到 App 内控制台（自动加时间戳，线程安全）。
OBJC_EXTERN void MaaabaAppendConsoleLog(NSString *line);

/// 当前缓存的日志行（旧→新）。
OBJC_EXTERN NSArray<NSString *> *MaaabaConsoleLogLines(void);

/// 清空 App 内控制台日志。
OBJC_EXTERN void MaaabaClearConsoleLog(void);

/// rein.log 同款持久化日志 fd（Documents/maaaba.log，未启用返回 -1）。
OBJC_EXTERN int MaaabaLogFileFD(void);

NS_ASSUME_NONNULL_END
