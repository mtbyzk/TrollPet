//
//  TrollPet 单文件版（顶部悬浮宠物）
//
//  同一个二进制跑两种模式：
//    普通启动  -> 设置界面（TPMainAppDelegate）
//    -hud 启动 -> 悬浮宠物进程（TPHUDAppDelegate，由主 App 以 root 身份拉起）
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>
#import <stdlib.h>
#import <string.h>
#import <spawn.h>
#import <unistd.h>
#import <signal.h>
#import <errno.h>
#import <limits.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>

#pragma mark - 类声明

@interface TPHUDApplication : UIApplication
@end

@interface TPHUDWindow : UIWindow
@end

@interface TPPetView : UIView
- (instancetype)initWithStatePath:(NSString *)statePath;
- (void)react;
- (void)feed;
@end

@interface TPPassthroughView : UIView
@end

@interface TPOverlayViewController : UIViewController
@property (nonatomic, strong, readonly) TPPetView *petView;
- (instancetype)initWithStateDir:(NSString *)stateDir;
- (void)layoutPetWithScale:(double)scale topOffset:(double)offset;
@end

@interface TPHUDAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@interface TPMainAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@interface TPMainViewController : UIViewController
- (void)refreshDiagnostics;
- (void)copyDiagnostics;
@end

#pragma mark - 状态目录与配置（原 TPRuntime）

extern char **environ;

// 私有 API：让 platform-application 以 root 身份拉起子进程（TrollSpeed 同款做法）。
// 用 dlsym 动态解析，避免链接期依赖。注意两个函数参数个数不同。
typedef int (*TPPersonaNpFunc)(posix_spawnattr_t *, uint32_t, uint32_t);
typedef int (*TPPersonaIdFunc)(posix_spawnattr_t *, uid_t);

static TPPersonaNpFunc TPGetPersonaNpFunc(const char *name) {
    return (TPPersonaNpFunc)dlsym(RTLD_DEFAULT, name);
}

static TPPersonaIdFunc TPGetPersonaIdFunc(const char *name) {
    return (TPPersonaIdFunc)dlsym(RTLD_DEFAULT, name);
}

// 逐个候选目录试写，选出真正可写的那个（无沙盒 App 的 Library 可能不是容器里的 Library）
static NSString *TPWritableDirectory(NSString *candidate) {
    if (candidate.length == 0) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm createDirectoryAtPath:candidate withIntermediateDirectories:YES attributes:nil error:nil]) {
        return nil;
    }
    NSString *probe = [candidate stringByAppendingPathComponent:@".probe"];
    NSString *payload = [NSString stringWithFormat:@"%d", getpid()];
    BOOL ok = [payload writeToFile:probe atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [fm removeItemAtPath:probe error:nil];
    return ok ? candidate : nil;
}

// 状态目录：优先 App 的 Library，不行就退到 tmp，保证一定能读写
static NSString *TPStateDirectory(void) {
    static NSString *dir = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *library = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) firstObject];
        NSString *temporary = NSTemporaryDirectory();
        NSArray<NSString *> *bases = @[ library ?: @"", temporary ?: @"", @"/tmp" ];
        for (NSString *base in bases) {
            NSString *candidate = [base stringByAppendingPathComponent:@"TrollPet"];
            NSString *ok = TPWritableDirectory(candidate);
            if (ok) {
                dir = ok;
                break;
            }
        }
        if (dir == nil) {
            dir = [temporary stringByAppendingPathComponent:@"TrollPet"];
            [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:nil];
        }
    });
    return dir;
}

static NSString *TPFile(NSString *stateDir, NSString *name) {
    return [stateDir stringByAppendingPathComponent:name];
}

static NSString *TPConfigPath(NSString *stateDir) { return TPFile(stateDir, @"config.plist"); }
static NSString *TPPetStatePath(NSString *stateDir) { return TPFile(stateDir, @"state.plist"); }
static NSString *TPStopRequestPath(NSString *stateDir) { return TPFile(stateDir, @"stop.request"); }
static NSString *TPFeedRequestPath(NSString *stateDir) { return TPFile(stateDir, @"feed.request"); }
static NSString *TPPidPath(NSString *stateDir) { return TPFile(stateDir, @"hud.pid"); }
static NSString *TPLogPath(NSString *stateDir) { return TPFile(stateDir, @"hud.log"); }

// 内存日志：即使沙盒 / 权限导致文件写不进去，界面上也能看到
static NSMutableArray<NSString *> *gTPLogLines = nil;

