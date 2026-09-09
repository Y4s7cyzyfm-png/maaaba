//
//  RootViewController.m
//  Maaaba
//
//  单 Tab 界面：顶栏 + 滚动卡片（状态 / DarkSword 初始化 / 游戏与功能）。
//

#import "RootViewController.h"
#import "MD3Theme.h"
#import "MD3Components.h"
#import "MaaabaBridge.h"
#import "SmobaFeatures.h"
#import "SilentKeepAlive.h"

@interface RootViewController ()
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, strong) UILabel *kernelStateLabel;
@property (nonatomic, strong) UILabel *remoteStateLabel;
@property (nonatomic, strong) UILabel *gameStateLabel;
@property (nonatomic, strong) UILabel *featureStateLabel;
@property (nonatomic, strong) MD3ProgressView *progressView;
@property (nonatomic, strong) UILabel *stageLabel;
@property (nonatomic, strong) UILabel *errorLabel;
@property (nonatomic, strong) MD3FilledButton *kernelInitButton;
@property (nonatomic, strong) MD3FilledButton *remoteCallInitButton;
@property (nonatomic, strong) MD3FilledButton *readGameButton;
@property (nonatomic, strong) MD3FilledButton *runFeatureButton;
@property (nonatomic, strong) UIView *toastView;
@property (nonatomic, strong) UILabel *toastLabel;
@end

@implementation RootViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = MD3Theme.backgroundColor;

    [self buildScrollView];

    [self buildStatusCard];
    [self buildDarkSwordCard];
    [self buildGameCard];
    [self buildToast];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(bridgeDidChange:)
                                                 name:MaaabaBridgeProgressNotification
                                               object:nil];
    [self reloadState];

    // 保活偏好：冷启动恢复
    if (SilentKeepAlivePreferenceEnabled()) {
        SilentKeepAliveStart();
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Layout

- (void)buildScrollView {
    self.scrollView = [[UIScrollView alloc] init];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.alwaysBounceVertical = YES;
    [self.view addSubview:self.scrollView];

    self.stack = [[UIStackView alloc] init];
    self.stack.axis = UILayoutConstraintAxisVertical;
    self.stack.spacing = 12;
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scrollView addSubview:self.stack];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    UILayoutGuide *content = self.scrollView.contentLayoutGuide;
    UILayoutGuide *frame = self.scrollView.frameLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [self.stack.topAnchor constraintEqualToAnchor:content.topAnchor constant:16],
        [self.stack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16],
        [self.stack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],
        [self.stack.bottomAnchor constraintLessThanOrEqualToAnchor:content.bottomAnchor constant:-24],
        [self.stack.widthAnchor constraintEqualToAnchor:frame.widthAnchor constant:-32],
    ]];
}

