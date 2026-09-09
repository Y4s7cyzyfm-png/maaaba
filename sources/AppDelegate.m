//
//  AppDelegate.m
//  Maaaba
//
//  改自 Rein AppDelegate：保活/后台拆除逻辑保持一致。
//

#import "AppDelegate.h"
#import "RootViewController.h"
#import "MaaabaBridge.h"
#import "SmobaFeatures.h"
#import "SilentKeepAlive.h"
#import <os/log.h>
#import <unistd.h>

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary<UIApplicationLaunchOptionsKey, id> *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[RootViewController alloc] init];
    [self.window makeKeyAndVisible];

    if (SilentKeepAlivePreferenceEnabled()) {
        SilentKeepAliveStart();
    }
    return YES;
}

// 退后台：保活在播 → 会话保持；否则在存活窗口内安全拆除 RemoteCall，
// 防止悬停的 trojan 线程把 SpringBoard 打崩（“注销”）。
- (void)applicationDidEnterBackground:(UIApplication *)application {
    BOOL playing = SilentKeepAliveIsPlaying();
    os_log_error(OS_LOG_DEFAULT,
                 "[Maaaba] backgrounding: keepalive playing=%d preference=%d featuresRunning=%d -> %{public}s",
                 playing, SilentKeepAlivePreferenceEnabled(), SmobaFeaturesRunning(),
                 playing ? @"keep session" : @"teardown session");
    MaaabaAppendConsoleLog([NSString stringWithFormat:
        @"[Maaaba] backgrounding: keepalive playing=%d featuresRunning=%d -> %@",
        playing, SmobaFeaturesRunning(),
        playing ? @"keep session" : @"teardown session"]);
    if (playing) return;

    UIApplication *app = UIApplication.sharedApplication;
    __block UIBackgroundTaskIdentifier task = [app beginBackgroundTaskWithExpirationHandler:^{
        [app endBackgroundTask:task];
    }];
    MaaabaTeardownRemoteCall();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (int i = 0; i < 125 &&
             (MaaabaRemoteCallIsReady() || MaaabaRemoteCallIsRunning()); i++) {
            usleep(200000);
            if (app.applicationState != UIApplicationStateBackground) break;
        }
        [app endBackgroundTask:task];
    });
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    if (SilentKeepAlivePreferenceEnabled() && !SilentKeepAliveIsPlaying()) {
        SilentKeepAliveStart();
    }
}

- (void)applicationWillTerminate:(UIApplication *)application {
    SmobaFeaturesStop();
    SmobaFeaturesWaitFullyStopped(3.0);
    RemoteCall *process = MaaabaBridgeRemoteCall();
    if (process) {
        @try {
            [process destroyRemoteCall];
        } @catch (NSException *exception) {
        }
    }
}

@end