// 诊断日志：主 App 与 HUD 进程共用同一个文件，主 App 里可直接查看 / 复制
static void TPAppendLog(NSString *stateDir, NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    if (gTPLogLines == nil) {
        gTPLogLines = [NSMutableArray array];
    }
    [gTPLogLines addObject:line];
    if (gTPLogLines.count > 60) {
        [gTPLogLines removeObjectAtIndex:0];
    }

    NSString *path = TPLogPath(stateDir);
    NSString *existing = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    NSString *content = existing.length > 0 ? existing : @"";
    NSArray<NSString *> *old = [content componentsSeparatedByString:@"\n"];
    if (old.count > 40) {
        content = [[old subarrayWithRange:NSMakeRange(old.count - 40, 40)] componentsJoinedByString:@"\n"];
    }

    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"HH:mm:ss";
    NSString *stamp = [fmt stringFromDate:[NSDate date]];
    NSString *next = [content stringByAppendingFormat:@"%@ %@\n", stamp, line];
    [next writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static CGFloat TPStatusBarHeight(void);   // 定义在 HUD 段，这里先声明供悬浮层布局使用

static NSDictionary *TPReadConfig(NSString *stateDir) {
    NSDictionary *raw = [NSDictionary dictionaryWithContentsOfFile:TPConfigPath(stateDir)];
    double scale = [raw[@"scale"] doubleValue];
    double offset = [raw[@"topOffset"] doubleValue];
    if (scale < 0.5 || scale > 2.0) scale = 0.9;
    if (offset < 0.0 || offset > 80.0) offset = 6.0;
    return @{ @"scale": @(scale), @"topOffset": @(offset) };
}

static void TPWriteConfig(NSString *stateDir, double scale, double topOffset) {
    NSDictionary *cfg = @{ @"scale": @(scale), @"topOffset": @(topOffset) };
    [[NSFileManager defaultManager] createDirectoryAtPath:stateDir
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:nil];
    [cfg writeToFile:TPConfigPath(stateDir) atomically:YES];
}

static BOOL TPHUDIsRunning(void) {
    NSString *text = [NSString stringWithContentsOfFile:TPPidPath(TPStateDirectory())
                                               encoding:NSUTF8StringEncoding
                                                  error:nil];
    pid_t pid = (pid_t)[text intValue];
    if (pid <= 0) return NO;
    // 自己是 mobile 用户，探测 root 进程时可能返回 EPERM，同样说明进程还在
    if (kill(pid, 0) == 0) return YES;
    return errno == EPERM;
}

// 最近一次启动失败的原因，主界面直接显示出来（用户截图即可，不必懂日志）
static NSString *gTPLastStartError = nil;

static int TPSpawnHUD(NSString *stateDir, const char *exePath, BOOL rootPersona,
                      double scale, double topOffset, pid_t *outPid) {
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);

    if (rootPersona) {
        // persona 提权：uid/gid 置 0，让 HUD 以 root 运行（否则解锁时会被 SpringBoard 杀掉）
        TPPersonaNpFunc personaNP = TPGetPersonaNpFunc("posix_spawnattr_set_persona_np");
        TPPersonaIdFunc personaUID = TPGetPersonaIdFunc("posix_spawnattr_set_persona_uid_np");
        TPPersonaIdFunc personaGID = TPGetPersonaIdFunc("posix_spawnattr_set_persona_gid_np");
        TPAppendLog(stateDir, @"main: persona api=%d", personaNP && personaUID && personaGID ? 1 : 0);
        if (personaNP && personaUID && personaGID) {
            personaNP(&attr, 99, 1); // POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE == 1
            personaUID(&attr, 0);
            personaGID(&attr, 0);
        }
    }

    posix_spawnattr_setpgroup(&attr, 0);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);

    NSString *scaleArg = [NSString stringWithFormat:@"%.3f", scale];
    NSString *offsetArg = [NSString stringWithFormat:@"%.1f", topOffset];
    const char *args[] = {
        exePath,
        "-hud",
        "-stateDir", stateDir.UTF8String,
        "-scale", scaleArg.UTF8String,
        "-topOffset", offsetArg.UTF8String,
        NULL
    };

    pid_t pid = 0;
    int rc = posix_spawn(&pid, exePath, NULL, &attr, (char **)args, environ);
    int spawnErrno = rc != 0 ? errno : 0;
    posix_spawnattr_destroy(&attr);

    TPAppendLog(stateDir, @"main: spawn root=%d rc=%d errno=%d(%s) pid=%d uid=%d",
                rootPersona ? 1 : 0, rc, spawnErrno,
                rc != 0 ? strerror(spawnErrno) : "ok", pid, getuid());

    if (outPid) *outPid = pid;
    return rc;
}

static BOOL TPStartHUD(NSString *stateDir, double scale, double topOffset) {
    if (TPHUDIsRunning()) {
        TPWriteConfig(stateDir, scale, topOffset);
        gTPLastStartError = nil;
        return YES;
    }
    [[NSFileManager defaultManager] removeItemAtPath:TPStopRequestPath(stateDir) error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:TPFeedRequestPath(stateDir) error:nil];
    TPWriteConfig(stateDir, scale, topOffset);

    char exePath[PATH_MAX] = {0};
    uint32_t exePathSize = sizeof(exePath);
    if (_NSGetExecutablePath(exePath, &exePathSize) != 0) {
        gTPLastStartError = @"取不到可执行文件路径";
        TPAppendLog(stateDir, @"main: _NSGetExecutablePath failed");
        return NO;
    }

    TPAppendLog(stateDir, @"main: start hud uid=%d exe=%s", getuid(), exePath);

    pid_t pid = 0;
    int rc = TPSpawnHUD(stateDir, exePath, YES, scale, topOffset, &pid);
    BOOL rootPersona = YES;
    if (rc != 0) {
        // root 提权失败时再退一步：用普通身份启动，至少能确认 HUD 窗口本身是否正常
        rootPersona = NO;
        rc = TPSpawnHUD(stateDir, exePath, NO, scale, topOffset, &pid);
    }

    if (rc != 0 || pid <= 0) {
        gTPLastStartError = [NSString stringWithFormat:@"rc=%d (%s)", rc, strerror(errno)];
        TPAppendLog(stateDir, @"main: start failed rc=%d", rc);
        return NO;
    }

    gTPLastStartError = nil;
    // 不要 waitpid，让 HUD 自己跑
    NSString *pidText = [NSString stringWithFormat:@"%d", pid];
    [pidText writeToFile:TPPidPath(stateDir) atomically:YES encoding:NSUTF8StringEncoding error:nil];
    TPAppendLog(stateDir, @"main: hud pid=%d root=%d", pid, rootPersona ? 1 : 0);
    return YES;
}

static void TPStopHUD(NSString *stateDir) {
    // HUD 进程是 root，主 App 无法直接 kill，用请求文件通知它自行退出
    [[NSFileManager defaultManager] createDirectoryAtPath:stateDir
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:nil];
    [@"stop" writeToFile:TPStopRequestPath(stateDir) atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void TPRequestFeed(NSString *stateDir) {
    [@"feed" writeToFile:TPFeedRequestPath(stateDir) atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

#pragma mark - 宠物视图（原 TPPetView）

// 24 小时从 0 饿到 100
static const double kTPHungerPerMinute = 100.0 / 1440.0;

static UIColor *TPOrange(void) {
    return [UIColor colorWithRed:0.98 green:0.64 blue:0.33 alpha:1.0];
}

static UIColor *TPDark(void) {
    return [UIColor colorWithRed:0.24 green:0.15 blue:0.11 alpha:1.0];
}

static UIColor *TPCream(void) {
    return [UIColor colorWithRed:1.00 green:0.94 blue:0.84 alpha:1.0];
}

static UIColor *TPPink(void) {
    return [UIColor colorWithRed:1.00 green:0.62 blue:0.69 alpha:1.0];
}

static void TPFillOval(CGContextRef ctx, CGRect rect, UIColor *color) {
    CGContextSetFillColorWithColor(ctx, [color CGColor]);
    CGContextFillEllipseInRect(ctx, rect);
}

static void TPFillTriangle(CGContextRef ctx, CGPoint a, CGPoint b, CGPoint c, UIColor *color) {
    CGContextSetFillColorWithColor(ctx, [color CGColor]);
    CGContextBeginPath(ctx);
    CGContextMoveToPoint(ctx, a.x, a.y);
    CGContextAddLineToPoint(ctx, b.x, b.y);
    CGContextAddLineToPoint(ctx, c.x, c.y);
    CGContextClosePath(ctx);
    CGContextFillPath(ctx);
}

@interface TPPetView () {
    CADisplayLink *_link;
    double _elapsed;        // 动画时间轴（秒）
    double _happyUntil;     // 开心表情截止时间
    double _eatUntil;       // 进食表情截止时间
    double _blinkEndsAt;    // 本次眨眼结束时间
    double _nextBlinkAt;    // 下次眨眼时间
    double _hunger;         // 0 ~ 100
    NSDate *_hungerDate;
    NSTimeInterval _lastSaveAt;
    NSMutableArray<NSMutableDictionary *> *_hearts;
    NSString *_statePath;
}
@end

@implementation TPPetView

- (instancetype)initWithStatePath:(NSString *)statePath {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _statePath = [statePath copy];
        _hearts = [NSMutableArray array];
        _nextBlinkAt = 2.4;
        _lastSaveAt = 0.0;

        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.userInteractionEnabled = YES;
        self.multipleTouchEnabled = NO;

        [[NSFileManager defaultManager] createDirectoryAtPath:[statePath stringByDeletingLastPathComponent]
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                              action:@selector(handleTap:)];
        [self addGestureRecognizer:tap];

        UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                                                            action:@selector(handleLongPress:)];
        press.minimumPressDuration = 0.45;
        [self addGestureRecognizer:press];

        [self loadState];
    }
    return self;
}

- (void)dealloc {
    [_link invalidate];
}

#pragma mark - 生命周期

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window) {
        [self startAnimating];
    } else {
        [self stopAnimating];
    }
}

