//
//  SmobaFeatures.h
//  Maaaba
//
//  跨进程功能开关（DarkSword 内核读写 + RemoteCall）：
//    功能1 全图内透：FogOfWar.set_enable 入口写 ARM64 RET，迷雾系统停摆；
//    功能2 自定义视距：按 Smoba 原码思路（float 1.2 扫描 + 邻近标记 257）改写相机距离。
//  目标进程：Smoba（王者荣耀）——跨进程修改，无需注入游戏。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 启动功能流程。前置：内核就绪 + RemoteCall 就绪 + 已「读取游戏进程」。
/// 异步执行；用 SmobaFeaturesIsRunning() 查询状态。
OBJC_EXTERN void SmobaFeaturesStart(void);

/// 停止并回滚全部已应用补丁（内透恢复原始指令、视距恢复原值）。
OBJC_EXTERN void SmobaFeaturesStop(void);

/// 阻塞等待功能线程完全收尾。timeout 秒内返回 YES。
OBJC_EXTERN BOOL SmobaFeaturesWaitFullyStopped(NSTimeInterval timeout);

/// 功能是否运行中（补丁已应用且监控线程存活）。
OBJC_EXTERN BOOL SmobaFeaturesRunning(void);

/// 上次错误（可能为空）。
OBJC_EXTERN NSString * _Nullable SmobaFeaturesLastError(void);

/// 各子功能实时状态（供 UI 展示）。
OBJC_EXTERN BOOL SmobaFeatureWallhackActive(void);
OBJC_EXTERN BOOL SmobaFeatureZoomActive(void);

NS_ASSUME_NONNULL_END