- (void)buildStatusCard {
    MD3CardView *card = [[MD3CardView alloc] init];
    [self.stack addArrangedSubview:card];

    UILabel *cardTitle = [[UILabel alloc] init];
    cardTitle.text = @"状态";
    cardTitle.font = MD3Theme.titleFont;
    cardTitle.textColor = MD3Theme.onSurfaceColor;
    cardTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:cardTitle];

    self.kernelStateLabel = [self stateLabel];
    self.remoteStateLabel = [self stateLabel];
    self.gameStateLabel = [self stateLabel];
    self.featureStateLabel = [self stateLabel];
    [card addSubview:self.kernelStateLabel];
    [card addSubview:self.remoteStateLabel];
    [card addSubview:self.gameStateLabel];
    [card addSubview:self.featureStateLabel];

    self.progressView = [[MD3ProgressView alloc] init];
    [card addSubview:self.progressView];

    self.stageLabel = [[UILabel alloc] init];
    self.stageLabel.font = MD3Theme.bodyFont;
    self.stageLabel.textColor = MD3Theme.onSurfaceVariantColor;
    self.stageLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:self.stageLabel];

    self.errorLabel = [[UILabel alloc] init];
    self.errorLabel.font = MD3Theme.bodyFont;
    self.errorLabel.textColor = [UIColor systemRedColor];
    self.errorLabel.numberOfLines = 0;
    self.errorLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:self.errorLabel];

    [NSLayoutConstraint activateConstraints:@[
        [cardTitle.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [cardTitle.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [cardTitle.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],

        [self.kernelStateLabel.topAnchor constraintEqualToAnchor:cardTitle.bottomAnchor constant:10],
        [self.kernelStateLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [self.kernelStateLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],

        [self.remoteStateLabel.topAnchor constraintEqualToAnchor:self.kernelStateLabel.bottomAnchor constant:6],
        [self.remoteStateLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [self.remoteStateLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],

        [self.gameStateLabel.topAnchor constraintEqualToAnchor:self.remoteStateLabel.bottomAnchor constant:6],
        [self.gameStateLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [self.gameStateLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],

        [self.featureStateLabel.topAnchor constraintEqualToAnchor:self.gameStateLabel.bottomAnchor constant:6],
        [self.featureStateLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [self.featureStateLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],

        [self.progressView.topAnchor constraintEqualToAnchor:self.featureStateLabel.bottomAnchor constant:12],
        [self.progressView.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [self.progressView.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [self.progressView.heightAnchor constraintEqualToConstant:4],

        [self.stageLabel.topAnchor constraintEqualToAnchor:self.progressView.bottomAnchor constant:10],
        [self.stageLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [self.stageLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],

        [self.errorLabel.topAnchor constraintEqualToAnchor:self.stageLabel.bottomAnchor constant:6],
        [self.errorLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [self.errorLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [self.errorLabel.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],
    ]];
}

- (UILabel *)stateLabel {
    UILabel *label = [[UILabel alloc] init];
    label.font = MD3Theme.bodyFont;
    label.textColor = MD3Theme.onSurfaceVariantColor;
    label.numberOfLines = 0;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

- (void)buildDarkSwordCard {
    MD3CardView *card = [[MD3CardView alloc] init];
    [self.stack addArrangedSubview:card];

    UILabel *cardTitle = [[UILabel alloc] init];
    cardTitle.text = @"DarkSword";
    cardTitle.font = MD3Theme.titleFont;
    cardTitle.textColor = MD3Theme.onSurfaceColor;
    cardTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:cardTitle];

    self.kernelInitButton = [MD3FilledButton buttonWithTitle:@"① 初始化 DarkSword 内核"
                                                  systemIcon:@"cpu"
                                                       style:0];
    self.remoteCallInitButton = [MD3FilledButton buttonWithTitle:@"② 初始化 RemoteCall"
                                                      systemIcon:@"antenna.radiowaves.left.and.right"
                                                           style:0];
    [card addSubview:self.kernelInitButton];
    [card addSubview:self.remoteCallInitButton];

    [NSLayoutConstraint activateConstraints:@[
        [cardTitle.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [cardTitle.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [cardTitle.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],

        [self.kernelInitButton.topAnchor constraintEqualToAnchor:cardTitle.bottomAnchor constant:12],
        [self.kernelInitButton.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [self.kernelInitButton.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],

        [self.remoteCallInitButton.topAnchor constraintEqualToAnchor:self.kernelInitButton.bottomAnchor constant:12],
        [self.remoteCallInitButton.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [self.remoteCallInitButton.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [self.remoteCallInitButton.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16],
    ]];

    __weak typeof(self) weakSelf = self;
    self.kernelInitButton.onTap = ^(MD3FilledButton *button) {
        if (MaaabaKernelIsReady()) { [weakSelf showToast:@"内核已就绪"]; return; }
        [weakSelf showToast:@"开始初始化内核…"];
        MaaabaInitializeDarkSwordKernel();
    };
    self.remoteCallInitButton.onTap = ^(MD3FilledButton *button) {
        if (MaaabaRemoteCallIsReady()) { [weakSelf showToast:@"RemoteCall 已就绪"]; return; }
        if (!MaaabaKernelIsReady()) { [weakSelf showToast:@"请先初始化 DarkSword 内核"]; return; }
        MaaabaInitializeRemoteCall();
    };
}

- (void)buildGameCard {
    MD3CardView *card = [[MD3CardView alloc] init];
    [self.stack addArrangedSubview:card];

    UILabel *cardTitle = [[UILabel alloc] init];
    cardTitle.text = @"游戏与功能";
    cardTitle.font = MD3Theme.titleFont;
    cardTitle.textColor = MD3Theme.onSurfaceColor;
    cardTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:cardTitle];

    self.readGameButton = [MD3FilledButton buttonWithTitle:@"③ 读取游戏进程"
                                                systemIcon:@"gamecontroller"
                                                     style:0];
    self.runFeatureButton = [MD3FilledButton buttonWithTitle:@"④ 开启功能"
                                                  systemIcon:@"eye.fill"
                                                       style:0];
    [card addSubview:self.readGameButton];
    [card addSubview:self.runFeatureButton];

    [NSLayoutConstraint activateConstraints:@[
        [cardTitle.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [cardTitle.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [cardTitle.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],

        [self.readGameButton.topAnchor constraintEqualToAnchor:cardTitle.bottomAnchor constant:12],
        [self.readGameButton.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [self.readGameButton.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],

        [self.runFeatureButton.topAnchor constraintEqualToAnchor:self.readGameButton.bottomAnchor constant:12],
        [self.runFeatureButton.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [self.runFeatureButton.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [self.runFeatureButton.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16],
    ]];

    __weak typeof(self) weakSelf = self;
    self.readGameButton.onTap = ^(MD3FilledButton *button) {
        [weakSelf readGameTapped];
    };
    self.runFeatureButton.onTap = ^(MD3FilledButton *button) {
        [weakSelf runFeatureTapped];
    };
}

#pragma mark - Actions

- (void)readGameTapped {
    if (!MaaabaKernelIsReady()) {
        [self showToast:@"请先初始化 DarkSword 内核"];
        return;
    }
    int pid = 0;
    BOOL ok = MaaabaReadGameProcess(&pid);
    [self showToast:ok ? [NSString stringWithFormat:@"游戏进程已找到（pid %d）", pid]
                       : (MaaabaBridgeLastError().length > 0 ? MaaabaBridgeLastError()
                                                             : @"未找到游戏进程，请先进入游戏")];
}

- (void)runFeatureTapped {
    if (SmobaFeaturesRunning()) {
        SmobaFeaturesStop();
        [self showToast:@"功能已停止"];
        [self reloadState];
        return;
    }
    if (!MaaabaKernelIsReady()) {
        [self showToast:@"请先初始化 DarkSword 内核"];
        return;
    }
    if (!MaaabaRemoteCallIsReady()) {
        [self showToast:@"请先初始化 RemoteCall"];
        return;
    }
    if (!MaaabaGameProcessFound()) {
        [self showToast:@"请先「读取游戏进程」"];
        return;
    }
    SmobaFeaturesStart();
    [self reloadState];
}

#pragma mark - State

- (void)bridgeDidChange:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{ [self reloadState]; });
}

- (void)reloadState {
    BOOL kernelReady = MaaabaKernelIsReady();
    BOOL remoteReady = MaaabaRemoteCallIsReady();
    BOOL featuresRunning = SmobaFeaturesRunning();

    self.kernelStateLabel.text = [NSString stringWithFormat:@"内核：%@",
        kernelReady ? @"已就绪 ✓" : (MaaabaKernelIsRunning() ? @"初始化中…" : @"未初始化")];
    self.remoteStateLabel.text = [NSString stringWithFormat:@"RemoteCall：%@",
        remoteReady ? @"已连接 ✓" : (MaaabaRemoteCallIsRunning() ? @"连接中…" : @"未连接")];
    self.gameStateLabel.text = [NSString stringWithFormat:@"游戏进程：%@",
        MaaabaGameProcessFound()
            ? [NSString stringWithFormat:@"已找到 ✓（pid %d）", MaaabaGameProcessPID()]
            : @"未查找"];
    self.featureStateLabel.text = [NSString stringWithFormat:@"功能：%@",
        featuresRunning ? @"运行中 ✓（内透 + 视距）" : @"未开启"];

    self.progressView.progress = MaaabaBridgeProgress();
    self.stageLabel.text = MaaabaBridgeStage();
    NSString *error = MaaabaBridgeLastError();
    self.errorLabel.text = error.length > 0 ? error : @"";

    [self.runFeatureButton setTitle:featuresRunning ? @"停止功能" : @"④ 开启功能"];
}

#pragma mark - Toast

- (void)buildToast {
    self.toastView = [[UIView alloc] init];
    self.toastView.backgroundColor = [MD3Theme.onSurfaceColor colorWithAlphaComponent:0.92];
    self.toastView.layer.cornerRadius = 20;
    self.toastView.layer.cornerCurve = kCACornerCurveContinuous;
    self.toastView.userInteractionEnabled = NO;
    self.toastView.hidden = YES;
    self.toastView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.toastView];

    self.toastLabel = [[UILabel alloc] init];
    self.toastLabel.font = MD3Theme.labelFont;
    self.toastLabel.textColor = MD3Theme.backgroundColor;
    self.toastLabel.textAlignment = NSTextAlignmentCenter;
    self.toastLabel.numberOfLines = 0;
    self.toastLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.toastView addSubview:self.toastLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.toastView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.toastView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor
                                                    constant:-24],
        [self.toastView.heightAnchor constraintGreaterThanOrEqualToConstant:40],
        [self.toastView.widthAnchor constraintGreaterThanOrEqualToConstant:180],
        [self.toastLabel.topAnchor constraintEqualToAnchor:self.toastView.topAnchor constant:10],
        [self.toastLabel.bottomAnchor constraintEqualToAnchor:self.toastView.bottomAnchor constant:-10],
        [self.toastLabel.leadingAnchor constraintEqualToAnchor:self.toastView.leadingAnchor constant:20],
        [self.toastLabel.trailingAnchor constraintEqualToAnchor:self.toastView.trailingAnchor constant:-20],
    ]];
}

- (void)showToast:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.toastLabel.text = message;
        self.toastView.alpha = 0;
        self.toastView.hidden = NO;
        [UIView animateWithDuration:0.2
                              delay:0
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{ self.toastView.alpha = 1; }
                         completion:^(BOOL finished) {
                             dispatch_after(
                                 dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8 * NSEC_PER_SEC)),
                                 dispatch_get_main_queue(), ^{
                                     [UIView animateWithDuration:0.25 animations:^{
                                         self.toastView.alpha = 0;
                                     } completion:^(BOOL done) {
                                         self.toastView.hidden = YES;
                                     }];
                                 });
                         }];
    });
}

@end