- (void)startAnimating {
    if (_link) return;
    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    _link.preferredFramesPerSecond = 30;
    [_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)stopAnimating {
    [_link invalidate];
    _link = nil;
}

#pragma mark - 状态与动画

- (void)tick:(CADisplayLink *)link {
    _elapsed += link.duration;

    if (_elapsed >= _nextBlinkAt) {
        _blinkEndsAt = _elapsed + 0.15;
        _nextBlinkAt = _elapsed + 2.4 + (double)arc4random_uniform(30) / 10.0;
    }

    double minutes = -[_hungerDate timeIntervalSinceNow] / 60.0;
    if (minutes > 0.0) {
        _hunger = MIN(100.0, _hunger + minutes * kTPHungerPerMinute);
    }
    _hungerDate = [NSDate date];

    if (_elapsed - _lastSaveAt > 60.0) {
        _lastSaveAt = _elapsed;
        [self saveState];
    }

    for (NSInteger i = (NSInteger)_hearts.count - 1; i >= 0; i--) {
        NSMutableDictionary *heart = _hearts[(NSUInteger)i];
        double y = [heart[@"y"] doubleValue] - 0.5;
        double alpha = [heart[@"a"] doubleValue] - 0.016;
        if (alpha <= 0.0) {
            [_hearts removeObjectAtIndex:(NSUInteger)i];
            continue;
        }
        heart[@"y"] = @(y);
        heart[@"a"] = @(alpha);
    }

    [self setNeedsDisplay];
}

- (void)handleTap:(UITapGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateRecognized) {
        [self react];
    }
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        [self feed];
    }
}

- (void)react {
    _happyUntil = _elapsed + 1.8;
    [self spawnHearts:2];
    [self feedback];
}

- (void)feed {
    _hunger = 0.0;
    _hungerDate = [NSDate date];
    _eatUntil = _elapsed + 2.0;
    [self spawnHearts:3];
    [self feedback];
    [self saveState];
}

- (void)feedback {
    UIImpactFeedbackGenerator *generator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [generator impactOccurred];
}

- (void)spawnHearts:(NSInteger)count {
    for (NSInteger i = 0; i < count; i++) {
        double x = 34.0 + (double)arc4random_uniform(32);
        double y = 16.0 + (double)arc4random_uniform(10);
        [_hearts addObject:[@{ @"x": @(x), @"y": @(y), @"a": @(1.0) } mutableCopy]];
    }
}

#pragma mark - 持久化

- (void)loadState {
    NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:_statePath];
    if (state) {
        double savedHunger = [state[@"hunger"] doubleValue];
        NSTimeInterval savedAt = [state[@"date"] doubleValue];
        NSDate *date = savedAt > 0.0 ? [NSDate dateWithTimeIntervalSince1970:savedAt] : [NSDate date];
        double minutes = MAX(0.0, -[date timeIntervalSinceNow] / 60.0);
        _hunger = MIN(100.0, savedHunger + minutes * kTPHungerPerMinute);
    } else {
        _hunger = 0.0;
    }
    _hungerDate = [NSDate date];
}

- (void)saveState {
    NSDictionary *state = @{ @"hunger": @(_hunger),
                             @"date": @([[NSDate date] timeIntervalSince1970]) };
    [state writeToFile:_statePath atomically:YES];
}

#pragma mark - 绘制

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;

    CGFloat width = CGRectGetWidth(rect);
    CGFloat height = CGRectGetHeight(rect);
    if (width <= 0.0 || height <= 0.0) return;

    // 以 100 x 100 的逻辑坐标绘制，按窗口尺寸整体缩放
    CGFloat unit = MIN(width, height) / 100.0;
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, (width - 100.0 * unit) * 0.5, (height - 100.0 * unit) * 0.5);
    CGContextScaleCTM(ctx, unit, unit);

    BOOL eating = _elapsed < _eatUntil;
    BOOL happy = _elapsed < _happyUntil;
    BOOL hungry = _hunger >= 70.0;

    // 地面影子
    TPFillOval(ctx, CGRectMake(30, 93, 40, 7), [[UIColor blackColor] colorWithAlphaComponent:0.12]);

    CGFloat bob = sin(_elapsed * 2.2) * 1.1;

    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, 0, bob);

    [self drawTailInContext:ctx wag:sin(_elapsed * 3.0)];
    [self drawBodyInContext:ctx];
    [self drawHeadInContext:ctx
                     eyeOpen:(_elapsed < _blinkEndsAt) ? 0.12 : 1.0
                      eating:eating
                       happy:happy
                      hungry:hungry];

    CGContextRestoreGState(ctx);

    [self drawHeartsInContext:ctx];

    CGContextRestoreGState(ctx);
}

- (void)drawTailInContext:(CGContextRef)ctx wag:(CGFloat)wag {
    CGContextSetStrokeColorWithColor(ctx, [TPOrange() CGColor]);
    CGContextSetLineWidth(ctx, 7.5);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextMoveToPoint(ctx, 70, 84);
    CGContextAddCurveToPoint(ctx,
                             84, 82,
                             90 + wag * 3.0, 72 + wag * 4.0,
                             88 + wag * 4.0, 60 + wag * 7.0);
    CGContextStrokePath(ctx);
}

- (void)drawBodyInContext:(CGContextRef)ctx {
    TPFillOval(ctx, CGRectMake(27, 63, 46, 32), TPOrange());
    TPFillOval(ctx, CGRectMake(38, 74, 24, 18), TPCream());
    TPFillOval(ctx, CGRectMake(31, 86, 16, 10), TPCream());
    TPFillOval(ctx, CGRectMake(53, 86, 16, 10), TPCream());
}

- (void)drawHeadInContext:(CGContextRef)ctx
                  eyeOpen:(CGFloat)eyeOpen
                   eating:(BOOL)eating
                    happy:(BOOL)happy
                   hungry:(BOOL)hungry {
    // 耳朵（先画，让头部盖住下半部分）
    TPFillTriangle(ctx, CGPointMake(23, 38), CGPointMake(29, 13), CGPointMake(45, 30), TPOrange());
    TPFillTriangle(ctx, CGPointMake(77, 38), CGPointMake(71, 13), CGPointMake(55, 30), TPOrange());
    TPFillTriangle(ctx, CGPointMake(31, 32), CGPointMake(34, 19), CGPointMake(41, 30), TPPink());
    TPFillTriangle(ctx, CGPointMake(69, 32), CGPointMake(66, 19), CGPointMake(59, 30), TPPink());

    // 头
    TPFillOval(ctx, CGRectMake(25, 21, 50, 49), TPOrange());

    // 腮红
    TPFillOval(ctx, CGRectMake(27, 43, 11, 6), [TPPink() colorWithAlphaComponent:0.35]);
    TPFillOval(ctx, CGRectMake(62, 43, 11, 6), [TPPink() colorWithAlphaComponent:0.35]);

    // 眼睛
    if (happy || eating) {
        CGContextSetStrokeColorWithColor(ctx, [TPDark() CGColor]);
        CGContextSetLineWidth(ctx, 2.4);
        CGContextSetLineCap(ctx, kCGLineCapRound);
        CGContextMoveToPoint(ctx, 32.5, 41);
        CGContextAddQuadCurveToPoint(ctx, 39, 34, 45.5, 41);
        CGContextMoveToPoint(ctx, 54.5, 41);
        CGContextAddQuadCurveToPoint(ctx, 61, 34, 67.5, 41);
        CGContextStrokePath(ctx);
    } else {
        CGFloat eyeHeight = 9.5 * eyeOpen;
        TPFillOval(ctx, CGRectMake(35.5, 38 - eyeHeight * 0.5, 7, eyeHeight), TPDark());
        TPFillOval(ctx, CGRectMake(57.5, 38 - eyeHeight * 0.5, 7, eyeHeight), TPDark());
        if (eyeOpen > 0.5) {
            TPFillOval(ctx, CGRectMake(37.5, 35.2, 2.2, 2.2), [UIColor colorWithWhite:1 alpha:0.92]);
            TPFillOval(ctx, CGRectMake(59.5, 35.2, 2.2, 2.2), [UIColor colorWithWhite:1 alpha:0.92]);
        }
        if (hungry) {
            // 委屈的眉毛
            CGContextSetStrokeColorWithColor(ctx, [TPDark() CGColor]);
            CGContextSetLineWidth(ctx, 1.6);
            CGContextSetLineCap(ctx, kCGLineCapRound);
            CGContextMoveToPoint(ctx, 32.5, 31.5);
            CGContextAddLineToPoint(ctx, 44.5, 34.5);
            CGContextMoveToPoint(ctx, 55.5, 34.5);
            CGContextAddLineToPoint(ctx, 67.5, 31.5);
            CGContextStrokePath(ctx);
        }
    }

    // 口鼻
    TPFillOval(ctx, CGRectMake(38, 45, 13, 10), TPCream());
    TPFillOval(ctx, CGRectMake(49, 45, 13, 10), TPCream());

    // 鼻子
    TPFillTriangle(ctx, CGPointMake(46.5, 47.5), CGPointMake(53.5, 47.5), CGPointMake(50, 52), TPPink());

    // 嘴
    if (eating) {
        TPFillOval(ctx, CGRectMake(46, 52.5, 8, 7), TPDark());
    } else {
        CGContextSetStrokeColorWithColor(ctx, [TPDark() CGColor]);
        CGContextSetLineWidth(ctx, 1.2);
        CGContextSetLineCap(ctx, kCGLineCapRound);
        if (hungry) {
            CGContextMoveToPoint(ctx, 45, 58.5);
            CGContextAddQuadCurveToPoint(ctx, 50, 54.5, 55, 58.5);
        } else {
            CGContextMoveToPoint(ctx, 45, 56.5);
            CGContextAddQuadCurveToPoint(ctx, 50, 60.5, 55, 56.5);
        }
        CGContextStrokePath(ctx);
    }

    // 胡须
    CGContextSetStrokeColorWithColor(ctx, [[TPDark() colorWithAlphaComponent:0.45] CGColor]);
    CGContextSetLineWidth(ctx, 0.7);
    CGContextMoveToPoint(ctx, 26, 50);
    CGContextAddLineToPoint(ctx, 14, 47.5);
    CGContextMoveToPoint(ctx, 25.5, 54);
    CGContextAddLineToPoint(ctx, 13, 54);
    CGContextMoveToPoint(ctx, 26, 58);
    CGContextAddLineToPoint(ctx, 14, 61);
    CGContextMoveToPoint(ctx, 74, 50);
    CGContextAddLineToPoint(ctx, 86, 47.5);
    CGContextMoveToPoint(ctx, 74.5, 54);
    CGContextAddLineToPoint(ctx, 87, 54);
    CGContextMoveToPoint(ctx, 74, 58);
    CGContextAddLineToPoint(ctx, 86, 61);
    CGContextStrokePath(ctx);
}

- (void)drawHeartsInContext:(CGContextRef)ctx {
    for (NSDictionary *heart in _hearts) {
        CGFloat x = [heart[@"x"] doubleValue];
        CGFloat y = [heart[@"y"] doubleValue];
        CGFloat alpha = [heart[@"a"] doubleValue];
        CGContextSetFillColorWithColor(ctx, [[TPPink() colorWithAlphaComponent:alpha] CGColor]);
        CGContextBeginPath(ctx);
        CGContextMoveToPoint(ctx, x, y + 2.6);
        CGContextAddCurveToPoint(ctx, x - 5.2, y - 1.8, x - 3.4, y - 6.4, x, y - 2.8);
        CGContextAddCurveToPoint(ctx, x + 3.4, y - 6.4, x + 5.2, y - 1.8, x, y + 2.6);
        CGContextClosePath(ctx);
        CGContextFillPath(ctx);
    }
}

@end

#pragma mark - 悬浮层控制器（原 TPOverlayViewController）

@implementation TPPassthroughView

// 只有落到宠物身上的触摸才被吃掉，其余交给下层 App
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == self ? nil : hit;
}

@end

@implementation TPOverlayViewController {
    double _lastScale;
    double _lastOffset;
}

- (instancetype)initWithStateDir:(NSString *)stateDir {
    self = [super init];
    if (self) {
        _petView = [[TPPetView alloc] initWithStatePath:TPPetStatePath(stateDir)];

        // 窗口铺满全屏、背景透明，宠物只占顶部一小块；
        // 空白区域的 hitTest 返回 nil，触摸就会穿透到下面的 App
        TPPassthroughView *root = [[TPPassthroughView alloc] initWithFrame:CGRectZero];
        root.backgroundColor = [UIColor clearColor];
        self.view = root;

        // 窗口铺满全屏、背景透明，宠物只占顶部一小块；窗口其余区域 hitTest 返回 nil 实现穿透
        _petView.autoresizingMask = UIViewAutoresizingNone;
        _petView.backgroundColor = [UIColor clearColor];
        [root addSubview:_petView];
    }
    return self;
}

- (void)layoutPetWithScale:(double)scale topOffset:(double)offset {
    _lastScale = scale;
    _lastOffset = offset;

    CGRect bounds = self.view.bounds;
    if (CGRectGetWidth(bounds) <= 0.0) {
        // 窗口还没完成第一次布局时，退回用屏幕尺寸计算
        bounds = [UIScreen mainScreen].bounds;
    }
    CGFloat side = 112.0 * scale;
    CGFloat top = TPStatusBarHeight() + offset;
    _petView.frame = CGRectMake((CGRectGetWidth(bounds) - side) * 0.5, top, side, side);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (_lastScale > 0.0) {
        [self layoutPetWithScale:_lastScale topOffset:_lastOffset];
    }
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

@end

#pragma mark - 系统级窗口（原 TPHUDWindow）

@implementation TPHUDWindow

+ (BOOL)_isSystemWindow {
    return YES;
}

- (BOOL)_isWindowServerHostingManaged {
    return NO;
}

// NO：允许窗口接收触摸（宠物区域内的点击），窗口本身只有宠物大小，不会挡住其他区域
- (BOOL)_ignoresHitTest {
    return NO;
}

- (BOOL)_isSecure {
    return YES;
}

- (BOOL)_shouldCreateContextAsSecure {
    return YES;
}

@end

#pragma mark - 应用子类（原 TPHUDApplication）

@implementation TPHUDApplication

- (instancetype)init {
    self = [super init];
    if (self) {
        BOOL isHUD = NO;
        for (NSString *arg in [NSProcessInfo processInfo].arguments) {
            if ([arg isEqualToString:@"-hud"]) {
                isHUD = YES;
                break;
            }
        }
        if (isHUD) {
            [self tp_installEventFetcher];
        }
    }
    return self;
}

// HUD 进程不是前台 App，默认收不到触摸事件，需要手动把事件源装进主 RunLoop
- (void)tp_installEventFetcher {
    @try {
        id dispatcher = [self valueForKey:@"eventDispatcher"];
        if (!dispatcher) return;

        SEL installSelector = NSSelectorFromString(@"_installEventRunLoopSources:");
        if ([dispatcher respondsToSelector:installSelector]) {
            ((void (*)(id, SEL, CFRunLoopRef))objc_msgSend)(dispatcher, installSelector, CFRunLoopGetMain());
        }

        Class fetcherClass = objc_getClass("UIEventFetcher");
        if (!fetcherClass) return;
        id fetcher = [fetcherClass new];

        SEL sinkSelector = NSSelectorFromString(@"setEventFetcherSink:");
        if ([fetcher respondsToSelector:sinkSelector]) {
            ((void (*)(id, SEL, id))objc_msgSend)(fetcher, sinkSelector, dispatcher);
        } else {
            [fetcher setValue:dispatcher forKey:@"eventFetcherSink"];
        }
        [self setValue:fetcher forKey:@"eventFetcher"];
    } @catch (NSException *exception) {
        // 私有实现变动时静默失败：宠物仍然会显示，只是点不到
        (void)exception;
    }
}

@end

#pragma mark - HUD 模式 AppDelegate（原 TPHUDAppDelegate）

// 必须强引用，否则托管控制器会被释放，窗口随即消失
static id gWindowHostingController = nil;

// HUD 进程没有正常的前台场景，statusBarFrame 不可靠（常返回 20），
// 直接按屏幕高度判断状态栏（= 刘海 / 灵动岛）高度。
static CGFloat TPStatusBarHeight(void) {
    CGFloat screenHeight = CGRectGetHeight([UIScreen mainScreen].bounds);
    if (screenHeight >= 852.0) return 59.0;  // 灵动岛 / Pro 机型
    if (screenHeight >= 812.0) return 47.0;  // iPhone 14 等刘海机型
    return 20.0;                             // 非刘海机型
}

// 用 SBSAccessibilityWindowHostingController 把窗口注册进 SpringBoard 的辅助功能托管层
static id TPRegisterHostingWindow(UIWindow *window, NSString *stateDir) {
    Class hostingClass = objc_getClass("SBSAccessibilityWindowHostingController");
    if (!hostingClass) {
        // 类不在当前进程时，手动加载提供它的私有框架再取一次
        void *handle = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
        if (handle) {
            hostingClass = objc_getClass("SBSAccessibilityWindowHostingController");
        }
    }
    if (!hostingClass) {
        TPAppendLog(stateDir, @"hud: hostingClass missing");
        return nil;
    }

    id controller = [[hostingClass alloc] init];
    if (!controller) {
        TPAppendLog(stateDir, @"hud: hostingController nil");
        return nil;
    }

    unsigned int contextId = 0;
    SEL contextSelector = NSSelectorFromString(@"_contextId");
    if ([window respondsToSelector:contextSelector]) {
        contextId = ((unsigned int (*)(id, SEL))objc_msgSend)(window, contextSelector);
    }

    double level = window.windowLevel;
    SEL registerSelector = NSSelectorFromString(@"registerWindowWithContextID:atLevel:");
    if (![controller respondsToSelector:registerSelector]) {
        TPAppendLog(stateDir, @"hud: register selector missing contextId=%u", contextId);
        return controller;
    }

    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:"v@:Id"];
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = controller;
    invocation.selector = registerSelector;
    [invocation setArgument:&contextId atIndex:2];
    [invocation setArgument:&level atIndex:3];
    [invocation invoke];

    TPAppendLog(stateDir, @"hud: register ctx=%u level=%.0f", contextId, level);
    return controller;
}

@implementation TPHUDAppDelegate {
    TPOverlayViewController *_overlay;
    NSTimer *_watcher;
    NSString *_stateDir;
    double _scale;
    double _topOffset;
    NSTimeInterval _configMTime;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [self tp_parseArguments];

    TPAppendLog(_stateDir, @"hud: launch pid=%d uid=%d", getpid(), getuid());

    _overlay = [[TPOverlayViewController alloc] initWithStateDir:_stateDir];

    // 全屏透明窗口 + 顶部宠物视图，与 TrollSpeed 的 HUD 窗口保持一致
    TPHUDWindow *window = [[TPHUDWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    window.rootViewController = _overlay;
    window.backgroundColor = [UIColor clearColor];
    window.windowLevel = 10000010.0;
    self.window = window;

    [self tp_layoutWindow];
    [window setHidden:NO];
    [window makeKeyAndVisible];

    TPAppendLog(_stateDir, @"hud: window frame=%@ level=%.0f key=%d",
                NSStringFromCGRect(window.bounds), window.windowLevel, window.isKeyWindow);

    gWindowHostingController = TPRegisterHostingWindow(window, _stateDir);

    TPAppendLog(_stateDir, @"hud: hosted=%d", gWindowHostingController ? 1 : 0);

    _watcher = [NSTimer scheduledTimerWithTimeInterval:0.6
                                                 target:self
                                               selector:@selector(tp_onWatchTimer:)
                                               userInfo:nil
                                                repeats:YES];

    // 2 秒后复核一次，确认窗口与宠物视图真的存在尺寸（这是 HUD 不出来时最关键的一条）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        TPAppendLog(self->_stateDir, @"hud: tick hidden=%d win=%@ pet=%@",
                    window.hidden, NSStringFromCGRect(window.bounds),
                    NSStringFromCGRect(self->_overlay.petView.frame));
    });

    return YES;
}

#pragma mark - 参数与布局

- (void)tp_parseArguments {
    NSArray<NSString *> *arguments = [NSProcessInfo processInfo].arguments;
    _stateDir = nil;
    _scale = 0.9;
    _topOffset = 6.0;

    for (NSUInteger i = 1; i + 1 < arguments.count; i++) {
        NSString *key = arguments[i];
        NSString *value = arguments[i + 1];
        if ([key isEqualToString:@"-stateDir"]) {
            _stateDir = value;
            i++;
        } else if ([key isEqualToString:@"-scale"]) {
            _scale = value.doubleValue;
            i++;
        } else if ([key isEqualToString:@"-topOffset"]) {
            _topOffset = value.doubleValue;
            i++;
        }
    }

    if (_stateDir.length == 0) {
        _stateDir = TPStateDirectory();
    }
    if (_scale < 0.5 || _scale > 2.0) _scale = 0.9;
    if (_topOffset < 0.0 || _topOffset > 80.0) _topOffset = 6.0;

    [[NSFileManager defaultManager] createDirectoryAtPath:_stateDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:TPConfigPath(_stateDir)
                                                                                error:nil];
    _configMTime = [attributes[NSFileModificationDate] timeIntervalSince1970];
}

- (void)tp_layoutWindow {
    // 窗口本身铺满全屏（保持窗口上下文尺寸正常），宠物视图负责定位在顶部
    [_overlay layoutPetWithScale:_scale topOffset:_topOffset];
}

#pragma mark - 控制文件轮询

- (void)tp_onWatchTimer:(NSTimer *)timer {
    NSFileManager *fileManager = [NSFileManager defaultManager];

    // 主 App 要求退出
    NSString *stopPath = TPStopRequestPath(_stateDir);
    if ([fileManager fileExistsAtPath:stopPath]) {
        [fileManager removeItemAtPath:stopPath error:nil];
        [fileManager removeItemAtPath:TPPidPath(_stateDir) error:nil];
        [timer invalidate];
        _watcher = nil;
        self.window.hidden = YES;
        exit(0);
    }

    // 主 App 的"喂食"按钮
    NSString *feedPath = TPFeedRequestPath(_stateDir);
    if ([fileManager fileExistsAtPath:feedPath]) {
        [fileManager removeItemAtPath:feedPath error:nil];
        [_overlay.petView feed];
    }

    // 配置热更新（大小 / 距顶部距离）
    NSDictionary *attributes = [fileManager attributesOfItemAtPath:TPConfigPath(_stateDir) error:nil];
    NSTimeInterval mtime = [attributes[NSFileModificationDate] timeIntervalSince1970];
    if (mtime > _configMTime + 0.001) {
        _configMTime = mtime;
        NSDictionary *config = TPReadConfig(_stateDir);
        double scale = [config[@"scale"] doubleValue];
        double topOffset = [config[@"topOffset"] doubleValue];
        BOOL scaleChanged = fabs(scale - _scale) > 0.001;
        BOOL offsetChanged = fabs(topOffset - _topOffset) > 0.001;
        _scale = scale;
        _topOffset = topOffset;
        if (scaleChanged || offsetChanged) {
            [self tp_layoutWindow];
        }
    }
}

@end

#pragma mark - 设置界面（原 TPMainViewController）

@implementation TPMainViewController {
    UISwitch *_enabledSwitch;
    UISlider *_scaleSlider;
    UISlider *_offsetSlider;
    UILabel *_scaleValueLabel;
    UILabel *_offsetValueLabel;
    UILabel *_statusLabel;
    UIButton *_feedButton;
    UITextView *_diagView;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"顶部宠物 v3";
    self.view.backgroundColor = [UIColor colorWithWhite:0.07 alpha:1.0];

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSNumber *savedScale = [defaults objectForKey:@"scale"];
    NSNumber *savedOffset = [defaults objectForKey:@"topOffset"];
    double scale = savedScale ? savedScale.doubleValue : 0.9;
    double offset = savedOffset ? savedOffset.doubleValue : 6.0;

    UILabel *headline = [self labelWithText:@"在听筒下方养一只宠物"
                                       size:22.0
                                      weight:UIFontWeightBold
                                      color:[UIColor whiteColor]];

    UILabel *description = [self labelWithText:@"开启后，宠物会固定在屏幕顶部（摄像头 / 听筒下方），并始终显示在所有 App 之上。点击宠物它会开心，长按宠物可以喂食。"
                                          size:13.0
                                         weight:UIFontWeightRegular
                                         color:[UIColor colorWithWhite:0.68 alpha:1.0]];

    UILabel *switchTitle = [self labelWithText:@"启用悬浮宠物"
                                          size:16.0
                                         weight:UIFontWeightRegular
                                         color:[UIColor whiteColor]];

    _enabledSwitch = [[UISwitch alloc] init];
    BOOL enabled = [defaults objectForKey:@"enabled"] ? [defaults boolForKey:@"enabled"] : YES;
    _enabledSwitch.on = enabled;
    [_enabledSwitch addTarget:self
                        action:@selector(enabledChanged:)
              forControlEvents:UIControlEventValueChanged];
    [switchTitle setContentHuggingPriority:UILayoutPriorityDefaultHigh
                            forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *switchRow = [self rowWithViews:@[ switchTitle, _enabledSwitch ]];
    switchRow.distribution = UIStackViewDistributionEqualSpacing;

    // 大小
    _scaleSlider = [[UISlider alloc] init];
    _scaleSlider.minimumValue = 0.6;
    _scaleSlider.maximumValue = 1.6;
    _scaleSlider.value = (float)scale;
    [_scaleSlider addTarget:self
                      action:@selector(sliderChanged:)
            forControlEvents:UIControlEventValueChanged];

    _scaleValueLabel = [self valueLabel];
    UIStackView *scaleRow = [self sliderRowWithTitle:@"大小"
                                              slider:_scaleSlider
                                          valueLabel:_scaleValueLabel];

    // 距顶部距离
    _offsetSlider = [[UISlider alloc] init];
    _offsetSlider.minimumValue = 0.0;
    _offsetSlider.maximumValue = 40.0;
    _offsetSlider.value = (float)offset;
    [_offsetSlider addTarget:self
                       action:@selector(sliderChanged:)
             forControlEvents:UIControlEventValueChanged];

    _offsetValueLabel = [self valueLabel];
    UIStackView *offsetRow = [self sliderRowWithTitle:@"距顶部距离"
                                               slider:_offsetSlider
                                           valueLabel:_offsetValueLabel];

    _feedButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_feedButton setTitle:@"喂食一次" forState:UIControlStateNormal];
    _feedButton.titleLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightMedium];
    [_feedButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _feedButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    _feedButton.layer.cornerRadius = 12.0;
    [_feedButton.heightAnchor constraintEqualToConstant:46.0].active = YES;
    [_feedButton addTarget:self action:@selector(feedTapped) forControlEvents:UIControlEventTouchUpInside];

    _statusLabel = [self labelWithText:@"状态：未运行"
                                   size:13.0
                                 weight:UIFontWeightRegular
                                 color:[UIColor colorWithWhite:0.60 alpha:1.0]];

    UILabel *hint = [self labelWithText:@"提示：重启手机后，需要重新打开本 App 一次，宠物才会重新出现。"
                                    size:11.0
                                  weight:UIFontWeightRegular
                                  color:[UIColor colorWithWhite:0.45 alpha:1.0]];

    // 诊断区：宠物没出现时，点"复制诊断信息"把这段文字发给我即可定位问题
    UIButton *copyButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [copyButton setTitle:@"复制诊断信息" forState:UIControlStateNormal];
    copyButton.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightMedium];
    [copyButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    copyButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
    copyButton.layer.cornerRadius = 10.0;
    [copyButton.heightAnchor constraintEqualToConstant:38.0].active = YES;
    [copyButton addTarget:self action:@selector(copyDiagnostics) forControlEvents:UIControlEventTouchUpInside];

    _diagView = [[UITextView alloc] init];
    _diagView.editable = NO;
    _diagView.scrollEnabled = YES;
    _diagView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
    _diagView.textColor = [UIColor colorWithWhite:0.75 alpha:1.0];
    _diagView.font = [UIFont monospacedSystemFontOfSize:10.5 weight:UIFontWeightRegular];
    _diagView.layer.cornerRadius = 10.0;
    _diagView.textContainerInset = UIEdgeInsetsMake(8.0, 8.0, 8.0, 8.0);
    _diagView.text = @"（暂无日志）";
    [_diagView.heightAnchor constraintEqualToConstant:140.0].active = YES;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        headline, description, switchRow, scaleRow, offsetRow, _feedButton, _statusLabel, copyButton, _diagView, hint
    ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 18.0;
    stack.alignment = UIStackViewAlignmentFill;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [stack setCustomSpacing:28.0 afterView:description];
    [stack setCustomSpacing:24.0 afterView:_feedButton];
    [self.view addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:24.0],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-24.0],
        [stack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:24.0],
    ]];

    [self updateValueLabels];
    [self refreshStatus];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    TPAppendLog(TPStateDirectory(), @"ui: viewDidAppear on=%d running=%d",
                _enabledSwitch.isOn ? 1 : 0, TPHUDIsRunning() ? 1 : 0);
    // 开机后第一次打开 App，自动把宠物拉起来
    if (_enabledSwitch.isOn && !TPHUDIsRunning()) {
        [self applySettings];
    } else {
        [self refreshStatus];
    }
}

#pragma mark - 控件工厂

- (UILabel *)labelWithText:(NSString *)text
                      size:(CGFloat)size
                    weight:(UIFontWeight)weight
                     color:(UIColor *)color {
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    label.numberOfLines = 0;
    return label;
}

- (UILabel *)valueLabel {
    UILabel *label = [self labelWithText:@""
                                     size:13.0
                                   weight:UIFontWeightMedium
                                    color:[UIColor colorWithWhite:0.75 alpha:1.0]];
    label.textAlignment = NSTextAlignmentRight;
    [label setContentHuggingPriority:UILayoutPriorityRequired
                              forAxis:UILayoutConstraintAxisHorizontal];
    return label;
}

- (UIStackView *)rowWithViews:(NSArray<UIView *> *)views {
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:views];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 12.0;
    return row;
}

- (UIStackView *)sliderRowWithTitle:(NSString *)title
                             slider:(UISlider *)slider
                         valueLabel:(UILabel *)valueLabel {
    UILabel *titleLabel = [self labelWithText:title
                                          size:15.0
                                        weight:UIFontWeightRegular
                                         color:[UIColor whiteColor]];
    [titleLabel setContentHuggingPriority:UILayoutPriorityRequired
                                   forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *topRow = [self rowWithViews:@[ titleLabel, valueLabel ]];
    topRow.distribution = UIStackViewDistributionEqualSpacing;

    UIStackView *column = [[UIStackView alloc] initWithArrangedSubviews:@[ topRow, slider ]];
    column.axis = UILayoutConstraintAxisVertical;
    column.spacing = 8.0;
    column.alignment = UIStackViewAlignmentFill;
    return column;
}

#pragma mark - 状态更新

- (void)updateValueLabels {
    _scaleValueLabel.text = [NSString stringWithFormat:@"%.2fx", _scaleSlider.value];
    _offsetValueLabel.text = [NSString stringWithFormat:@"%.0f pt", _offsetSlider.value];
}

- (void)refreshStatus {
    NSFileManager *fileManager = [NSFileManager defaultManager];

    // 诊断信息：无论运行与否都显示，出问题时把这行文字复制出来即可定位
    [self refreshDiagnostics];

    if (!TPHUDIsRunning()) {
        if (gTPLastStartError.length > 0) {
            _statusLabel.text = [NSString stringWithFormat:@"状态：启动失败 %@", gTPLastStartError];
        } else {
            _statusLabel.text = @"状态：未运行";
        }
        _feedButton.enabled = NO;
        _feedButton.alpha = 0.5;
        return;
    }

    _feedButton.enabled = YES;
    _feedButton.alpha = 1.0;

    double hunger = 0.0;
    NSString *statePath = TPPetStatePath(TPStateDirectory());
    if ([fileManager fileExistsAtPath:statePath]) {
        NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:statePath];
        hunger = [state[@"hunger"] doubleValue];
        NSTimeInterval savedAt = [state[@"date"] doubleValue];
        if (savedAt > 0.0) {
            double minutes = MAX(0.0, [[NSDate date] timeIntervalSince1970] - savedAt) / 60.0;
            hunger = MIN(100.0, hunger + minutes * (100.0 / 1440.0));
        }
    }
    _statusLabel.text = [NSString stringWithFormat:@"状态：运行中 · 饥饿度 %.0f%%", hunger];
}

- (void)refreshDiagnostics {
    if (_diagView == nil) return;

    NSString *stateDir = TPStateDirectory();
    NSString *logPath = TPLogPath(stateDir);
    NSFileManager *fm = [NSFileManager defaultManager];

    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    [lines addObject:@"== v3 自检 =="];
    [lines addObject:[NSString stringWithFormat:@"dir=%@", stateDir]];
    [lines addObject:[NSString stringWithFormat:@"uid=%d readVarMobile=%d", getuid(),
                      [fm isReadableFileAtPath:@"/var/mobile"] ? 1 : 0]];
    [lines addObject:[NSString stringWithFormat:@"logfile=%@", [fm fileExistsAtPath:logPath] ? @"exists" : @"missing"]];

    // 写入探测：用单独文件试写，判断是否只是日志文件写不进去
    NSString *probePath = TPFile(stateDir, @"probe.txt");
    NSString *probe = [NSString stringWithFormat:@"p-%f", [[NSDate date] timeIntervalSince1970]];
    NSError *probeError = nil;
    BOOL probeOK = [probe writeToFile:probePath atomically:YES encoding:NSUTF8StringEncoding error:&probeError];
    [lines addObject:[NSString stringWithFormat:@"probe=%@ %@", probeOK ? @"ok" : @"FAIL",
                      probeError ? probeError.localizedDescription : @""]];

    NSString *fileText = [NSString stringWithContentsOfFile:logPath encoding:NSUTF8StringEncoding error:nil];
    [lines addObject:@"-- file log --"];
    [lines addObject:fileText.length > 0 ? fileText : @"(empty)"];

    [lines addObject:@"-- memory log --"];
    if (gTPLogLines.count > 0) {
        [lines addObjectsFromArray:gTPLogLines];
    } else {
        [lines addObject:@"(empty)"];
    }

    _diagView.text = [lines componentsJoinedByString:@"\n"];
}

- (void)copyDiagnostics {
    UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
    pasteboard.string = _diagView.text.length > 0 ? _diagView.text : @"（暂无日志）";
    UIImpactFeedbackGenerator *generator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [generator impactOccurred];
}

#pragma mark - 交互

- (void)enabledChanged:(UISwitch *)sender {
    TPAppendLog(TPStateDirectory(), @"ui: switch=%d", sender.isOn ? 1 : 0);
    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:@"enabled"];
    [self applySettings];
}

- (void)sliderChanged:(UISlider *)sender {
    [self updateValueLabels];
    // 运行中时写配置即可热更新，不用重启宠物进程
    [[NSUserDefaults standardUserDefaults] setDouble:_scaleSlider.value forKey:@"scale"];
    [[NSUserDefaults standardUserDefaults] setDouble:_offsetSlider.value forKey:@"topOffset"];
    if (_enabledSwitch.isOn) {
        TPWriteConfig(TPStateDirectory(), _scaleSlider.value, _offsetSlider.value);
    }
}

- (void)feedTapped {
    TPRequestFeed(TPStateDirectory());
    UIImpactFeedbackGenerator *generator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [generator impactOccurred];

    [_statusLabel setText:@"状态：已投喂，宠物正在进食…"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self refreshStatus];
    });
}

- (void)applySettings {
    BOOL enabled = _enabledSwitch.isOn;
    double scale = _scaleSlider.value;
    double offset = _offsetSlider.value;

    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:@"enabled"];
    [[NSUserDefaults standardUserDefaults] setDouble:scale forKey:@"scale"];
    [[NSUserDefaults standardUserDefaults] setDouble:offset forKey:@"topOffset"];

    if (enabled) {
        TPStartHUD(TPStateDirectory(), scale, offset);
    } else {
        TPStopHUD(TPStateDirectory());
    }

    [self refreshStatus];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSString *pidText = [NSString stringWithContentsOfFile:TPPidPath(TPStateDirectory())
                                                       encoding:NSUTF8StringEncoding
                                                          error:nil];
        TPAppendLog(TPStateDirectory(), @"ui: after1s pid=%@ alive=%d", pidText.length > 0 ? pidText : @"nil",
                    TPHUDIsRunning() ? 1 : 0);
        [self refreshStatus];
    });
}

@end

#pragma mark - 普通模式 AppDelegate（原 TPMainAppDelegate）

@implementation TPMainAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    TPAppendLog(TPStateDirectory(), @"main: app launched uid=%d", getuid());

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];

    TPMainViewController *viewController = [[TPMainViewController alloc] init];
    UINavigationController *navigationController = [[UINavigationController alloc] initWithRootViewController:viewController];
    navigationController.navigationBar.prefersLargeTitles = NO;
    navigationController.navigationBar.tintColor = [UIColor whiteColor];

    UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
    [appearance configureWithOpaqueBackground];
    appearance.backgroundColor = [UIColor colorWithWhite:0.07 alpha:1.0];
    appearance.titleTextAttributes = @{ NSForegroundColorAttributeName: [UIColor whiteColor] };
    navigationController.navigationBar.standardAppearance = appearance;
    navigationController.navigationBar.scrollEdgeAppearance = appearance;

    self.window.rootViewController = navigationController;
    [self.window makeKeyAndVisible];
    return YES;
}

@end

#pragma mark - 入口

int main(int argc, char *argv[]) {
    @autoreleasepool {
        BOOL hudMode = NO;
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "-hud") == 0) {
                hudMode = YES;
                break;
            }
        }
        // 显式指定 UIApplication 子类，HUD 模式下它会在 init 里安装触摸事件源
        NSString *delegateClassName = hudMode ? @"TPHUDAppDelegate" : @"TPMainAppDelegate";
        return UIApplicationMain(argc, argv, @"TPHUDApplication", delegateClassName);
    }
}
