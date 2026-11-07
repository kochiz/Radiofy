// Radiofy 3.5-MULTIVERSE — menu-bar digital radio (Spotify.app local-first + Web API opcional).
// UI: WKWebView (ui/index.html). Bridge: messageHandlers.radio.
// Build: ./build_mac.sh
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <CommonCrypto/CommonDigest.h>
#import <ApplicationServices/ApplicationServices.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <poll.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static const CGFloat kW = 360, kH = 640, kHOver = 56, kRadius = 24;

@interface RadioPanel : NSPanel
@end
@implementation RadioPanel
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

@interface WeakMsg : NSObject <WKScriptMessageHandler>
@property (weak) id<WKScriptMessageHandler> target;
@end
@implementation WeakMsg
- (void)userContentController:(WKUserContentController *)c didReceiveScriptMessage:(WKScriptMessage *)m { [self.target userContentController:c didReceiveScriptMessage:m]; }
@end

static NSImage *RoundedMask(CGFloat r) {
    CGFloat e = r * 2 + 1;
    NSImage *m = [NSImage imageWithSize:NSMakeSize(e, e) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        [[NSColor blackColor] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:r yRadius:r] fill];
        return YES;
    }];
    m.capInsets = NSEdgeInsetsMake(r, r, r, r);
    m.resizingMode = NSImageResizingModeStretch;
    return m;
}

// radio-wave glyph (line style, template so it follows the menu bar appearance)
static NSImage *WaveIcon(void) {
    NSImage *im = [NSImage imageWithSize:NSMakeSize(20, 18) flipped:NO drawingHandler:^BOOL(NSRect r) {
        NSBezierPath *p = [NSBezierPath bezierPath];
        p.lineWidth = 1.6; p.lineCapStyle = NSLineCapStyleRound; p.lineJoinStyle = NSLineJoinStyleRound;
        [p moveToPoint:NSMakePoint(1.5, 9)];
        [p curveToPoint:NSMakePoint(6, 9) controlPoint1:NSMakePoint(3, 9) controlPoint2:NSMakePoint(4.5, 12)];
        [p curveToPoint:NSMakePoint(10, 9) controlPoint1:NSMakePoint(7.5, 3) controlPoint2:NSMakePoint(8.5, 16)];
        [p curveToPoint:NSMakePoint(14, 9) controlPoint1:NSMakePoint(11.5, 1.5) controlPoint2:NSMakePoint(12.5, 14)];
        [p curveToPoint:NSMakePoint(18.5, 9) controlPoint1:NSMakePoint(15.5, 5) controlPoint2:NSMakePoint(17, 9)];
        [[NSColor blackColor] setStroke];
        [p stroke];
        return YES;
    }];
    im.template = YES;
    return im;
}

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKScriptMessageHandler>
@property (strong) NSStatusItem *item;
@property (strong) RadioPanel *panel;
@property (strong) WKWebView *web;
@property BOOL webReady;
@property (strong) NSMutableArray *pendingJS;
@property (strong) NSTimer *teardownTimer, *pollTimer;
@property (strong) id globalMon;
@property (strong) id<NSObject> frameActivity;
@property NSTimeInterval hiddenAt;
@property (strong) NSMutableDictionary *store;   // persisted state.json
@property (strong) dispatch_queue_t q;
@property (strong) dispatch_queue_t asQueue; // AppleScript / osascript — NUNCA el main
@property BOOL busy, polling, pendingRadio;
@property (atomic) NSInteger webWaitId;
@property (strong) NSURLSession *session;
@property (copy) NSString *clientId, *meId, *meCountry, *lastAuthErr;
@property (strong) NSMutableDictionary *tokens;      // tokens.json (0600)
@property (atomic) int listenFd;
@property (atomic) NSInteger tuneWatchId;
@property NSTimeInterval backoffUntil, playlistsAt, last429NoteAt;
@property (strong) NSArray *playlists;
@property (strong) NSMutableDictionary *totals, *recent;
@property (strong) NSMutableArray *recentUris, *arts, *recentArtists, *trackPool;
@property (strong) NSMutableSet *blockedUris; // no reproducibles (CL / local) — no volver a play
@property (strong) NSMutableDictionary *playlistSeeds; // id → {seed, apiOk} probe en background
@property (copy) NSString *onAirUri, *onAirArtist, *poolSrc, *localCtxSrc;
@property (strong) NSMutableDictionary *primedNext; // siguiente canción lista para el dial/Cambiar
@property NSInteger poolTotal;
@property NSTimeInterval lastTuneAt; // gracia post-tune mientras Spotify asienta
@property BOOL awaitingEnd, overscreen, pendingTuneFromStart, useLocalSpotify, suppressResignHide, appleEventsDenied, loadingPlaylists, pinnedTop;
@property (copy) NSString *lastAppleScriptErr;
@property (strong) NSRunningApplication *frontBeforeSpotifyAS;
@property BOOL spotifyWasFrontBeforeAS;
@property NSInteger spotifyASQuietDepth;
@end

@implementation AppDelegate

#pragma mark - persistence
- (NSString *)supportDir {
    NSString *d = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Radio"];
    [[NSFileManager defaultManager] createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}
- (NSString *)logPath {
    return [[self supportDir] stringByAppendingPathComponent:@"radiofy.log"];
}
- (void)radioLog:(NSString *)fmt, ... NS_FORMAT_FUNCTION(1,2) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (!msg.length) return;
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:[self logPath]];
    if (!fh) {
        [line writeToFile:[self logPath] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    @try {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        // rotación simple ~256 KB
        if (fh.offsetInFile > 256000) {
            [fh truncateFileAtOffset:0];
            [fh writeData:[@"--- radiofy log rotated ---\n" dataUsingEncoding:NSUTF8StringEncoding]];
        }
    } @finally { [fh closeFile]; }
}
- (NSString *)storePath {
    return [[self supportDir] stringByAppendingPathComponent:@"state.json"];
}
- (NSString *)poolPath {
    return [[self supportDir] stringByAppendingPathComponent:@"trackPool.json"];
}
- (void)loadStore {
    NSData *d = [NSData dataWithContentsOfFile:[self storePath]];
    id j = d ? [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:nil] : nil;
    self.store = [j isKindOfClass:[NSDictionary class]] ? j : [NSMutableDictionary dictionary];
    NSString *cur = self.store[@"cur"];
    if (![cur isKindOfClass:[NSString class]] || [cur hasPrefix:@"spotify:"]) { self.store[@"cur"] = @"liked"; self.store[@"curName"] = @"Liked Songs"; }
    [self.store removeObjectForKey:@"sources"]; [self.store removeObjectForKey:@"likedURI"];
}
- (void)saveStore {
    NSData *d = [NSJSONSerialization dataWithJSONObject:self.store options:NSJSONWritingPrettyPrinted error:nil];
    [d writeToFile:[self storePath] atomically:YES];
}

#pragma mark - lifecycle
- (void)applicationDidFinishLaunching:(NSNotification *)n {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    self.q = dispatch_queue_create("radio.spotify", DISPATCH_QUEUE_SERIAL);
    self.asQueue = dispatch_queue_create("radio.applescript", DISPATCH_QUEUE_SERIAL);
    self.pendingJS = [NSMutableArray array];
    [self loadStore];
    [self loadAuth];
    self.totals = [NSMutableDictionary dictionary]; self.recent = [NSMutableDictionary dictionary]; self.recentUris = [NSMutableArray array];
    self.arts = [NSMutableArray array]; self.recentArtists = [NSMutableArray array];
    self.trackPool = [NSMutableArray array]; self.blockedUris = [NSMutableSet set];
    self.playlistSeeds = [NSMutableDictionary dictionary]; self.poolSrc = nil; self.poolTotal = 0;
    {
        NSData *sd = [NSData dataWithContentsOfFile:[[self supportDir] stringByAppendingPathComponent:@"playlistSeeds.json"]];
        id sj = sd.length ? [NSJSONSerialization JSONObjectWithData:sd options:0 error:nil] : nil;
        if ([sj isKindOfClass:[NSDictionary class]]) [self.playlistSeeds addEntriesFromDictionary:sj];
    }
    self.awaitingEnd = NO; self.overscreen = NO; self.backoffUntil = 0; self.last429NoteAt = 0;
    self.useLocalSpotify = [[NSFileManager defaultManager] fileExistsAtPath:@"/Applications/Spotify.app"];
    self.appleEventsDenied = NO;
    self.lastAppleScriptErr = nil;
    if ([self.store[@"meId"] isKindOfClass:[NSString class]] && [self.store[@"meId"] length]) self.meId = self.store[@"meId"];
    if ([self.store[@"meCountry"] isKindOfClass:[NSString class]] && [self.store[@"meCountry"] length]) self.meCountry = self.store[@"meCountry"];
    // Pedir Automatización Radiofy → Spotify (sin esto Cambiar local falla)
    if (self.useLocalSpotify) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSAppleEventDescriptor *target = [NSAppleEventDescriptor descriptorWithBundleIdentifier:@"com.spotify.client"];
            if (target) AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, true);
        });
    }
    NSArray *savedArts = self.store[@"arts"];
    if ([savedArts isKindOfClass:[NSArray class]]) for (id u in savedArts) if ([u isKindOfClass:[NSString class]] && [u length]) [self.arts addObject:u];
    [self loadPlayMemory];
    [self loadTrackPool];
    // 2.10: sacar la “cuarentena” inventada en 2.9
    if (self.store[@"quiet291"] || ![self.store[@"clearedFakeQuiet210"] boolValue]) {
        [self.store removeObjectForKey:@"quiet291"];
        [self.store removeObjectForKey:@"backoffUntilEpoch"];
        self.store[@"clearedFakeQuiet210"] = @YES;
        self.backoffUntil = 0;
        [self saveStore];
    } else {
        NSTimeInterval until = [self.store[@"backoffUntilEpoch"] doubleValue];
        NSTimeInterval nowEpoch = [[NSDate date] timeIntervalSince1970];
        if (until > nowEpoch) {
            self.backoffUntil = [NSDate timeIntervalSinceReferenceDate] + (until - nowEpoch);
        } else if (self.store[@"backoffUntilEpoch"]) {
            [self.store removeObjectForKey:@"backoffUntilEpoch"];
            [self saveStore];
        }
    }
    // 2.14: play local → la cuota Web API ya no bloquea Cambiar si hay pool.
    // Limpia backoff local una vez para poder llenar el pool con 1 GET.
    if (self.useLocalSpotify && ![self.store[@"localPlay214"] boolValue]) {
        self.store[@"localPlay214"] = @YES;
        self.backoffUntil = 0;
        [self.store removeObjectForKey:@"backoffUntilEpoch"];
        [self saveStore];
    }
    // b25: el probe de b24 dejó 429; limpiar una vez para que Liked/pool vuelvan.
    if (![self.store[@"clearedProbeBackoff25"] boolValue]) {
        self.store[@"clearedProbeBackoff25"] = @YES;
        self.backoffUntil = 0;
        [self.store removeObjectForKey:@"backoffUntilEpoch"];
        [self saveStore];
    }
    NSURLSessionConfiguration *sc = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    sc.URLCache = nil; sc.HTTPMaximumConnectionsPerHost = 2;
    self.session = [NSURLSession sessionWithConfiguration:sc];
    NSMenu *main = [[NSMenu alloc] init];
    NSMenuItem *ei = [main addItemWithTitle:@"Edición" action:nil keyEquivalent:@""];
    NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edición"];
    [edit addItemWithTitle:@"Cortar" action:@selector(cut:) keyEquivalent:@"x"];
    [edit addItemWithTitle:@"Copiar" action:@selector(copy:) keyEquivalent:@"c"];
    [edit addItemWithTitle:@"Pegar" action:@selector(paste:) keyEquivalent:@"v"];
    [edit addItemWithTitle:@"Seleccionar todo" action:@selector(selectAll:) keyEquivalent:@"a"];
    ei.submenu = edit;
    NSApp.mainMenu = main;

    self.item = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
    self.item.button.image = WaveIcon();
    self.item.button.toolTip = @"Radiofy";
    self.item.button.target = self;
    self.item.button.action = @selector(clicked:);
    [self.item.button sendActionOn:NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp];
    [self buildPanel];
}

- (void)applicationWillTerminate:(NSNotification *)n { [self stopListener]; }

- (void)clicked:(id)s {
    NSEvent *e = NSApp.currentEvent;
    if (e.type == NSEventTypeRightMouseUp || (e.modifierFlags & NSEventModifierFlagControl)) {
        NSMenu *m = [[NSMenu alloc] init];
        [m addItemWithTitle:@"Acerca de Radiofy" action:@selector(showAbout:) keyEquivalent:@""].target = self;
        [m addItemWithTitle:@"Reiniciar memoria" action:@selector(clearSongCache:) keyEquivalent:@""].target = self;
        [m addItem:[NSMenuItem separatorItem]];
        if ([self authed]) { [m addItemWithTitle:@"Desconectar" action:@selector(disconnect:) keyEquivalent:@""].target = self; [m addItem:[NSMenuItem separatorItem]]; }
        [m addItemWithTitle:@"Salir de Radiofy" action:@selector(terminate:) keyEquivalent:@""];
        [self hidePanel];
        [self.item popUpStatusItemMenu:m];
        return;
    }
    if (self.overscreen && self.panel.isVisible) { [self setOverscreenMode:NO]; return; }
    if (self.panel.isVisible) [self hidePanel];
    else if ([NSDate timeIntervalSinceReferenceDate] - self.hiddenAt > 0.25) [self showPanel];
}

- (void)buildPanel {
    self.panel = [[RadioPanel alloc] initWithContentRect:NSMakeRect(0, 0, kW, kH) styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
    self.panel.opaque = NO;
    self.panel.backgroundColor = [NSColor clearColor];
    self.panel.hasShadow = YES;
    self.panel.level = NSStatusWindowLevel;
    self.pinnedTop = NO;
    self.panel.hidesOnDeactivate = NO;
    self.panel.floatingPanel = YES;
    self.panel.releasedWhenClosed = NO;
    self.panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorTransient | NSWindowCollectionBehaviorIgnoresCycle | NSWindowCollectionBehaviorFullScreenAuxiliary;
    self.panel.delegate = self;
    self.panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    NSVisualEffectView *fx = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, kW, kH)];
    fx.material = NSVisualEffectMaterialHUDWindow;
    fx.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    fx.state = NSVisualEffectStateActive;
    fx.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    fx.maskImage = RoundedMask(kRadius);
    fx.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    fx.wantsLayer = YES;
    self.panel.contentView = fx;
}

#pragma mark - web view (kept ~5 min after close for instant reopen)
- (void)makeWeb {
    if (self.web) return;
    WKWebViewConfiguration *wc = [[WKWebViewConfiguration alloc] init];
    wc.processPool = [[WKProcessPool alloc] init];
    WeakMsg *wm = [[WeakMsg alloc] init];
    wm.target = self;
    [wc.userContentController addScriptMessageHandler:wm name:@"radio"];
    wc.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
    wc.suppressesIncrementalRendering = YES;
    NSView *fx = self.panel.contentView;
    WKWebView *w = [[WKWebView alloc] initWithFrame:fx.bounds configuration:wc];
    w.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    w.navigationDelegate = self;
    [w setValue:@NO forKey:@"drawsBackground"];
    w.allowsMagnification = NO;
    w.wantsLayer = YES;
    w.layer.cornerRadius = kRadius;
    w.layer.masksToBounds = YES;
    w.alphaValue = 0;
    [fx addSubview:w];
    self.web = w;
    self.webReady = NO;
    NSURL *ui = [[NSBundle mainBundle] URLForResource:@"ui" withExtension:nil];
    [w loadFileURL:[ui URLByAppendingPathComponent:@"index.html"] allowingReadAccessToURL:ui];
}
- (void)webView:(WKWebView *)w didFinishNavigation:(WKNavigation *)nav {
    if (w != self.web || self.webReady) return;
    self.webReady = YES;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *c) { c.duration = 0.12; [[self.web animator] setAlphaValue:1]; } completionHandler:nil];
    NSArray *q = [self.pendingJS copy];
    [self.pendingJS removeAllObjects];
    for (NSString *js in q) [self.web evaluateJavaScript:js completionHandler:nil];
}
- (void)webView:(WKWebView *)w decidePolicyForNavigationAction:(WKNavigationAction *)a decisionHandler:(void (^)(WKNavigationActionPolicy))h {
    h(a.request.URL.isFileURL ? WKNavigationActionPolicyAllow : WKNavigationActionPolicyCancel);
}
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)w { if (w == self.web) { [self teardownWeb]; if (self.panel.isVisible) [self makeWeb]; } }
- (void)teardownWeb {
    WKWebView *w = self.web;
    if (!w) return;
    self.web = nil; self.webReady = NO;
    [self.pendingJS removeAllObjects];
    [w stopLoading];
    w.navigationDelegate = nil;
    [w.configuration.userContentController removeScriptMessageHandlerForName:@"radio"];
    [w removeFromSuperview];
}
- (void)send:(NSDictionary *)o {
    NSData *d = [NSJSONSerialization dataWithJSONObject:o options:0 error:nil];
    if (!d) return;
    NSString *js = [NSString stringWithFormat:@"window.onNative&&window.onNative(%@)", [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.web) return;
        if (self.webReady) [self.web evaluateJavaScript:js completionHandler:nil]; else [self.pendingJS addObject:js];
    });
}

#pragma mark - panel
- (NSRect)panelFrame {
    NSWindow *bw = self.item.button.window;
    NSScreen *sc = bw.screen ?: NSScreen.mainScreen;
    NSRect br = bw ? bw.frame : NSMakeRect(sc.frame.size.width - 200, sc.frame.size.height - 24, 30, 24);
    NSRect vf = sc.visibleFrame;
    CGFloat h = self.overscreen ? kHOver : kH;
    CGFloat x = MAX(NSMinX(vf) + 8, MIN(NSMidX(br) - kW / 2, NSMaxX(vf) - kW - 8));
    CGFloat y = self.overscreen ? (NSMaxY(vf) - h - 2) : MAX(NSMinY(vf) + 4, NSMinY(br) - h - 5);
    return NSMakeRect(x, y, kW, h);
}
- (void)applyPanelChrome {
    NSView *fx = self.panel.contentView;
    if ([fx isKindOfClass:[NSVisualEffectView class]]) ((NSVisualEffectView *)fx).maskImage = RoundedMask(self.overscreen ? 12 : kRadius);
    if (self.web) { self.web.layer.cornerRadius = self.overscreen ? 12 : kRadius; self.web.frame = fx.bounds; }
}
- (void)applyWindowLevel {
    // Pin: encima de casi todo (apps normales). Sin pin: nivel de menú status.
    self.panel.level = self.pinnedTop ? (NSMainMenuWindowLevel + 2) : NSStatusWindowLevel;
    self.panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorTransient | NSWindowCollectionBehaviorIgnoresCycle | NSWindowCollectionBehaviorFullScreenAuxiliary;
}
- (void)armOutsideClose:(BOOL)on {
    if (self.globalMon) { [NSEvent removeMonitor:self.globalMon]; self.globalMon = nil; }
    if (!on || self.pinnedTop) return;
    __weak AppDelegate *ws = self;
    self.globalMon = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown handler:^(NSEvent *ev) {
        if (ws.overscreen || ws.pinnedTop) return;
        [ws hidePanel];
    }];
}
- (void)ensurePoll:(NSTimeInterval)sec {
    // local: poll corto y estable. Antes MAX(sec,8) + reset en cada tune → el timer NUNCA disparaba si Cambiabas <8s (UI≠Spotify).
    if (!self.useLocalSpotify && [self backoffLeft] > 0) {
        [self.pollTimer invalidate]; self.pollTimer = nil; return;
    }
    NSTimeInterval iv = self.useLocalSpotify ? 2.0 : MAX(sec, 20.0);
    if (self.pollTimer && fabs(self.pollTimer.timeInterval - iv) < 0.05) return; // no reiniciar (evita starvation)
    [self.pollTimer invalidate];
    self.pollTimer = nil;
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:iv target:self selector:@selector(poll) userInfo:nil repeats:YES];
    self.pollTimer.tolerance = iv * 0.25;
}
- (void)setOverscreenMode:(BOOL)on {
    self.overscreen = on;
    [self.teardownTimer invalidate]; self.teardownTimer = nil;
    [self makeWeb];
    [self.panel setFrame:[self panelFrame] display:YES];
    [self applyPanelChrome];
    [self applyWindowLevel];
    [NSApp activateIgnoringOtherApps:YES];
    [self.panel makeKeyAndOrderFront:nil];
    [self.panel makeFirstResponder:self.web];
    self.item.button.highlighted = !on;
    [self send:@{@"t": @"over", @"on": @(on)}];
    [self armOutsideClose:!on && !self.pinnedTop];
    if ([self backoffLeft] <= 0) [self ensurePoll:on ? 25.0 : 20.0];
}
- (void)showPanel {
    self.overscreen = NO;
    [self.teardownTimer invalidate]; self.teardownTimer = nil;
    [self makeWeb];
    [self.panel setFrame:[self panelFrame] display:NO];
    [self applyPanelChrome];
    [NSApp activateIgnoringOtherApps:YES];
    [self applyWindowLevel];
    [self.panel makeKeyAndOrderFront:nil];
    [self.panel makeFirstResponder:self.web];
    self.item.button.highlighted = YES;
    if (!self.frameActivity)
        self.frameActivity = [[NSProcessInfo processInfo] beginActivityWithOptions:(NSActivityUserInitiatedAllowingIdleSystemSleep | NSActivityLatencyCritical) reason:@"Panel visible"];
    [self send:@{@"t": @"shown"}];
    [self send:@{@"t": @"over", @"on": @NO}];
    // Con canción en curso: poll corto para pillar el fin (~1.5s). 20s se come la ventana.
    if ([self backoffLeft] <= 0) [self ensurePoll:(self.awaitingEnd && self.onAirUri.length) ? 2.5 : 20.0];
    [self armOutsideClose:!self.pinnedTop];
}
- (void)hidePanel {
    if (self.overscreen || self.pinnedTop) return;
    [self armOutsideClose:NO];
    [self.pollTimer invalidate]; self.pollTimer = nil;
    if (self.panel.isVisible) { [self.panel orderOut:nil]; self.hiddenAt = [NSDate timeIntervalSinceReferenceDate]; }
    self.item.button.highlighted = NO;
    if (self.frameActivity) { [[NSProcessInfo processInfo] endActivity:self.frameActivity]; self.frameActivity = nil; }
    // Panel cerrado: igual hay que detectar fin de tema (antes 30s → nunca avanzaba).
    if (self.awaitingEnd && self.onAirUri.length) [self ensurePoll:3.0];
    if (!self.web || self.teardownTimer) return;
    [self send:@{@"t": @"hidden"}];
    __weak AppDelegate *ws = self;
    self.teardownTimer = [NSTimer scheduledTimerWithTimeInterval:300.0 repeats:NO block:^(NSTimer *t) {
        AppDelegate *me = ws; if (!me) return;
        me.teardownTimer = nil;
        if (!me.panel.isVisible && !me.overscreen) [me teardownWeb];
    }];
}
- (void)windowDidResignKey:(NSNotification *)n {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.overscreen || self.pinnedTop) return;
        // Spotify.app roba el foco al hacer open location / play → no cerrar el panel
        if (self.suppressResignHide || self.busy) return;
        if (!self.panel.isKeyWindow) [self hidePanel];
    });
}

#pragma mark - Spotify Web API (PKCE; all network calls run synchronously on self.q)
static NSString *const kRedirect = @"http://127.0.0.1:29501/callback";
static const uint16_t kPort = 29501;
static NSString *const kScopes = @"user-library-read playlist-read-private playlist-read-collaborative user-read-playback-state user-modify-playback-state user-read-currently-playing";

static NSString *B64URL(NSData *d) {
    NSString *s = [d base64EncodedStringWithOptions:0];
    s = [s stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    s = [s stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [s stringByReplacingOccurrencesOfString:@"=" withString:@""];
}
static NSString *RandStr(size_t n) { NSMutableData *d = [NSMutableData dataWithLength:n]; arc4random_buf(d.mutableBytes, n); return B64URL(d); }
static NSString *Enc(NSString *s) {
    static NSCharacterSet *cs; static dispatch_once_t o;
    dispatch_once(&o, ^{ cs = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"]; });
    return [s stringByAddingPercentEncodingWithAllowedCharacters:cs] ?: @"";
}
static NSData *Form(NSDictionary *d) {
    NSMutableArray *p = [NSMutableArray array];
    for (NSString *k in d) [p addObject:[NSString stringWithFormat:@"%@=%@", Enc(k), Enc(d[k])]];
    return [[p componentsJoinedByString:@"&"] dataUsingEncoding:NSUTF8StringEncoding];
}
static id J(id o, NSString *k) { return [o isKindOfClass:[NSDictionary class]] ? o[k] : nil; }
// NSNull de JSON no es nil: sin esto `track:null` bloquea el fallback a `item` (API Spotify 2026)
static id JOk(id o, NSString *k) { id v = J(o, k); return (v && v != [NSNull null]) ? v : nil; }
static NSString *JS(id o, NSString *k) { id v = JOk(o, k); return [v isKindOfClass:[NSString class]] ? v : nil; }

- (NSString *)dir {
    NSString *d = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Radio"];
    [[NSFileManager defaultManager] createDirectoryAtPath:d withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:nil];
    return d;
}
- (NSDictionary *)readJSON:(NSString *)name {
    NSData *d = [NSData dataWithContentsOfFile:[[self dir] stringByAppendingPathComponent:name]];
    id j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    return [j isKindOfClass:[NSDictionary class]] ? j : nil;
}
// private file: created 0600 from the start, written to a temp file and renamed into place
- (void)writePrivate:(NSString *)name obj:(NSDictionary *)o {
    NSString *p = [[self dir] stringByAppendingPathComponent:name];
    if (!o) { unlink(p.fileSystemRepresentation); return; }
    NSData *d = [NSJSONSerialization dataWithJSONObject:o options:NSJSONWritingPrettyPrinted error:nil];
    NSString *tmp = [p stringByAppendingString:@".tmp"];
    int fd = open(tmp.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) return;
    fchmod(fd, 0600);
    const char *b = d.bytes; size_t left = d.length;
    while (left) { ssize_t w = write(fd, b, left); if (w <= 0) break; b += w; left -= w; }
    close(fd);
    rename(tmp.fileSystemRepresentation, p.fileSystemRepresentation);
    chmod(p.fileSystemRepresentation, 0600);
}
- (void)loadAuth {
    self.clientId = JS([self readJSON:@"config.json"], @"client_id") ?: @"";
    NSDictionary *t = [self readJSON:@"tokens.json"];
    self.tokens = t ? [t mutableCopy] : nil;
    [self chmodPrivate];
}
- (void)chmodPrivate {
    for (NSString *n in @[@"config.json", @"tokens.json"]) chmod([[self dir] stringByAppendingPathComponent:n].fileSystemRepresentation, 0600);
}
- (BOOL)authed { return self.clientId.length && [JS(self.tokens, @"refresh_token") length]; }
- (NSDictionary *)setupMsg {
    NSMutableDictionary *o = [NSMutableDictionary dictionaryWithDictionary:@{@"t": @"init", @"redirect": kRedirect}];
    o[@"auth"] = @([self authed]);
    o[@"clientId"] = self.clientId ?: @"";
    o[@"cur"] = self.store[@"cur"] ?: @"liked";
    o[@"curName"] = self.store[@"curName"] ?: @"Liked Songs";
    o[@"radio"] = self.store[@"radio"] ?: @YES;
    o[@"waiting"] = @(self.listenFd > 0);
    o[@"dev"] = @{@"id": self.store[@"device"] ?: @"", @"name": self.store[@"deviceName"] ?: @"", @"type": self.store[@"deviceType"] ?: @""};
    o[@"arts"] = [self.arts copy] ?: @[];
    // Si hay Spotify.app, no reabrir el panel con el cartel de 429 (play local no lo necesita)
    if (self.useLocalSpotify) {
        o[@"quotaSec"] = @0;
    } else {
        o[@"quotaSec"] = @((int)ceil([self backoffLeft]));
        if ([self backoffLeft] > 0) {
            NSMutableArray *bits = [NSMutableArray array];
            if ([self.store[@"lastBackoffSrc"] isEqualToString:@"radiofy-default"])
                [bits addObject:[NSString stringWithFormat:@"sin Retry-After → default Radiofy %@s", self.store[@"lastBackoffWait"] ?: @120]];
            else if (self.store[@"lastRetryAfterRaw"])
                [bits addObject:[NSString stringWithFormat:@"Retry-After Spotify: %@ → armado %@s", self.store[@"lastRetryAfterRaw"], self.store[@"lastBackoffWait"] ?: @"?"]];
            if (bits.count) o[@"quotaMeta"] = [bits componentsJoinedByString:@" "];
        }
    }
    if ([self.store[@"last"] isKindOfClass:[NSDictionary class]]) o[@"last"] = self.store[@"last"];
    return o;
}
- (void)pushQuota {
    int sec = (int)ceil([self backoffLeft]);
    NSMutableDictionary *o = [NSMutableDictionary dictionaryWithDictionary:@{@"t": @"quota", @"sec": @(MAX(sec, 0))}];
    if (self.store[@"lastRetryAfterRaw"]) o[@"raw"] = self.store[@"lastRetryAfterRaw"];
    if (self.store[@"lastRetryAfterSec"]) o[@"parsed"] = self.store[@"lastRetryAfterSec"];
    if (self.store[@"lastBackoffWait"]) o[@"armed"] = self.store[@"lastBackoffWait"];
    if (self.store[@"lastBackoffSrc"]) o[@"src"] = self.store[@"lastBackoffSrc"];
    [self send:o];
}
- (void)rememberArt:(NSString *)u {
    if (![u isKindOfClass:[NSString class]] || !u.length || [self.arts containsObject:u]) return;
    [self.arts insertObject:u atIndex:0];
    while (self.arts.count > 40) [self.arts removeLastObject];
}
- (NSString *)primaryArtist:(NSString *)artist {
    if (!artist.length) return @"";
    return [[[artist componentsSeparatedByString:@","].firstObject stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] lowercaseString] ?: @"";
}
- (void)rememberPlayedArtist:(NSString *)akey {
    if (!akey.length) return;
    [self.recentArtists removeObject:akey];
    [self.recentArtists insertObject:akey atIndex:0];
    while (self.recentArtists.count > 28) [self.recentArtists removeLastObject];
}
- (void)rememberPlayedUri:(NSString *)uri {
    if (!uri.length) return;
    [self.recentUris removeObject:uri];
    [self.recentUris insertObject:uri atIndex:0];
    while (self.recentUris.count > 60) [self.recentUris removeLastObject];
}
- (void)persistPlayMemory {
    self.store[@"recentUris"] = [self.recentUris copy] ?: @[];
    self.store[@"recentArtists"] = [self.recentArtists copy] ?: @[];
    [self saveStore];
}
- (void)loadPlayMemory {
    NSArray *uris = self.store[@"recentUris"];
    if ([uris isKindOfClass:[NSArray class]]) {
        for (id u in uris) if ([u isKindOfClass:[NSString class]] && [u length] && ![self.recentUris containsObject:u]) [self.recentUris addObject:u];
        while (self.recentUris.count > 60) [self.recentUris removeLastObject];
    }
    NSArray *artists = self.store[@"recentArtists"];
    if ([artists isKindOfClass:[NSArray class]]) {
        for (id a in artists) if ([a isKindOfClass:[NSString class]] && [a length] && ![self.recentArtists containsObject:a]) [self.recentArtists addObject:a];
        while (self.recentArtists.count > 28) [self.recentArtists removeLastObject];
    }
}
- (BOOL)artistBlocked:(NSString *)akey {
    return akey.length && ([self.recentArtists containsObject:akey] || [akey isEqualToString:(self.onAirArtist ?: @"")]);
}
- (BOOL)uriBlocked:(NSString *)uri {
    if (!uri.length) return YES;
    if (self.onAirUri.length && [uri isEqualToString:self.onAirUri]) return YES;
    return [self.recentUris containsObject:uri];
}
// oEmbed público: carátula sin Web API (no gasta cuota /me)
- (NSString *)coverArtForTrackURI:(NSString *)uri timeout:(NSTimeInterval)timeoutSec {
    if (![uri isKindOfClass:[NSString class]] || !uri.length) return @"";
    NSString *enc = [uri stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]] ?: uri;
    NSString *url = [@"https://open.spotify.com/oembed?url=" stringByAppendingString:enc];
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    r.HTTPMethod = @"GET";
    r.timeoutInterval = MAX(1.5, MIN(8.0, timeoutSec > 0 ? timeoutSec : 3.0));
    [r setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    __block NSData *data = nil; __block NSHTTPURLResponse *res = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[self.session dataTaskWithRequest:r completionHandler:^(NSData *d, NSURLResponse *rr, NSError *e) {
        data = d; res = (NSHTTPURLResponse *)rr; dispatch_semaphore_signal(sem);
    }] resume];
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(r.timeoutInterval * NSEC_PER_SEC))) != 0) return @"";
    if (res.statusCode != 200 || !data.length) return @"";
    id j = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return JS(j, @"thumbnail_url") ?: @"";
}
- (NSString *)coverArtForTrackURI:(NSString *)uri {
    return [self coverArtForTrackURI:uri timeout:3.0];
}

// ---- HTTP ----
- (NSInteger)http:(NSString *)method url:(NSString *)url headers:(NSDictionary *)h body:(NSData *)body json:(id *)out resp:(NSHTTPURLResponse **)rp {
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    r.HTTPMethod = method; r.timeoutInterval = 12; r.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    for (NSString *k in h) [r setValue:h[k] forHTTPHeaderField:k];
    if (body) r.HTTPBody = body; else if (![method isEqualToString:@"GET"]) r.HTTPBody = [NSData data];
    __block NSData *data = nil; __block NSHTTPURLResponse *res = nil; __block NSError *err = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[self.session dataTaskWithRequest:r completionHandler:^(NSData *d, NSURLResponse *rr, NSError *e) {
        data = d; res = (NSHTTPURLResponse *)rr; err = e; dispatch_semaphore_signal(sem);
    }] resume];
    // Nunca FOREVER: si el callback no llega, Cambiar deja la bolita girando eterno
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC))) != 0) {
        if (rp) *rp = nil;
        return -1;
    }
    if (rp) *rp = res;
    if (err || !res) return -1;
    if (out) *out = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return res.statusCode;
}
- (BOOL)tokenRequest:(NSDictionary *)form {
    id j = nil;
    NSInteger s = [self http:@"POST" url:@"https://accounts.spotify.com/api/token" headers:@{@"Content-Type": @"application/x-www-form-urlencoded"} body:Form(form) json:&j resp:NULL];
    if (s == 200 && JS(j, @"access_token")) {
        NSMutableDictionary *t = self.tokens ? [self.tokens mutableCopy] : [NSMutableDictionary dictionary];
        t[@"access_token"] = JS(j, @"access_token");
        if (JS(j, @"refresh_token")) t[@"refresh_token"] = JS(j, @"refresh_token");
        t[@"expires_at"] = @([[NSDate date] timeIntervalSince1970] + [J(j, @"expires_in") doubleValue]);
        if (JS(j, @"scope")) t[@"scope"] = JS(j, @"scope");
        self.tokens = t;
        [self writePrivate:@"tokens.json" obj:t];
        return YES;
    }
    if (s == 400 || s == 401) self.lastAuthErr = JS(j, @"error_description") ?: JS(j, @"error") ?: @"invalid";
    else self.lastAuthErr = nil;
    return NO;
}
- (BOOL)refresh {
    NSString *rt = JS(self.tokens, @"refresh_token");
    if (!rt.length || !self.clientId.length) return NO;
    if ([self tokenRequest:@{@"grant_type": @"refresh_token", @"refresh_token": rt, @"client_id": self.clientId}]) return YES;
    if (self.lastAuthErr) [self logoutWithMsg:@"La sesión de Spotify expiró. Vuelve a conectar."];
    return NO;
}
- (BOOL)ensureToken {
    if (![self authed]) return NO;
    if (!JS(self.tokens, @"access_token") || [J(self.tokens, @"expires_at") doubleValue] - [[NSDate date] timeIntervalSince1970] < 60) return [self refresh];
    return YES;
}
- (void)logoutWithMsg:(NSString *)msg {
    self.tokens = nil; self.webWaitId++;
    [self writePrivate:@"tokens.json" obj:nil];
    self.totals = [NSMutableDictionary dictionary]; self.recent = [NSMutableDictionary dictionary];
    self.recentUris = [NSMutableArray array]; self.playlists = nil; self.meId = nil;
    self.recentArtists = [NSMutableArray array]; self.onAirUri = nil; self.onAirArtist = nil; self.awaitingEnd = NO;
    [self clearTrackPool];
    [self persistPlayMemory];
    [self send:[self setupMsg]];
    if (msg) [self send:@{@"t": @"err", @"msg": msg}];
}
- (NSTimeInterval)backoffLeft {
    return MAX(0, self.backoffUntil - [NSDate timeIntervalSinceReferenceDate]);
}
- (void)persistBackoff {
    NSTimeInterval left = [self backoffLeft];
    if (left <= 0) {
        [self.store removeObjectForKey:@"backoffUntilEpoch"];
    } else {
        self.store[@"backoffUntilEpoch"] = @([[NSDate date] timeIntervalSince1970] + left);
    }
    [self saveStore];
}
- (void)armBackoffSeconds:(NSTimeInterval)sec rawHeader:(NSString *)raw {
    // Transparencia: sin tope teatral de 900s (eso hacía parecer siempre “15:00”).
    // Spotify manda X → esperamos X (máx 1h por sanidad). Sin header → default 120s y se declara.
    NSTimeInterval wait;
    NSString *src;
    if (sec > 0) {
        wait = MIN(sec, 3600);
        src = @"spotify";
    } else {
        wait = 120;
        src = @"radiofy-default";
    }
    self.store[@"lastRetryAfterRaw"] = raw.length ? raw : @"(sin header)";
    self.store[@"lastRetryAfterSec"] = @(sec);
    self.store[@"lastBackoffWait"] = @(wait);
    self.store[@"lastBackoffSrc"] = src;
    NSTimeInterval until = [NSDate timeIntervalSinceReferenceDate] + wait;
    if (until > self.backoffUntil) self.backoffUntil = until;
    [self persistBackoff];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.pollTimer invalidate];
        self.pollTimer = nil;
        // local poll (AppleScript) puede seguir aunque la Web API esté castigada
        if (self.useLocalSpotify) [self ensurePoll:8.0];
    });
    // Con Spotify.app el cartel 429 solo estorba; el backoff igual queda para no martillar la API
    if (!self.useLocalSpotify) [self pushQuota];
    else [self send:@{@"t": @"quota", @"sec": @0, @"clear": @YES}];
}
// Cero requests si hay cuota. Sin acortar. Sin “un PUT no cuenta”.
- (BOOL)waitForQuotaOrAbort {
    NSTimeInterval left = [self backoffLeft];
    if (left <= 0) {
        BOOL had = self.backoffUntil > 0 || self.store[@"backoffUntilEpoch"] != nil;
        self.backoffUntil = 0;
        if (self.store[@"backoffUntilEpoch"]) { [self.store removeObjectForKey:@"backoffUntilEpoch"]; [self saveStore]; }
        if (had && !self.useLocalSpotify) [self pushQuota];
        return YES;
    }
    return NO;
}
- (NSString *)backoffHuman {
    int sec = (int)ceil([self backoffLeft]);
    if (sec < 1) sec = 1;
    if (sec >= 60) return [NSString stringWithFormat:@"%d:%02d", sec / 60, sec % 60];
    return [NSString stringWithFormat:@"%d s", sec];
}
- (void)note429 {
    // Spotify.app: Cambiar puede ir por AppleScript; no tapar la UI con el cartel de 1h
    if (self.useLocalSpotify) return;
    [self pushQuota];
}
// API: durante backoff NADA sale (GET/PUT/POST). Un PUT en plena cuota empeoró el ban.
- (NSInteger)api:(NSString *)method path:(NSString *)path body:(id)b out:(id *)out {
    if ([self backoffLeft] > 0) return 429;
    if (![self ensureToken]) return 401;
    for (int i = 0; i < 2; i++) {
        NSMutableDictionary *h = [NSMutableDictionary dictionaryWithObject:[@"Bearer " stringByAppendingString:JS(self.tokens, @"access_token") ?: @""] forKey:@"Authorization"];
        NSData *body = nil;
        if (b) { body = [NSJSONSerialization dataWithJSONObject:b options:0 error:nil]; h[@"Content-Type"] = @"application/json"; }
        NSHTTPURLResponse *rp = nil; id j = nil;
        NSString *url = [path hasPrefix:@"https://"] ? path : [@"https://api.spotify.com/v1" stringByAppendingString:path];
        NSInteger s = [self http:method url:url headers:h body:body json:&j resp:&rp];
        if (s == 401 && i == 0) { if ([self refresh]) continue; return 401; }
        if (s == 429) {
            NSString *rah = rp ? [rp valueForHTTPHeaderField:@"Retry-After"] : nil;
            double ra = rah.length ? [rah doubleValue] : 0;
            [self armBackoffSeconds:ra rawHeader:rah ?: @""];
        }
        if (out) *out = j;
        return s;
    }
    return 401;
}
- (NSString *)msgFor:(NSInteger)s json:(id)j {
    NSString *reason = JS(J(j, @"error"), @"reason") ?: @"";
    NSString *m = JS(J(j, @"error"), @"message") ?: @"";
    if (s == 403 && ([reason isEqualToString:@"PREMIUM_REQUIRED"] || [m.lowercaseString containsString:@"premium"]))
        return @"Se requiere Spotify Premium para controlar la reproducción desde Radiofy.";
    if (s == 429) {
        return [NSString stringWithFormat:@"Spotify limitó requests. Espera ~%@.", [self backoffHuman]];
    }
    if (s == 401) return @"Conecta Radiofy con Spotify.";
    if (s == -1) return @"Sin conexión con Spotify.";
    if (s == 403) return m.length ? [@"Spotify rechazó la acción: " stringByAppendingString:m] : @"Spotify rechazó la acción.";
    return m.length ? m : [NSString stringWithFormat:@"Spotify respondió %ld.", (long)s];
}
- (void)fail:(NSInteger)s json:(id)j {
    if (s == 401 && ![self authed]) return;
    if (s == 429) { [self note429]; return; }
    [self send:@{@"t": @"err", @"msg": [self msgFor:s json:j], @"premium": @([[self msgFor:s json:j] containsString:@"Premium"])}];
}

// ---- login: loopback listener only while waiting for the browser ----
- (void)stopListener {
    int fd = self.listenFd;
    self.listenFd = 0;
    if (fd > 0) { shutdown(fd, SHUT_RDWR); close(fd); }
}
- (void)login {
    if (!self.clientId.length) { [self send:@{@"t": @"err", @"msg": @"Pega primero el Client ID."}]; return; }
    [self stopListener];
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a; memset(&a, 0, sizeof a);
    a.sin_len = sizeof a; a.sin_family = AF_INET; a.sin_port = htons(kPort); a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (fd < 0 || bind(fd, (struct sockaddr *)&a, sizeof a) < 0 || listen(fd, 4) < 0) {
        if (fd >= 0) close(fd);
        [self send:@{@"t": @"err", @"msg": @"El puerto 29501 está ocupado. Cierra lo que lo use e inténtalo de nuevo."}];
        return;
    }
    self.listenFd = fd;
    NSString *verifier = RandStr(48);
    unsigned char dg[CC_SHA256_DIGEST_LENGTH];
    NSData *vd = [verifier dataUsingEncoding:NSASCIIStringEncoding];
    CC_SHA256(vd.bytes, (CC_LONG)vd.length, dg);
    NSString *challenge = B64URL([NSData dataWithBytes:dg length:sizeof dg]);
    NSString *state = RandStr(16);
    NSString *cid = self.clientId;
    NSString *u = [NSString stringWithFormat:@"https://accounts.spotify.com/authorize?response_type=code&client_id=%@&redirect_uri=%@&code_challenge_method=S256&code_challenge=%@&scope=%@&state=%@",
                   Enc(cid), Enc(kRedirect), challenge, Enc(kScopes), state];
    [self send:@{@"t": @"wait", @"on": @YES}];
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:u]];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *code = nil, *err = nil;
        NSTimeInterval end = [NSDate timeIntervalSinceReferenceDate] + 600;
        while (self.listenFd == fd && !code && !err && [NSDate timeIntervalSinceReferenceDate] < end) {
            struct pollfd p = {fd, POLLIN, 0};
            if (poll(&p, 1, 1000) <= 0) continue;
            int c = accept(fd, NULL, NULL);
            if (c < 0) continue;
            struct timeval tv = {3, 0}; setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
            char buf[8192]; size_t n = 0;
            while (n < sizeof buf - 1) { ssize_t r = recv(c, buf + n, sizeof buf - 1 - n, 0); if (r <= 0) break; n += r; buf[n] = 0; if (strstr(buf, "\r\n\r\n")) break; }
            buf[n] = 0;
            NSString *req = [[NSString alloc] initWithBytes:buf length:n encoding:NSUTF8StringEncoding] ?: @"";
            NSArray *parts = [[req componentsSeparatedByString:@"\r\n"].firstObject componentsSeparatedByString:@" "];
            NSString *target = parts.count > 1 ? parts[1] : @"/";
            NSURLComponents *uc = [NSURLComponents componentsWithString:[@"http://127.0.0.1" stringByAppendingString:target]];
            BOOL cb = [uc.path isEqualToString:@"/callback"];
            NSString *body, *status = @"200 OK";
            if (cb) {
                NSString *gc = nil, *gs = nil, *ge = nil;
                for (NSURLQueryItem *qi in uc.queryItems) {
                    if ([qi.name isEqualToString:@"code"]) gc = qi.value;
                    else if ([qi.name isEqualToString:@"state"]) gs = qi.value;
                    else if ([qi.name isEqualToString:@"error"]) ge = qi.value;
                }
                if (![gs isEqualToString:state]) { err = @"state"; }
                else if (ge.length) { err = ge; }
                else if (gc.length) { code = gc; }
                else err = @"nocode";
                body = code ? @"Listo. Vuelve a Radio en la barra de menús; ya puedes cerrar esta pestaña." : @"No se completó la conexión. Vuelve a Radio e inténtalo de nuevo.";
            } else { status = @"404 Not Found"; body = @"Radio"; }
            NSString *html = [NSString stringWithFormat:@"<!doctype html><meta charset=utf-8><title>Radio</title><body style=\"font:15px -apple-system,sans-serif;background:#141629;color:#fff;display:grid;place-items:center;height:90vh\"><p>%@</p>", body];
            NSData *hd = [html dataUsingEncoding:NSUTF8StringEncoding];
            NSString *head = [NSString stringWithFormat:@"HTTP/1.1 %@\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: %lu\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n", status, (unsigned long)hd.length];
            NSMutableData *outd = [[head dataUsingEncoding:NSUTF8StringEncoding] mutableCopy]; [outd appendData:hd];
            send(c, outd.bytes, outd.length, 0);
            close(c);
        }
        BOOL mine = self.listenFd == fd;
        if (mine) [self stopListener];
        if (!mine) return;   // cancelled or superseded
        dispatch_async(self.q, ^{
            BOOL ok = NO;
            if (code) ok = [self tokenRequest:@{@"grant_type": @"authorization_code", @"code": code, @"redirect_uri": kRedirect, @"client_id": cid, @"code_verifier": verifier}];
            [self send:@{@"t": @"wait", @"on": @NO}];
            [self send:[self setupMsg]];
            if (ok) {
                [self send:@{@"t": @"authed"}];
                [self pushState];
                dispatch_async(dispatch_get_main_queue(), ^{ [NSApp activateIgnoringOtherApps:YES]; if (!self.panel.isVisible) [self showPanel]; });
            } else {
                NSString *m = !code && !err ? @"Tiempo agotado esperando a Spotify." :
                              [err isEqualToString:@"access_denied"] ? @"Cancelaste la autorización en Spotify." :
                              self.lastAuthErr ? [@"Spotify no aceptó la conexión: " stringByAppendingString:self.lastAuthErr] :
                              @"No se pudo completar la conexión con Spotify.";
                [self send:@{@"t": @"err", @"msg": m}];
            }
        });
    });
}
- (void)disconnect:(id)sender {
    [self stopListener];
    dispatch_async(self.q, ^{ [self logoutWithMsg:nil]; });
}
- (void)persistTrackPool {
    NSDictionary *o = @{
        @"src": self.poolSrc ?: @"",
        @"total": @(self.poolTotal),
        @"tracks": [self.trackPool copy] ?: @[]
    };
    NSData *d = [NSJSONSerialization dataWithJSONObject:o options:0 error:nil];
    if (d) [d writeToFile:[self poolPath] atomically:YES];
}
- (void)loadTrackPool {
    NSData *d = [NSData dataWithContentsOfFile:[self poolPath]];
    id j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    if (![j isKindOfClass:[NSDictionary class]]) return;
    NSString *src = JS(j, @"src");
    NSArray *tracks = JOk(j, @"tracks");
    if (![src isKindOfClass:[NSString class]] || !src.length || ![tracks isKindOfClass:[NSArray class]] || !tracks.count) return;
    NSString *cur = self.store[@"cur"] ?: @"liked";
    if (![src isEqualToString:cur]) return; // pool de otra fuente: no sirve
    [self.trackPool removeAllObjects];
    for (id t in tracks) if ([t isKindOfClass:[NSDictionary class]] && JS(t, @"uri")) [self.trackPool addObject:t];
    self.poolSrc = [src copy];
    self.poolTotal = [JOk(j, @"total") integerValue];
}
- (void)clearTrackPool {
    [self.trackPool removeAllObjects];
    self.poolSrc = nil;
    self.poolTotal = 0;
    [[NSFileManager defaultManager] removeItemAtPath:[self poolPath] error:nil];
}
- (void)clearSongCache {
    [self.recent removeAllObjects];
    [self.recentUris removeAllObjects];
    [self.recentArtists removeAllObjects];
    [self.totals removeAllObjects];
    [self.arts removeAllObjects];
    [self clearTrackPool];
    self.store[@"arts"] = @[];
    // NO tocar backoffUntil: limpiar memoria no debe romper la cuota de Spotify
    [self persistPlayMemory];
    [self saveStore];
    [self send:@{@"t": @"cacheCleared", @"arts": @[]}];
}
- (void)clearSongCache:(id)sender {
    dispatch_async(self.q, ^{ [self clearSongCache]; });
}
- (NSString *)appVersion {
    NSString *v = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"3.0";
    NSString *b = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"0";
    return [NSString stringWithFormat:@"%@-b%@", v, b];
}
- (void)persistPlaylistSeeds {
    NSString *path = [[self supportDir] stringByAppendingPathComponent:@"playlistSeeds.json"];
    NSData *d = [NSJSONSerialization dataWithJSONObject:self.playlistSeeds ?: @{} options:NSJSONWritingPrettyPrinted error:nil];
    if (d) [d writeToFile:path atomically:YES];
}
// DESACTIVADO (b25): quemaba cuota → 429 y Liked no abría. No llamar.
- (void)probePlaylistsInBackground:(NSArray *)items {
    (void)items;
}
// Solo reactivar el frente anterior. NUNCA hide de Spotify → eso es el flash abre/cierra.
- (void)beginSpotifyASQuiet {
    if (self.spotifyASQuietDepth == 0) {
        NSRunningApplication *front = [[NSWorkspace sharedWorkspace] frontmostApplication];
        self.frontBeforeSpotifyAS = front;
        self.spotifyWasFrontBeforeAS = [front.bundleIdentifier isEqualToString:@"com.spotify.client"];
    }
    self.spotifyASQuietDepth++;
}
- (void)endSpotifyASQuiet {
    if (self.spotifyASQuietDepth > 0) self.spotifyASQuietDepth--;
    if (self.spotifyASQuietDepth > 0) return;
    NSRunningApplication *front = self.frontBeforeSpotifyAS;
    self.frontBeforeSpotifyAS = nil;
    if (self.spotifyWasFrontBeforeAS) return;
    if (front && !front.terminated && front.bundleIdentifier.length &&
        ![front.bundleIdentifier isEqualToString:@"com.spotify.client"]) {
        [front activateWithOptions:NSApplicationActivateIgnoringOtherApps];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{ [NSApp activateIgnoringOtherApps:YES]; });
    }
}
- (BOOL)apiPlayerNext {
    if (![self authed] || [self backoffLeft] > 0 || ![self ensureToken]) return NO;
    id j = nil;
    NSInteger s = [self api:@"POST" path:@"/me/player/next" body:nil out:&j];
    return (s == 204 || s == 200 || s == 202);
}
// Abre Liked o playlist por AS (sin Web API). Si el primer tema no suena, next.
- (NSDictionary *)openPlaylistContextAS:(NSString *)src fromStart:(BOOL)fromStart {
    if (!src.length) return nil;
    BOOL liked = [src isEqualToString:@"liked"];
    if (!liked) {
        if ([src rangeOfCharacterFromSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]].location != NSNotFound) return nil;
        if (src.length < 10) return nil;
    }
    if (![[NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.spotify.client"] count]) {
        [self ensureSpotifyRunningQuiet];
        [NSThread sleepForTimeInterval:0.5];
    }
    [self beginSpotifyASQuiet];
    NSString *pl = liked ? @"spotify:collection:tracks" : [NSString stringWithFormat:@"spotify:playlist:%@", src];
    NSMutableString *as = [NSMutableString stringWithString:
        @"tell application \"Spotify\"\n"
         "if not running then return \"\"\n"
         "try\nset shuffling to true\nend try\n"];
    [as appendFormat:@"play track \"%@\"\n delay 0.35\n", ASEscape(pl)];
    [as appendString:
        @"repeat 6 times\n"
         "try\nset u to spotify url of current track as string\non error\nset u to \"\"\nend try\n"
         "if u starts with \"spotify:track:\" then\n"
         "try\nplay\nend try\n"
         "delay 0.22\n"
         "if player state is playing then exit repeat\n"
         "end if\n"
         "next track\ndelay 0.12\n"
         "end repeat\n"];
    [as appendString:[self appleScriptAfterPlay:fromStart]];
    [as appendString:@"end tell"];
    NSDictionary *out = [self localTuneResultFromScript:[self runAppleScript:as timeoutSec:8.0]];
    if (![out[@"uri"] hasPrefix:@"spotify:track:"]) {
        NSDictionary *again = [self localSpotifyState];
        if ([again[@"id"] hasPrefix:@"spotify:track:"]) {
            out = @{@"uri": again[@"id"] ?: @"", @"name": again[@"name"] ?: @"", @"artist": again[@"artist"] ?: @"",
                    @"akey": [self primaryArtist:again[@"artist"]] ?: @"", @"art": again[@"art"] ?: @"",
                    @"dur": again[@"dur"] ?: @0, @"pos": again[@"pos"] ?: @0};
        }
    }
    [self endSpotifyASQuiet];
    return [out[@"uri"] hasPrefix:@"spotify:track:"] ? out : nil;
}
- (void)showAbout:(id)sender {
    [self send:@{@"t": @"about", @"ver": [self appVersion]}];
    dispatch_async(dispatch_get_main_queue(), ^{ [self showPanel]; });
}

// ---- Spotify.app local (AppleScript): play/seek/poll SIN Web API → no come cuota ----
static NSString *ASEscape(NSString *s) {
    if (!s) return @"";
    NSString *o = [s stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    o = [o stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    return [o stringByReplacingOccurrencesOfString:@"\r" withString:@""];
}
static double ASFloat(NSString *s) {
    if (!s.length) return 0;
    return [[s stringByReplacingOccurrencesOfString:@"," withString:@"."] doubleValue];
}
- (void)promptSpotifyAutomation {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self send:@{@"t": @"err", @"msg": @"macOS bloqueó el control de Spotify. En Ajustes → Privacidad → Automatización, activa Radiofy → Spotify y vuelve a Cambiar."}];
        NSURL *u = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"];
        if (u) [[NSWorkspace sharedWorkspace] openURL:u];
    });
}
// Spotify a veces no responde a Apple Events. Si esto corre en el main → "Not Responding".
// osascript en cola propia + timeout: el UI sigue vivo y podemos matar el proceso colgado.
- (NSString *)runAppleScript:(NSString *)src {
    return [self runAppleScript:src timeoutSec:8.0];
}
- (NSString *)runAppleScript:(NSString *)src timeoutSec:(NSTimeInterval)timeoutSec {
    if (!src.length) return nil;
    if ([NSThread isMainThread]) {
        // Nunca bloquear el main esperando a Spotify
        __block NSString *out = nil;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        dispatch_async(self.asQueue, ^{
            out = [self runAppleScript:src timeoutSec:timeoutSec];
            dispatch_semaphore_signal(sem);
        });
        if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC))) != 0)
            return nil;
        return out;
    }
    __block NSString *out = nil;
    dispatch_queue_t aq = self.asQueue ?: self.q;
    const char *cur = dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL);
    const char *asl = dispatch_queue_get_label(aq);
    if (cur && asl && strcmp(cur, asl) == 0) {
        out = [self executeOSAS:src timeoutSec:timeoutSec];
    } else {
        dispatch_sync(aq, ^{ out = [self executeOSAS:src timeoutSec:timeoutSec]; });
    }
    return out;
}
- (NSString *)executeOSAS:(NSString *)src timeoutSec:(NSTimeInterval)timeoutSec {
    NSString *dir = NSTemporaryDirectory() ?: @"/tmp";
    NSString *path = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"radiofy-%d.scpt.txt", getpid()]];
    NSError *we = nil;
    if (![src writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&we]) return nil;
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/osascript"];
    task.arguments = @[path];
    NSPipe *outPipe = [NSPipe pipe];
    NSPipe *errPipe = [NSPipe pipe];
    task.standardOutput = outPipe;
    task.standardError = errPipe;
    task.standardInput = [NSPipe pipe];
    NSError *le = nil;
    if (![task launchAndReturnError:&le]) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        return nil;
    }
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [task waitUntilExit];
        dispatch_semaphore_signal(sem);
    });
    NSTimeInterval lim = timeoutSec > 0.5 ? timeoutSec : 8.0;
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(lim * NSEC_PER_SEC))) != 0) {
        @try { [task terminate]; } @catch (__unused NSException *ex) {}
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        self.lastAppleScriptErr = @"Spotify no respondió a tiempo";
        return nil;
    }
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    NSData *od = [outPipe.fileHandleForReading readDataToEndOfFile];
    NSData *ed = [errPipe.fileHandleForReading readDataToEndOfFile];
    NSString *em = [[NSString alloc] initWithData:ed encoding:NSUTF8StringEncoding] ?: @"";
    em = [em stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (task.terminationStatus != 0) {
        self.lastAppleScriptErr = em.length ? em : @"AppleScript falló";
        if ([em.lowercaseString containsString:@"not authorized"] || [em.lowercaseString containsString:@"no autorizado"] ||
            [em.lowercaseString containsString:@"not allowed"] || [em.lowercaseString containsString:@"(-1743)"]) {
            self.appleEventsDenied = YES;
        }
        return nil;
    }
    self.appleEventsDenied = NO;
    self.lastAppleScriptErr = nil;
    NSString *out = [[NSString alloc] initWithData:od encoding:NSUTF8StringEncoding] ?: @"";
    return [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}
// Solo para cold-start / automatización. NO usar spotify:playlist: en Cambiar (abre ventana).
- (BOOL)openSpotifyURI:(NSString *)uri {
    if (!uri.length) return NO;
    NSURL *u = [NSURL URLWithString:uri];
    if (!u) return NO;
    return [[NSWorkspace sharedWorkspace] openURLs:@[u] withAppBundleIdentifier:@"com.spotify.client" options:NSWorkspaceLaunchWithoutActivation additionalEventParamDescriptor:nil launchIdentifiers:nil];
}
- (BOOL)ensureSpotifyRunningQuiet {
    if ([[NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.spotify.client"] count]) return YES;
    NSURL *appURL = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:@"com.spotify.client"];
    if (!appURL) return NO;
    if (@available(macOS 10.15, *)) {
        NSWorkspaceOpenConfiguration *cfg = [NSWorkspaceOpenConfiguration configuration];
        cfg.activates = NO;
        __block BOOL ok = NO;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [[NSWorkspace sharedWorkspace] openApplicationAtURL:appURL configuration:cfg completionHandler:^(__unused NSRunningApplication *app, NSError *err) {
            ok = (err == nil);
            dispatch_semaphore_signal(sem);
        }];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)));
        return ok || [[NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.spotify.client"] count] > 0;
    }
    return [[NSWorkspace sharedWorkspace] launchAppWithBundleIdentifier:@"com.spotify.client" options:NSWorkspaceLaunchWithoutActivation additionalEventParamDescriptor:nil launchIdentifier:nil];
}
- (BOOL)playLocalTrack:(NSString *)uri positionMs:(double)posMs {
    return [self playLocalTrack:uri positionMs:posMs contextSrc:nil];
}
// 3.0: Spotify.app primero (estilo b74). Web API solo fallback opcional.
- (BOOL)playApiTrack:(NSString *)uri positionMs:(double)posMs contextSrc:(NSString *)ctxSrc {
    if (!uri.length || ![uri hasPrefix:@"spotify:track:"]) return NO;
    if (![self authed] || [self backoffLeft] > 0) return NO;
    if (![self ensureToken]) return NO;
    NSMutableDictionary *body = [NSMutableDictionary dictionary];
    NSString *ctx = nil;
    if ([ctxSrc isEqualToString:@"liked"]) {
        if (!self.meId.length) return NO;
        ctx = [NSString stringWithFormat:@"spotify:user:%@:collection", self.meId];
    } else if (ctxSrc.length >= 10 && [ctxSrc rangeOfCharacterFromSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]].location == NSNotFound) {
        ctx = [NSString stringWithFormat:@"spotify:playlist:%@", ctxSrc];
    }
    if (ctx.length) {
        body[@"context_uri"] = ctx;
        body[@"offset"] = @{@"uri": uri};
    } else {
        body[@"uris"] = @[uri];
    }
    if (posMs > 0) body[@"position_ms"] = @((NSInteger)posMs);
    id j = nil;
    NSInteger s = [self api:@"PUT" path:@"/me/player/play" body:body out:&j];
    return (s == 204 || s == 200 || s == 202);
}
- (BOOL)seekApiMs:(long long)ms {
    if (![self authed] || [self backoffLeft] > 0) return NO;
    if (![self ensureToken]) return NO;
    id j = nil;
    NSInteger s = [self api:@"PUT" path:[NSString stringWithFormat:@"/me/player/seek?position_ms=%lld", MAX(0LL, ms)] body:nil out:&j];
    return (s == 204 || s == 200 || s == 202);
}
- (NSDictionary *)apiNowPlaying {
    if ([self backoffLeft] > 0 || ![self ensureToken]) return nil;
    id j = nil;
    NSInteger s = [self api:@"GET" path:@"/me/player/currently-playing?additional_types=track" body:nil out:&j];
    if (s != 200 || ![j isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *item = J(j, @"item");
    if (![item isKindOfClass:[NSDictionary class]]) return nil;
    // Local files → Spotify.app muestra “can't play this / import it”
    if ([JOk(item, @"is_local") boolValue]) return nil;
    NSString *uri = JS(item, @"uri");
    if ([uri hasPrefix:@"spotify:local:"]) return nil;
    NSString *tid = JS(item, @"id");
    if (!tid.length) return nil;
    if (![uri hasPrefix:@"spotify:track:"]) uri = [@"spotify:track:" stringByAppendingString:tid];
    NSMutableArray *arts = [NSMutableArray array];
    for (id a in J(item, @"artists")) if ([a isKindOfClass:[NSDictionary class]] && JS(a, @"name").length) [arts addObject:JS(a, @"name")];
    NSString *artist = [arts componentsJoinedByString:@", "];
    NSString *art = @"";
    NSArray *images = J(J(item, @"album"), @"images");
    if ([images isKindOfClass:[NSArray class]] && images.count) art = JS(images.firstObject, @"url") ?: @"";
    double dur = [J(item, @"duration_ms") doubleValue];
    double posMs = [J(j, @"progress_ms") doubleValue];
    return @{@"uri": uri, @"name": JS(item, @"name") ?: @"", @"artist": artist ?: @"",
             @"akey": [self primaryArtist:artist] ?: @"", @"art": art ?: @"",
             @"dur": @(dur), @"pos": @(posMs / 1000.0)};
}
// Reproduce un track streamable conocido (nunca offset por posición: cae en locales).
- (NSDictionary *)playApiPicked:(NSDictionary *)t src:(NSString *)src fromStart:(BOOL)fromStart {
    NSString *uri = t[@"uri"];
    if (![uri hasPrefix:@"spotify:track:"]) return nil;
    double durMs = [t[@"dur"] doubleValue];
    double posMs = fromStart ? 0 : ([self radioMidSecForDurationMs:durMs] * 1000.0);
    if (posMs < 1 && !fromStart) posMs = 30000;
    if (![self playApiTrack:uri positionMs:posMs contextSrc:src]) return nil;
    [NSThread sleepForTimeInterval:0.25];
    NSDictionary *live = [self apiNowPlaying];
    if ([live[@"uri"] hasPrefix:@"spotify:track:"]) {
        self.localCtxSrc = [src copy];
        return @{@"uri": live[@"uri"] ?: uri, @"name": live[@"name"] ?: (t[@"name"] ?: @""),
                 @"artist": live[@"artist"] ?: (t[@"artist"] ?: @""),
                 @"akey": live[@"akey"] ?: (t[@"akey"] ?: @""), @"art": live[@"art"] ?: (t[@"art"] ?: @""),
                 @"dur": live[@"dur"] ?: (t[@"dur"] ?: @0), @"pos": live[@"pos"] ?: @(posMs / 1000.0)};
    }
    // API OK pero Spotify aún no refleja: devolver el pick (streamable) para no caer a AS next
    self.localCtxSrc = [src copy];
    return @{@"uri": uri, @"name": t[@"name"] ?: @"", @"artist": t[@"artist"] ?: @"",
             @"akey": t[@"akey"] ?: @"", @"art": t[@"art"] ?: @"",
             @"dur": t[@"dur"] ?: @0, @"pos": @(posMs / 1000.0)};
}
- (NSDictionary *)playApiContext:(NSString *)src fromStart:(BOOL)fromStart {
    if ([self backoffLeft] > 0) return nil;
    if (!src.length) return nil;
    // Solo URI de track del pool (is_local ya filtrado). NUNCA position aleatoria:
    // en playlists con archivos locales Spotify.app abre el diálogo “can't play this”.
    NSInteger st = 0; id ej = nil;
    NSDictionary *picked = [self pickTrack:src status:&st json:&ej];
    if (!picked[@"uri"]) return nil;
    return [self playApiPicked:picked src:src fromStart:fromStart];
}
// Now-playing unificado (API o AppleScript). Nil si no hay track.
- (NSDictionary *)liveTrackNow {
    NSDictionary *live = [self apiNowPlaying];
    if ([live[@"uri"] hasPrefix:@"spotify:track:"]) return live;
    NSDictionary *as = [self localSpotifyState];
    if (![as[@"id"] hasPrefix:@"spotify:track:"]) return nil;
    return @{@"uri": as[@"id"] ?: @"", @"name": as[@"name"] ?: @"", @"artist": as[@"artist"] ?: @"",
             @"akey": [self primaryArtist:as[@"artist"]] ?: @"", @"art": as[@"art"] ?: @"",
             @"dur": as[@"dur"] ?: @0, @"pos": as[@"pos"] ?: @0};
}
// Espera canción distinta a prevUri (cambio de playlist/contexto). No seek aquí.
- (NSDictionary *)waitForTrackChangeFrom:(NSString *)prevUri attempts:(int)attempts interval:(NSTimeInterval)interval {
    int n = MAX(1, attempts);
    for (int i = 0; i < n; i++) {
        if (i > 0) [NSThread sleepForTimeInterval:MAX(0.12, interval)];
        NSDictionary *live = [self liveTrackNow];
        if (![live[@"uri"] hasPrefix:@"spotify:track:"]) continue;
        NSString *u = live[@"uri"] ?: @"";
        if (!prevUri.length || ![u isEqualToString:prevUri]) return live;
    }
    return nil; // sigue la anterior → no inventar metadata
}
// Abre playlist/liked por context_uri SIN GET /items (403 en playlists ajenas desde feb 2025).
// Connect → Spotify.app en background (mismo enfoque que spotify-cli / Alfred Mini Player).
- (NSDictionary *)playApiContextUriOnly:(NSString *)src fromStart:(BOOL)fromStart {
    if (!src.length || [self backoffLeft] > 0 || ![self ensureToken]) return nil;
    if ([src isEqualToString:@"liked"] && !self.meId.length) {
        id mj = nil;
        if ([self api:@"GET" path:@"/me" body:nil out:&mj] == 200) {
            self.meId = JS(mj, @"id");
            if (self.meId.length) self.store[@"meId"] = self.meId;
        }
        if (!self.meId.length) return nil;
    }
    NSString *ctx = nil;
    if ([src isEqualToString:@"liked"])
        ctx = [NSString stringWithFormat:@"spotify:user:%@:collection", self.meId];
    else if (src.length >= 10 && [src rangeOfCharacterFromSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]].location == NSNotFound)
        ctx = [NSString stringWithFormat:@"spotify:playlist:%@", src];
    if (!ctx.length) return nil;
    NSString *prevUri = self.onAirUri.length ? self.onAirUri : @"";
    if (!prevUri.length) {
        NSDictionary *before = [self liveTrackNow];
        if ([before[@"uri"] hasPrefix:@"spotify:track:"]) prevUri = before[@"uri"];
    }
    NSMutableDictionary *body = [@{@"context_uri": ctx} mutableCopy];
    if (!fromStart) body[@"offset"] = @{@"position": @(arc4random_uniform(40))};
    id j = nil;
    NSInteger s = [self api:@"PUT" path:@"/me/player/play" body:body out:&j];
    if (!(s == 204 || s == 200 || s == 202)) {
        [body removeObjectForKey:@"offset"];
        s = [self api:@"PUT" path:@"/me/player/play" body:body out:&j];
        if (!(s == 204 || s == 200 || s == 202)) return nil;
    }
    // Confirmar pista nueva ANTES de metadata/seek (evita tapa/texto viejos + peo).
    NSDictionary *live = [self waitForTrackChangeFrom:prevUri attempts:10 interval:0.28];
    NSString *uri = live[@"uri"] ?: @"";
    if (![uri hasPrefix:@"spotify:track:"]) return nil;
    NSString *art = live[@"art"] ?: @"";
    double dur = [live[@"dur"] doubleValue];
    // Solo calcular pos; un único seek en finishLocalTune cuando liveMatches.
    double posSec = fromStart ? 0 : [self radioMidSecForDurationMs:dur];
    self.localCtxSrc = [src copy];
    return @{@"uri": uri, @"name": live[@"name"] ?: @"", @"artist": live[@"artist"] ?: @"",
             @"akey": live[@"akey"] ?: ([self primaryArtist:live[@"artist"]] ?: @""),
             @"art": art ?: @"", @"dur": live[@"dur"] ?: @0,
             @"pos": @(fromStart ? 0 : posSec)};
}
// Spotify.app + contexto de playlist (b74). Sin `launch` AS (abre ventana).
- (BOOL)playLocalTrack:(NSString *)uri positionMs:(double)posMs contextSrc:(NSString *)ctxSrc {
    if (!uri.length || !self.useLocalSpotify) return NO;
    double sec = MAX(0, posMs / 1000.0);
    NSString *ctx = nil;
    if ([ctxSrc isEqualToString:@"liked"]) ctx = @"spotify:collection:tracks";
    else if (ctxSrc.length >= 10 && [ctxSrc rangeOfCharacterFromSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]].location == NSNotFound)
        ctx = [NSString stringWithFormat:@"spotify:playlist:%@", ctxSrc];
    if (![[NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.spotify.client"] count]) {
        [self ensureSpotifyRunningQuiet];
        [NSThread sleepForTimeInterval:0.5];
    }
    [self beginSpotifyASQuiet];
    NSMutableString *src = [NSMutableString stringWithString:
        @"tell application \"Spotify\"\n"
         "if not running then return \"off\"\n"];
    if (ctx.length) [src appendFormat:@"play track \"%@\" in context \"%@\"\n", ASEscape(uri), ASEscape(ctx)];
    else [src appendFormat:@"play track \"%@\"\n", ASEscape(uri)];
    [src appendFormat:@"delay %.2f\ntry\nplay\nend try\nset player position to %f\n", sec < 0.5 ? 0.45 : 0.25, sec];
    if (sec < 0.5) [src appendString:@"delay 0.12\nset player position to 0\n"];
    [src appendString:@"return \"ok\"\nend tell"];
    BOOL ok = [[self runAppleScript:src timeoutSec:5.0] isEqualToString:@"ok"];
    if (ok && ctxSrc.length) self.localCtxSrc = [ctxSrc copy];
    if (!ok) [self radioLog:@"playLocalTrack AS fail uri=%@", uri];
    [self endSpotifyASQuiet];
    return ok;
}
- (BOOL)seekLocalSec:(double)sec {
    if (!self.useLocalSpotify) return NO;
    NSString *src = [NSString stringWithFormat:
        @"tell application \"Spotify\"\n"
         "if not running then return \"off\"\n"
         "try\n"
         "set player position to %f\n"
         "if player state is paused then play\n"
         "return \"ok\"\n"
         "on error\nreturn \"err\"\nend try\n"
         "end tell", MAX(0, sec)];
    if ([[self runAppleScript:src timeoutSec:4.0] isEqualToString:@"ok"]) return YES;
    return [self seekApiMs:(long long)(MAX(0, sec) * 1000.0)];
}
- (NSDictionary *)localTuneResultFromScript:(NSString *)raw {
    if (!raw.length) return nil;
    NSArray *p = [raw componentsSeparatedByString:@"\t"];
    if (p.count < 5) return nil;
    NSString *art = p.count > 5 ? (p[5] ?: @"") : @"";
    if ([art isEqualToString:@"missing value"]) art = @"";
    return @{@"uri": p[2] ?: @"", @"name": p[0] ?: @"", @"artist": p[1] ?: @"",
             @"akey": [self primaryArtist:p[1]] ?: @"", @"art": art ?: @"",
             @"dur": @(ASFloat(p[3])), @"pos": @(ASFloat(p[4]))};
}
- (NSString *)appleScriptAfterPlay:(BOOL)fromStart {
    NSMutableString *as = [NSMutableString stringWithString:
        @"try\n"
         "set tname to name of current track as string\n"
         "set tart to artist of current track as string\n"
         "set turl to spotify url of current track as string\n"
         "set tdur to duration of current track\n"
         "set tpos to 0\n"
         "set tarturl to \"\"\n"
         "try\nset tarturl to artwork url of current track as string\non error\nset tarturl to \"\"\nend try\n"
         "if tdur > 20000 then\n"];
    if (fromStart) [as appendString:@"set player position to 0\nset tpos to 0\n"];
    else [as appendString:@"set tpos to (tdur / 1000.0) * (0.15 + 0.60 * (random number from 0 to 1))\nset player position to tpos\n"];
    [as appendString:@"end if\nreturn tname & \"\\t\" & tart & \"\\t\" & turl & \"\\t\" & (tdur as string) & \"\\t\" & (tpos as string) & \"\\t\" & tarturl\non error\nreturn \"\"\nend try\n"];
    return as;
}
// next + play; si no suena (local / sin derechos en CL / toast “can't play”), salta.
- (NSString *)appleScriptSkipUntilPlaying:(BOOL)fromStart leadingSkips:(int)skips {
    NSMutableString *as = [NSMutableString stringWithString:
        @"tell application \"Spotify\"\n"
         "if not running then return \"\"\n"
         "try\nset shuffling to true\nend try\n"];
    for (int i = 0; i < MAX(0, skips); i++) [as appendString:@"next track\ndelay 0.1\n"];
    [as appendString:
        @"repeat 8 times\n"
         "try\nset u to spotify url of current track as string\non error\nset u to \"\"\nend try\n"
         "if u starts with \"spotify:track:\" then\n"
         "try\nplay\nend try\n"
         "delay 0.2\n"
         "exit repeat\n"
         "end if\n"
         "next track\n"
         "delay 0.12\n"
         "end repeat\n"];
    [as appendString:[self appleScriptAfterPlay:fromStart]];
    [as appendString:@"end tell"];
    return as;
}
- (NSDictionary *)tuneViaSkipUntilPlaying:(BOOL)fromStart leadingSkips:(int)skips {
    [self beginSpotifyASQuiet];
    NSString *raw = [self runAppleScript:[self appleScriptSkipUntilPlaying:fromStart leadingSkips:skips] timeoutSec:8.0];
    NSDictionary *out = [self localTuneResultFromScript:raw];
    if (![out[@"uri"] hasPrefix:@"spotify:track:"]) {
        NSDictionary *again = [self localSpotifyState];
        NSString *aid = again[@"id"] ?: @"";
        // No exigir "playing": con temas lentos / hide AS a veces queda paused un instante.
        if ([aid hasPrefix:@"spotify:track:"]) {
            out = @{@"uri": aid, @"name": again[@"name"] ?: @"", @"artist": again[@"artist"] ?: @"",
                    @"akey": [self primaryArtist:again[@"artist"]] ?: @"", @"art": again[@"art"] ?: @"",
                    @"dur": again[@"dur"] ?: @0, @"pos": again[@"pos"] ?: @0};
        } else {
            out = nil;
        }
    }
    [self endSpotifyASQuiet];
    return out[@"uri"] ? out : nil;
}
// Play de un track del pool/primed → dict para finishLocalTune (o nil).
- (NSDictionary *)playPickedLocal:(NSDictionary *)picked src:(NSString *)src fromStart:(BOOL)fromStart {
    NSString *uri = picked[@"uri"];
    if (![uri hasPrefix:@"spotify:track:"] || [self.blockedUris containsObject:uri]) return nil;
    double durMs = [picked[@"dur"] doubleValue];
    double posMs = fromStart ? 0 : ([self radioMidSecForDurationMs:durMs] * 1000.0);
    if (!fromStart && posMs < 1) posMs = 30000;
    if (![self playLocalTrack:uri positionMs:posMs contextSrc:src]) {
        [self.blockedUris addObject:uri];
        return nil;
    }
    NSDictionary *again = [self localSpotifyState];
    NSString *aid = again[@"id"] ?: @"";
    self.localCtxSrc = [src copy];
    if ([aid hasPrefix:@"spotify:track:"]) {
        return @{@"uri": aid, @"name": again[@"name"] ?: (picked[@"name"] ?: @""),
                 @"artist": again[@"artist"] ?: (picked[@"artist"] ?: @""),
                 @"akey": [self primaryArtist:again[@"artist"]] ?: (picked[@"akey"] ?: @""),
                 @"art": again[@"art"] ?: (picked[@"art"] ?: @""),
                 @"dur": again[@"dur"] ?: (picked[@"dur"] ?: @0),
                 @"pos": again[@"pos"] ?: @(posMs / 1000.0)};
    }
    return @{@"uri": uri, @"name": picked[@"name"] ?: @"", @"artist": picked[@"artist"] ?: @"",
             @"akey": picked[@"akey"] ?: @"", @"art": picked[@"art"] ?: @"",
             @"dur": picked[@"dur"] ?: @0, @"pos": @(posMs / 1000.0)};
}
// Seed desde cache local de Spotify (sin Web API) para una playlist.
- (NSString *)seedTrackURIFromSpotifyCache:(NSString *)playlistId {
    if (!playlistId.length || [playlistId isEqualToString:@"liked"]) return nil;
    if ([playlistId rangeOfCharacterFromSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]].location != NSNotFound) return nil;
    NSString *usersRoot = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Spotify/PersistentCache/Users"];
    NSArray *users = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:usersRoot error:nil];
    NSData *marker = [[NSString stringWithFormat:@"pl#slc#'spotify:playlist:%@#", playlistId] dataUsingEncoding:NSUTF8StringEncoding];
    if (!marker) return nil;
    NSRegularExpression *tr = [NSRegularExpression regularExpressionWithPattern:@"(?:spotify:)?track:([A-Za-z0-9]{22})" options:0 error:nil];
    for (NSString *u in users) {
        if (![u hasSuffix:@"-user"]) continue;
        NSString *dir = [usersRoot stringByAppendingPathComponent:u];
        NSDirectoryEnumerator *en = [[NSFileManager defaultManager] enumeratorAtPath:dir];
        NSString *rel;
        while ((rel = [en nextObject])) {
            if (!([rel hasSuffix:@".ldb"] || [rel hasSuffix:@".log"])) continue;
            NSData *data = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:rel] options:NSDataReadingMappedIfSafe error:nil];
            if (data.length < marker.length + 30) continue;
            NSRange r = [data rangeOfData:marker options:0 range:NSMakeRange(0, data.length)];
            if (r.location == NSNotFound) continue;
            NSUInteger from = r.location + r.length;
            NSUInteger win = MIN(data.length - from, (NSUInteger)2500);
            NSString *txt = [[NSString alloc] initWithBytes:(const char *)data.bytes + from length:win encoding:NSASCIIStringEncoding];
            if (!txt) txt = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(from, win)] encoding:NSISOLatin1StringEncoding];
            if (!txt) continue;
            NSTextCheckingResult *m = [tr firstMatchInString:txt options:0 range:NSMakeRange(0, txt.length)];
            if (!m || m.numberOfRanges < 2) continue;
            NSString *tid = [txt substringWithRange:[m rangeAtIndex:1]];
            if (tid.length == 22) return [@"spotify:track:" stringByAppendingString:tid];
        }
    }
    return nil;
}
// Spotify.app: al cambiar fuente hay que abrir contexto; same-src → solo next×N.
- (NSString *)seedTrackURIForSrc:(NSString *)src sameContext:(BOOL)same {
    if (self.primedNext[@"uri"] && [self.primedNext[@"src"] isEqualToString:src]) return self.primedNext[@"uri"];
    if ([src isEqualToString:self.poolSrc]) {
        for (NSDictionary *t in self.trackPool) if ([t[@"uri"] hasPrefix:@"spotify:track:"]) return t[@"uri"];
    }
    NSString *cached = [self seedTrackURIFromSpotifyCache:src];
    if (cached.length) return cached;
    // Solo reutilizar on-air/last si seguimos en la misma fuente
    if (same) {
        if (self.onAirUri.length && [self.onAirUri hasPrefix:@"spotify:track:"]) return self.onAirUri;
        if ([self.store[@"last"] isKindOfClass:[NSDictionary class]]) {
            NSString *lid = self.store[@"last"][@"id"];
            if ([lid isKindOfClass:[NSString class]] && [lid hasPrefix:@"spotify:track:"]) return lid;
        }
        for (id u in self.recentUris) {
            if ([u isKindOfClass:[NSString class]] && [u hasPrefix:@"spotify:track:"]) return u;
        }
    }
    return nil;
}
- (NSDictionary *)playLocalContext:(NSString *)src fromStart:(BOOL)fromStart {
    if (!self.useLocalSpotify || !src.length) return nil;
    BOOL needOpen = !self.localCtxSrc.length || ![self.localCtxSrc isEqualToString:src];
    int skips = needOpen ? (fromStart ? 0 : (int)arc4random_uniform(2))
                         : (fromStart ? (int)arc4random_uniform(2) : (int)(1 + arc4random_uniform(2)));
    if (![src isEqualToString:@"liked"]) {
        if ([src rangeOfCharacterFromSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]].location != NSNotFound) return nil;
        if (src.length < 10) return nil;
    }
    [self radioLog:@"playLocalContext src=%@ needOpen=%d fromStart=%d", src, needOpen ? 1 : 0, fromStart ? 1 : 0];
    NSDictionary *out = nil;
    if (needOpen) {
        // pool/seed → AS (liked=collection, playlist=uri). Sin probe. Sin toast 403.
        NSInteger st = 0; id ej = nil;
        NSDictionary *picked = nil;
        if ([self backoffLeft] <= 0) picked = [self pickTrack:src status:&st json:&ej];
        NSString *seed = picked[@"uri"];
        if (![seed hasPrefix:@"spotify:track:"]) {
            NSDictionary *probed = self.playlistSeeds[src];
            if ([probed isKindOfClass:[NSDictionary class]] && [probed[@"seed"] isKindOfClass:[NSString class]])
                seed = probed[@"seed"];
        }
        if (![seed hasPrefix:@"spotify:track:"]) seed = [self seedTrackURIForSrc:src sameContext:NO];
        if ([seed hasPrefix:@"spotify:track:"] && ![self.blockedUris containsObject:seed]) {
            double posMs = fromStart ? 0 : 30000;
            if (picked[@"dur"] && !fromStart) {
                double mid = [self radioMidSecForDurationMs:[picked[@"dur"] doubleValue]] * 1000.0;
                if (mid > 1) posMs = mid;
            }
            if ([self playLocalTrack:seed positionMs:posMs contextSrc:src]) {
                NSDictionary *again = [self localSpotifyState];
                NSString *aid = again[@"id"] ?: @"";
                self.localCtxSrc = [src copy];
                [self radioLog:@"playLocalContext path=seed-open"];
                if ([aid hasPrefix:@"spotify:track:"]) {
                    return @{@"uri": aid, @"name": again[@"name"] ?: (picked[@"name"] ?: @""),
                             @"artist": again[@"artist"] ?: (picked[@"artist"] ?: @""),
                             @"akey": [self primaryArtist:again[@"artist"]] ?: (picked[@"akey"] ?: @""),
                             @"art": again[@"art"] ?: (picked[@"art"] ?: @""),
                             @"dur": again[@"dur"] ?: (picked[@"dur"] ?: @0),
                             @"pos": again[@"pos"] ?: @(posMs / 1000.0)};
                }
                return @{@"uri": seed, @"name": picked[@"name"] ?: @"", @"artist": picked[@"artist"] ?: @"",
                         @"akey": picked[@"akey"] ?: @"", @"art": picked[@"art"] ?: @"",
                         @"dur": picked[@"dur"] ?: @0, @"pos": @(posMs / 1000.0)};
            }
            [self.blockedUris addObject:seed];
        }
        out = [self openPlaylistContextAS:src fromStart:fromStart];
        if (out[@"uri"]) {
            self.localCtxSrc = [src copy];
            [self radioLog:@"playLocalContext path=as-open"];
            return out;
        }
        [self radioLog:@"playLocalContext FAIL open src=%@ pickSt=%ld", src, (long)st];
        self.lastAppleScriptErr = @"No pude sintonizar en Spotify.app. Revisa Automatización (Radiofy → Spotify).";
        return nil;
    }
    // Mismo contexto: AS next; si falla → pool URI (no dejar la playlist muerta en loop).
    out = [self tuneViaSkipUntilPlaying:fromStart leadingSkips:skips];
    if (out[@"uri"]) {
        self.localCtxSrc = [src copy];
        [self radioLog:@"playLocalContext path=as-same"];
        return out;
    }
    NSInteger st = 0; id ej = nil;
    for (int attempt = 0; attempt < 4; attempt++) {
        NSDictionary *picked = [self pickTrack:src status:&st json:&ej];
        out = [self playPickedLocal:picked src:src fromStart:fromStart];
        if (out[@"uri"]) {
            [self radioLog:@"playLocalContext path=pool-same"];
            return out;
        }
        if (!picked[@"uri"]) break;
    }
    out = [self openPlaylistContextAS:src fromStart:fromStart];
    if (out[@"uri"]) {
        self.localCtxSrc = [src copy];
        [self radioLog:@"playLocalContext path=as-reopen"];
        return out;
    }
    [self radioLog:@"playLocalContext FAIL same src=%@", src];
    return nil;
}
- (NSDictionary *)localSpotifyState {
    if (!self.useLocalSpotify) return nil;
    // Solo lectura. NUNCA restore/activate aquí: el poll lo llama cada ~2s y pelear el foco colgaba la UI.
    NSString *src =
        @"tell application \"Spotify\"\n"
         "if not running then return \"off\"\n"
         "set pst to player state as string\n"
         "if pst is \"stopped\" then return \"stopped\"\n"
         "try\n"
         "set tname to name of current track as string\n"
         "set tart to artist of current track as string\n"
         "set turl to spotify url of current track as string\n"
         "set tdur to duration of current track\n"
         "set tpos to player position\n"
         "set tarturl to \"\"\n"
         "try\nset tarturl to artwork url of current track as string\non error\nset tarturl to \"\"\nend try\n"
         "return pst & \"\\t\" & tname & \"\\t\" & tart & \"\\t\" & turl & \"\\t\" & (tdur as string) & \"\\t\" & (tpos as string) & \"\\t\" & tarturl\n"
         "on error\nreturn pst\nend try\n"
         "end tell";
    // Poll frecuente: timeout corto para no acumular osascript si Spotify se traba
    NSString *raw = [self runAppleScript:src timeoutSec:2.5];
    if (!raw.length || [raw isEqualToString:@"off"]) return @{@"sp": @"off"};
    if ([raw isEqualToString:@"stopped"]) return @{@"sp": @"on", @"empty": @YES};
    NSArray *p = [raw componentsSeparatedByString:@"\t"];
    if (p.count < 6) return @{@"sp": @"on", @"empty": @YES};
    double durMs = ASFloat(p[4]);
    double posSec = ASFloat(p[5]);
    NSString *art = p.count > 6 ? (p[6] ?: @"") : @"";
    if ([art isEqualToString:@"missing value"]) art = @"";
    BOOL playing = [p[0] isEqualToString:@"playing"];
    NSDictionary *dev = @{@"id": @"local", @"name": @"Spotify en este Mac", @"type": @"Computer", @"active": @YES, @"restricted": @NO};
    return @{@"sp": @"on", @"id": p[3] ?: @"", @"name": p[1] ?: @"", @"artist": p[2] ?: @"", @"art": art ?: @"",
             @"dur": @(durMs), @"pos": @(posSec), @"st": playing ? @"playing" : @"paused", @"dev": dev};
}
- (NSDictionary *)localDeviceInfo {
    return @{@"id": @"local", @"name": @"Spotify en este Mac", @"type": @"Computer", @"active": @YES, @"restricted": @NO};
}

// ---- now playing ----
- (void)poll {
    if (self.busy || ![self authed]) return;
    if (self.polling) return;
    self.polling = YES;
    dispatch_async(self.q, ^{ [self pushState]; self.polling = NO; });
}
- (void)pushState {
    if (![self authed]) return;
    if (self.busy) return;
    // Modo local: cero GET /me/player
    if (self.useLocalSpotify) {
        NSDictionary *loc = [self localSpotifyState];
        if (!loc || [loc[@"sp"] isEqualToString:@"off"]) {
            [self send:@{@"t": @"state", @"sp": @"on", @"dev": [self localDeviceInfo]}];
            return;
        }
        if ([loc[@"empty"] boolValue]) {
            if (self.awaitingEnd && self.onAirUri.length && !self.busy) { [self advanceRadio]; return; }
            [self send:@{@"t": @"state", @"sp": @"on", @"dev": [self localDeviceInfo]}];
            return;
        }
        NSString *uri = loc[@"id"] ?: @"";
        NSString *artist = loc[@"artist"] ?: @"";
        double durMs = [loc[@"dur"] doubleValue];
        double posSec = [loc[@"pos"] doubleValue];
        NSString *prev = self.onAirUri ?: @"";
        if (self.awaitingEnd && prev.length && !self.busy) {
            if ([uri isEqualToString:prev] && durMs > 0 && posSec * 1000 >= durMs - 1500) { [self advanceRadio]; return; }
        }
        // URI distinta: en gracia post-tune (playlist asienta) → adoptar UI. Si no, ignorar (evita salto A→B).
        if (uri.length && prev.length && ![uri isEqualToString:prev]) {
            NSTimeInterval age = [NSDate timeIntervalSinceReferenceDate] - self.lastTuneAt;
            BOOL settle = self.awaitingEnd && age >= 0 && age < 10.0;
            if (!settle) return;
            self.onAirUri = uri;
            self.onAirArtist = [self primaryArtist:artist];
            NSString *art = loc[@"art"] ?: @"";
            if (art.length) [self rememberArt:art];
            NSMutableDictionary *st = [loc mutableCopy];
            st[@"t"] = @"state";
            if (art.length) st[@"art"] = art;
            else [st removeObjectForKey:@"art"];
            self.store[@"last"] = @{@"id": uri, @"name": st[@"name"] ?: @"", @"artist": artist, @"art": art ?: @"",
                                    @"dur": st[@"dur"] ?: @0, @"pos": st[@"pos"] ?: @0, @"st": st[@"st"] ?: @"paused"};
            [self send:st];
            if (!art.length) {
                NSString *uriCopy = [uri copy];
                dispatch_async(self.q, ^{
                    NSString *a = [self coverArtForTrackURI:uriCopy timeout:3.0] ?: @"";
                    if (!a.length || ![uriCopy isEqualToString:self.onAirUri]) return;
                    [self rememberArt:a];
                    [self send:@{@"t": @"art", @"uri": uriCopy, @"art": a}];
                });
            }
            return;
        }
        if (uri.length && !prev.length) {
            self.onAirUri = uri;
            self.onAirArtist = [self primaryArtist:artist];
        }
        NSString *art = loc[@"art"] ?: @"";
        if (!art.length && [self.store[@"last"] isKindOfClass:[NSDictionary class]] && [self.store[@"last"][@"id"] isEqualToString:uri])
            art = self.store[@"last"][@"art"] ?: @"";
        if (art.length) [self rememberArt:art];
        NSMutableDictionary *st = [loc mutableCopy];
        st[@"t"] = @"state";
        if (art.length) st[@"art"] = art;
        self.store[@"last"] = @{@"id": uri, @"name": st[@"name"] ?: @"", @"artist": artist, @"art": art ?: @"",
                                @"dur": st[@"dur"] ?: @0, @"pos": st[@"pos"] ?: @0, @"st": st[@"st"] ?: @"paused"};
        [self send:st];
        return;
    }
    if ([NSDate timeIntervalSinceReferenceDate] < self.backoffUntil) return;
    id j = nil;
    NSInteger s = [self api:@"GET" path:@"/me/player?additional_types=track,episode" body:nil out:&j];
    NSDictionary *dv = [self devInfo:J(j, @"device")];
    if (s == 204 || (s == 200 && !J(j, @"item"))) {
        if (self.awaitingEnd && self.onAirUri.length && !self.busy) { [self advanceRadio]; return; }
        [self send:dv ? @{@"t": @"state", @"sp": @"on", @"dev": dv} : @{@"t": @"state", @"sp": @"on"}];
        return;
    }
    if (s != 200) { if (s != 429 && s != 401) [self send:@{@"t": @"state", @"sp": @"err", @"msg": [self msgFor:s json:j]}]; return; }
    id it = JOk(j, @"item");
    NSString *artist = @"";
    id ars = JOk(it, @"artists");
    if ([ars isKindOfClass:[NSArray class]]) { NSMutableArray *n = [NSMutableArray array]; for (id x in ars) if (JS(x, @"name")) [n addObject:JS(x, @"name")]; artist = [n componentsJoinedByString:@", "]; }
    else if (JS(JOk(it, @"show"), @"name")) artist = JS(JOk(it, @"show"), @"name");
    id imgs = JOk(JOk(it, @"album"), @"images") ?: JOk(it, @"images");
    NSString *art = @"";
    if ([imgs isKindOfClass:[NSArray class]] && [imgs count]) art = JS([imgs count] > 1 ? imgs[1] : imgs[0], @"url") ?: @"";
    NSString *uri = JS(it, @"uri") ?: JS(it, @"id") ?: @"";
    double durMs = [JOk(it, @"duration_ms") doubleValue];
    double posMs = [JOk(j, @"progress_ms") doubleValue];
    BOOL playing = [JOk(j, @"is_playing") boolValue];
    if (self.awaitingEnd && self.onAirUri.length && !self.busy) {
        if ([uri isEqualToString:self.onAirUri] && durMs > 0 && posMs >= durMs - 1500) { [self advanceRadio]; return; }
        if (uri.length && ![uri isEqualToString:self.onAirUri]) {
            NSTimeInterval age = [NSDate timeIntervalSinceReferenceDate] - self.lastTuneAt;
            if (!(age >= 0 && age < 10.0)) return;
            self.onAirUri = uri;
            self.onAirArtist = [self primaryArtist:artist];
        }
    } else if (self.onAirUri.length && uri.length && ![uri isEqualToString:self.onAirUri]) {
        return;
    }
    NSDictionary *st = @{@"t": @"state", @"sp": @"on", @"id": uri, @"name": JS(it, @"name") ?: @"", @"artist": artist, @"art": art,
                         @"dur": JOk(it, @"duration_ms") ?: @0, @"pos": @(posMs / 1000.0),
                         @"st": playing ? @"playing" : @"paused", @"dev": dv ?: [NSNull null]};
    self.store[@"last"] = @{@"id": uri, @"name": st[@"name"], @"artist": artist, @"art": art, @"dur": st[@"dur"], @"pos": st[@"pos"], @"st": st[@"st"]};
    [self rememberArt:art];
    [self send:st];
}
- (NSDictionary *)devInfo:(id)d {
    if (!JS(d, @"id") && !JS(d, @"name")) return nil;
    return @{@"id": JS(d, @"id") ?: @"", @"name": JS(d, @"name") ?: @"Dispositivo", @"type": JS(d, @"type") ?: @"", @"active": @([J(d, @"is_active") boolValue]),
             @"restricted": @([J(d, @"is_restricted") boolValue])};
}
- (void)rememberDevice:(NSString *)i name:(NSString *)n type:(NSString *)t {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.store[@"device"] = i ?: @""; self.store[@"deviceName"] = n ?: @""; self.store[@"deviceType"] = t ?: @"";
        [self saveStore];
    });
}
- (NSInteger)transferTo:(NSString *)i json:(id *)j {
    return [self api:@"PUT" path:@"/me/player" body:@{@"device_ids": @[i], @"play": @YES} out:j];
}
// "Escuchar en este Mac": open the web player and wait (every 2 s, max 60 s) for its device to show up, then transfer to it.
- (void)listenHere {
    NSInteger token = ++self.webWaitId;
    [self send:@{@"t": @"webwait", @"on": @YES}];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://open.spotify.com/"]];
    });
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        for (int i = 0; i < 30; i++) {
            [NSThread sleepForTimeInterval:2.0];
            if (token != self.webWaitId || ![self authed]) return;
            // async (no sync): evita deadlock si q está en osascript
            __block BOOL done = NO;
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            dispatch_async(self.q, ^{
                if (token != self.webWaitId) { done = YES; dispatch_semaphore_signal(sem); return; }
                id j = nil;
                if ([self api:@"GET" path:@"/me/player/devices" body:nil out:&j] != 200) { dispatch_semaphore_signal(sem); return; }
                for (id d in J(j, @"devices")) {
                    NSString *n = JS(d, @"name") ?: @"", *ty = JS(d, @"type") ?: @"";
                    if (!JS(d, @"id") || [J(d, @"is_restricted") boolValue] || [ty caseInsensitiveCompare:@"Computer"] != NSOrderedSame) continue;
                    if ([n rangeOfString:@"web player" options:NSCaseInsensitiveSearch].location == NSNotFound && [n rangeOfString:@"safari" options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
                    done = YES;
                    self.webWaitId++;
                    [self rememberDevice:JS(d, @"id") name:n type:ty];
                    id tj = nil;
                    NSInteger s = [self transferTo:JS(d, @"id") json:&tj];
                    [self send:@{@"t": @"webwait", @"on": @NO}];
                    if (s >= 200 && s < 300) [self send:@{@"t": @"note", @"msg": [@"Sonando en " stringByAppendingString:n]}];
                    else [self fail:s json:tj];
                    [NSThread sleepForTimeInterval:0.6];
                    [self pushState];
                    break;
                }
                dispatch_semaphore_signal(sem);
            });
            dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)));
            if (done) return;
        }
        if (token == self.webWaitId) {
            self.webWaitId++;
            [self send:@{@"t": @"webwait", @"on": @NO}];
            [self send:@{@"t": @"err", @"msg": @"No apareció el reproductor web. Abre open.spotify.com, inicia sesión y pulsa play una vez."}];
        }
    });
}

// ---- sources ----
- (void)rememberPlaylistId:(NSString *)pid name:(NSString *)name {
    if (![pid isKindOfClass:[NSString class]] || !pid.length || [pid isEqualToString:@"liked"]) return;
    if ([pid rangeOfCharacterFromSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]].location != NSNotFound) return;
    NSMutableArray *cache = [[self.store[@"playlistsCache"] isKindOfClass:[NSArray class]] ? self.store[@"playlistsCache"] : @[] mutableCopy];
    NSMutableArray *next = [NSMutableArray array];
    NSDictionary *prev = nil;
    for (id p in cache) {
        if ([p isKindOfClass:[NSDictionary class]] && [JS(p, @"id") isEqualToString:pid]) { prev = p; break; }
    }
    NSMutableDictionary *head = [@{@"id": pid, @"name": name.length ? name : @"Playlist", @"own": @YES} mutableCopy];
    if (prev[@"n"] != nil) head[@"n"] = prev[@"n"];
    else head[@"n"] = @0;
    if (JS(prev, @"art").length) head[@"art"] = JS(prev, @"art");
    if (prev[@"mine"] != nil) head[@"mine"] = prev[@"mine"];
    [next addObject:head];
    for (id p in cache) {
        if (![p isKindOfClass:[NSDictionary class]] || !JS(p, @"id")) continue;
        if ([JS(p, @"id") isEqualToString:pid]) continue;
        [next addObject:p];
    }
    while (next.count > 1000) [next removeLastObject];
    self.store[@"playlistsCache"] = next;
    self.playlists = next;
    self.playlistsAt = [NSDate timeIntervalSinceReferenceDate];
    [self saveStore];
}
- (NSArray *)playlistMenuItems {
    NSArray *cached = self.playlists;
    if (!cached.count && [self.store[@"playlistsCache"] isKindOfClass:[NSArray class]]) cached = self.store[@"playlistsCache"];
    NSString *cur = self.store[@"cur"] ?: @"";
    NSString *curName = self.store[@"curName"] ?: @"Playlist";
    if (cur.length && ![cur isEqualToString:@"liked"]) {
        BOOL found = NO;
        for (id p in cached) if ([JS(p, @"id") isEqualToString:cur]) { found = YES; break; }
        if (!found) {
            NSMutableArray *m = [cached mutableCopy] ?: [NSMutableArray array];
            [m insertObject:@{@"id": cur, @"name": curName, @"n": @0, @"own": @YES} atIndex:0];
            cached = m;
        }
    }
    return cached ?: @[];
}
// Cache local de Spotify.app (leveldb) cuando la Web API está en 429/QUOTA.
- (NSArray *)playlistsFromSpotifyCache {
    NSString *usersRoot = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Spotify/PersistentCache/Users"];
    NSArray *users = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:usersRoot error:nil];
    NSMutableDictionary *byId = [NSMutableDictionary dictionary];
    NSData *marker = [@"pl#slc#'spotify:playlist:" dataUsingEncoding:NSUTF8StringEncoding];
    NSCharacterSet *alnum = [NSCharacterSet alphanumericCharacterSet];
    NSArray *noise = @[@"reporting.uri", @"request_id", @"auto", @"track", @"album", @"playlist", @"local"];
    for (NSString *u in users) {
        if (![u hasSuffix:@"-user"]) continue;
        NSString *dir = [usersRoot stringByAppendingPathComponent:u];
        NSDirectoryEnumerator *en = [[NSFileManager defaultManager] enumeratorAtPath:dir];
        NSString *rel;
        while ((rel = [en nextObject])) {
            if (!([rel hasSuffix:@".ldb"] || [rel hasSuffix:@".log"])) continue;
            NSData *data = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:rel] options:NSDataReadingMappedIfSafe error:nil];
            if (data.length < 40) continue;
            const uint8_t *bytes = data.bytes;
            NSUInteger len = data.length;
            NSUInteger pos = 0;
            while (pos + marker.length + 22 < len) {
                NSRange r = [data rangeOfData:marker options:0 range:NSMakeRange(pos, len - pos)];
                if (r.location == NSNotFound) break;
                NSUInteger idAt = r.location + marker.length;
                if (idAt + 22 > len) break;
                BOOL okId = YES;
                for (NSUInteger i = 0; i < 22; i++) {
                    unichar c = bytes[idAt + i];
                    if (c > 127 || ![alnum characterIsMember:(char)c]) { okId = NO; break; }
                }
                pos = idAt + 22;
                if (!okId) continue;
                NSString *pid = [[NSString alloc] initWithBytes:bytes + idAt length:22 encoding:NSASCIIStringEncoding];
                if (!pid.length) continue;
                NSUInteger winEnd = MIN(len, idAt + 22 + 420);
                NSString *name = nil;
                for (NSUInteger i = idAt + 22; i + 2 < winEnd; i++) {
                    if (bytes[i] != 0x0a) continue;
                    NSUInteger nlen = bytes[i + 1];
                    if (nlen < 2 || nlen >= 0x80 || i + 2 + nlen > winEnd) continue;
                    NSData *nd = [NSData dataWithBytes:bytes + i + 2 length:nlen];
                    NSString *s = [[NSString alloc] initWithData:nd encoding:NSUTF8StringEncoding];
                    if (!s.length || s.length > 120) continue;
                    if ([s hasPrefix:@"spotify:"]) continue;
                    BOOL printable = YES;
                    for (NSUInteger k = 0; k < s.length; k++) {
                        unichar c = [s characterAtIndex:k];
                        if (c < 32 && c != 9 && c != 10) { printable = NO; break; }
                    }
                    if (!printable) continue;
                    if ([noise containsObject:s]) continue;
                    NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
                    if ([[s stringByTrimmingCharactersInSet:digits] length] == 0) continue;
                    name = s;
                    break;
                }
                if (!name.length) continue;
                NSData *win = [data subdataWithRange:NSMakeRange(idAt, winEnd - idAt)];
                BOOL mine = self.meId.length && [win rangeOfData:[self.meId dataUsingEncoding:NSUTF8StringEncoding] options:0 range:NSMakeRange(0, win.length)].location != NSNotFound;
                NSDictionary *prev = byId[pid];
                if (!prev || (mine && ![prev[@"mine"] boolValue]) || (name.length > [JS(prev, @"name") length] && mine == [prev[@"mine"] boolValue])) {
                    byId[pid] = @{@"id": pid, @"name": name, @"n": @0, @"own": @YES, @"mine": @(mine), @"local": @YES};
                }
            }
        }
    }
    NSArray *all = [[byId allValues] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [JS(a, @"name") localizedCaseInsensitiveCompare:JS(b, @"name")];
    }];
    return all;
}
// Todas las páginas de /me/playlists (hasta 1000). Sin martillar 429.
- (NSArray *)fetchAllPlaylistsStatus:(NSInteger *)outStatus json:(id *)outJson {
    NSMutableArray *out = [NSMutableArray array];
    NSInteger offset = 0;
    const NSInteger limit = 50;
    const NSInteger maxPages = 20;
    id lastJ = nil;
    NSInteger lastS = 0;
    NSInteger expectedTotal = 0;
    for (int page = 0; page < maxPages; page++) {
        if ([self backoffLeft] > 0) { lastS = 429; break; }
        id j = nil;
        NSString *path = [NSString stringWithFormat:@"/me/playlists?limit=%ld&offset=%ld", (long)limit, (long)offset];
        NSInteger s = [self api:@"GET" path:path body:nil out:&j];
        lastS = s; lastJ = j;
        NSArray *items = (s == 200) ? J(j, @"items") : nil;
        NSInteger total = [JOk(j, @"total") integerValue];
        if (total > 0) expectedTotal = total;
        if (s != 200) break;
        if (![items isKindOfClass:[NSArray class]] || !items.count) break;
        for (id p in items) {
            if (![p isKindOfClass:[NSDictionary class]] || !JS(p, @"id")) continue;
            BOOL mine = !self.meId.length || [JS(JOk(p, @"owner"), @"id") isEqualToString:self.meId] || [JOk(p, @"collaborative") boolValue];
            // Web API reciente: items.total; legacy: tracks.total
            id bag = JOk(p, @"items") ?: JOk(p, @"tracks");
            NSNumber *cnt = @([JOk(bag, @"total") integerValue]);
            NSString *art = @"";
            id images = JOk(p, @"images");
            if ([images isKindOfClass:[NSArray class]] && [(NSArray *)images count]) {
                // Spotify: [0]=grande; último=chico (thumb)
                art = JS([(NSArray *)images lastObject], @"url") ?: JS([(NSArray *)images firstObject], @"url") ?: @"";
            }
            NSMutableDictionary *row = [@{@"id": JS(p, @"id"), @"name": JS(p, @"name") ?: @"Playlist", @"n": cnt, @"own": @YES, @"mine": @(mine)} mutableCopy];
            if (art.length) row[@"art"] = art;
            [out addObject:row];
        }
        offset += (NSInteger)items.count;
        // Evidencia: page1 trajo 47 (<50) con total=151 → no cortar; seguir hasta offset>=total
        if (expectedTotal > 0 && offset >= expectedTotal) { lastS = 200; break; }
        if (expectedTotal <= 0 && (NSInteger)items.count < limit) { lastS = 200; break; }
        [NSThread sleepForTimeInterval:0.15];
    }
    if (outStatus) *outStatus = lastS;
    if (outJson) *outJson = lastJ;
    return out;
}
- (void)applyPlaylistList:(NSArray *)out err:(NSString *)err {
    if (!out.count) return;
    self.playlists = out;
    self.playlistsAt = [NSDate timeIntervalSinceReferenceDate];
    self.store[@"playlistsCache"] = out;
    [self saveStore];
    NSMutableDictionary *msg = [@{@"t": @"playlists", @"items": out} mutableCopy];
    if (err.length) msg[@"err"] = err;
    [self send:msg];
}
- (void)loadPlaylists:(BOOL)force {
    if (self.loadingPlaylists) {
        NSArray *have = [self playlistMenuItems];
        if (have.count) [self send:@{@"t": @"playlists", @"items": have}];
        return;
    }
    if (!force && self.playlists.count > 1 && [NSDate timeIntervalSinceReferenceDate] - self.playlistsAt < 86400) {
        BOOL missingArt = NO;
        for (id p in self.playlists) {
            if (![p isKindOfClass:[NSDictionary class]]) continue;
            if (!JS(p, @"art").length) { missingArt = YES; break; }
        }
        if (!missingArt) { [self send:@{@"t": @"playlists", @"items": self.playlists}]; return; }
        // Cache viejo sin tapas → refetch
    }
    NSArray *cached = [self playlistMenuItems];
    if (cached.count) [self send:@{@"t": @"playlists", @"items": cached}];

    self.loadingPlaylists = YES;
    // Con cuota: NO pisar lista larga con cache local más corto (bug b24).
    if ([self backoffLeft] > 0) {
        NSArray *local = [self playlistsFromSpotifyCache];
        self.loadingPlaylists = NO;
        if (local.count > cached.count) {
            [self applyPlaylistList:local err:nil];
            return;
        }
        if (cached.count) {
            [self send:@{@"t": @"playlists", @"items": cached, @"err": [self msgFor:429 json:nil]}];
        } else if (local.count) {
            [self applyPlaylistList:local err:[self msgFor:429 json:nil]];
        } else {
            [self send:@{@"t": @"playlists", @"items": @[], @"err": [self msgFor:429 json:nil]}];
        }
        return;
    }

    if (!self.meId.length || !self.meCountry.length) {
        id mj = nil;
        if ([self api:@"GET" path:@"/me" body:nil out:&mj] == 200) {
            self.meId = JS(mj, @"id");
            self.meCountry = JS(mj, @"country");
            if (self.meId.length) self.store[@"meId"] = self.meId;
            if (self.meCountry.length) self.store[@"meCountry"] = self.meCountry;
            [self saveStore];
        }
    }
    NSInteger s = 0; id j = nil;
    NSArray *out = [self fetchAllPlaylistsStatus:&s json:&j];
    if (out.count) {
        self.loadingPlaylists = NO;
        // Si la API vino corta, completar con cache local de Spotify.app
        NSInteger apiTotal = [JOk(j, @"total") integerValue];
        if ((s != 200 || (apiTotal > 0 && (NSInteger)out.count < apiTotal)) ) {
            NSArray *local = [self playlistsFromSpotifyCache];
            if (local.count > out.count) {
                NSMutableDictionary *by = [NSMutableDictionary dictionary];
                for (NSDictionary *p in out) if (JS(p, @"id")) by[JS(p, @"id")] = p;
                for (NSDictionary *p in local) {
                    NSString *pid = JS(p, @"id");
                    if (pid.length && !by[pid]) by[pid] = p;
                }
                out = [[by allValues] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                    return [JS(a, @"name") localizedCaseInsensitiveCompare:JS(b, @"name")];
                }];
            }
        }
        if (s == 200) {
            [self.store removeObjectForKey:@"backoffUntilEpoch"];
            self.backoffUntil = 0;
        }
        [self applyPlaylistList:out err:(s != 200 ? [self msgFor:s json:j] : nil)];
        return;
    }
    NSArray *local = [self playlistsFromSpotifyCache];
    self.loadingPlaylists = NO;
    if (local.count > cached.count) {
        [self applyPlaylistList:local err:nil];
        return;
    }
    if (cached.count) {
        self.playlists = cached;
        [self send:@{@"t": @"playlists", @"items": cached, @"err": s ? [self msgFor:s json:j] : nil}];
    } else if (local.count) {
        [self applyPlaylistList:local err:nil];
    } else {
        [self send:@{@"t": @"playlists", @"items": @[], @"err": s ? [self msgFor:s json:j] : @"No pude cargar playlists."}];
    }
}
- (NSDictionary *)parseTrackItem:(id)it offset:(NSInteger)k {
    if (![it isKindOfClass:[NSDictionary class]]) return nil;
    id tr = JOk(it, @"track") ?: JOk(it, @"item") ?: ([JS(it, @"uri") hasPrefix:@"spotify:track:"] ? it : nil);
    NSString *uri = JS(tr, @"uri");
    if (![uri hasPrefix:@"spotify:track:"] || [JOk(tr, @"is_local") boolValue]) return nil;
    // Si la API marca no reproducible en el mercado, no meterlo al pool (evita el toast de Spotify).
    id playable = JOk(tr, @"is_playable");
    if ([playable isKindOfClass:[NSNumber class]] && ![playable boolValue]) return nil;
    NSString *artist = @"";
    id ars = JOk(tr, @"artists");
    if ([ars isKindOfClass:[NSArray class]]) {
        NSMutableArray *n = [NSMutableArray array];
        for (id x in ars) if (JS(x, @"name")) [n addObject:JS(x, @"name")];
        artist = [n componentsJoinedByString:@", "];
    }
    NSString *akey = [self primaryArtist:artist];
    id imgs = JOk(JOk(tr, @"album"), @"images");
    NSString *art = @"";
    if ([imgs isKindOfClass:[NSArray class]] && [imgs count]) art = JS([imgs count] > 1 ? imgs[1] : imgs[0], @"url") ?: @"";
    [self rememberArt:art];
    return @{@"uri": uri, @"dur": JOk(tr, @"duration_ms") ?: @0, @"name": JS(tr, @"name") ?: @"", @"artist": artist, @"akey": akey ?: @"", @"art": art ?: @"", @"off": @(k)};
}
// Pool en disco: Cambiar = sorteo local + 1 PUT. GET solo si el pool está vacío.
- (BOOL)refillTrackPool:(NSString *)src status:(NSInteger *)st json:(id *)ej {
    if ([self backoffLeft] > 0) { *st = 429; *ej = nil; return NO; }
    BOOL liked = [src isEqualToString:@"liked"];
    NSString *base = liked ? @"/me/tracks" : [NSString stringWithFormat:@"/playlists/%@/items", Enc(src)];
    // market → is_playable refleja derechos en Chile (u otro país de la cuenta)
    NSString *mkt = self.meCountry.length ? self.meCountry : (self.store[@"meCountry"] ?: @"CL");
    if (![mkt isKindOfClass:[NSString class]] || !mkt.length) mkt = @"CL";
    NSString *extra = liked
        ? [NSString stringWithFormat:@"&market=%@", mkt]
        : [NSString stringWithFormat:@"&additional_types=track&market=%@", mkt];
    const NSInteger pageSize = 50;
    NSInteger totalHint = self.poolTotal > 0 ? self.poolTotal : pageSize;
    for (int pageTry = 0; pageTry < 2; pageTry++) {
        NSInteger maxStart = MAX(0, totalHint - pageSize);
        NSInteger start = (pageTry == 0 && self.poolTotal <= 0) ? 0 : (maxStart > 0 ? (NSInteger)arc4random_uniform((uint32_t)(maxStart + 1)) : 0);
        id j = nil;
        NSInteger s = [self api:@"GET" path:[NSString stringWithFormat:@"%@?limit=%ld&offset=%ld%@", base, (long)pageSize, (long)start, extra] body:nil out:&j];
        if (s != 200) { *st = s; *ej = j; return NO; }
        NSInteger total = [JOk(j, @"total") integerValue];
        if (total > 0) {
            self.poolTotal = total;
            self.totals[src] = @{@"n": @(total), @"at": @([NSDate timeIntervalSinceReferenceDate])};
            totalHint = total;
        }
        id items = JOk(j, @"items");
        if (![items isKindOfClass:[NSArray class]] || ![items count]) {
            if (total <= 0) { *st = 0; return NO; }
            continue;
        }
        NSMutableSet *seen = [NSMutableSet set];
        for (NSDictionary *t in self.trackPool) if (t[@"uri"]) [seen addObject:t[@"uri"]];
        NSMutableArray *fresh = [NSMutableArray array];
        for (NSUInteger i = 0; i < [items count]; i++) {
            NSDictionary *t = [self parseTrackItem:items[i] offset:start + (NSInteger)i];
            if (!t || !t[@"uri"] || [seen containsObject:t[@"uri"]]) continue;
            [seen addObject:t[@"uri"]];
            [fresh addObject:t];
        }
        if (!fresh.count) continue;
        // merge hasta 150: más Cambiar sin volver a pedir lista
        [self.trackPool addObjectsFromArray:fresh];
        while (self.trackPool.count > 150) [self.trackPool removeObjectAtIndex:0];
        self.poolSrc = [src copy];
        [self persistTrackPool];
        return YES;
    }
    *st = 0;
    return self.trackPool.count > 0;
}
- (BOOL)ensureTrackPool:(NSString *)src status:(NSInteger *)st json:(id *)ej {
    if ([src isEqualToString:self.poolSrc] && self.trackPool.count >= 1) return YES;
    if ([self backoffLeft] > 0) { *st = 429; *ej = nil; return NO; }
    return [self refillTrackPool:src status:st json:ej];
}
- (NSDictionary *)pickTrack:(NSString *)src status:(NSInteger *)st json:(id *)ej {
    // Nunca GET si aún hay tracks en pool (también los del disco)
    if (![src isEqualToString:self.poolSrc] || self.trackPool.count < 1) {
        if (![self ensureTrackPool:src status:st json:ej]) return nil;
    }
    NSMutableArray *ok = [NSMutableArray array];
    NSMutableArray *soft = [NSMutableArray array];
    NSDictionary *fallback = nil;
    for (NSDictionary *t in self.trackPool) {
        NSString *uri = t[@"uri"];
        if (!uri.length || [self.blockedUris containsObject:uri]) continue;
        if (self.onAirUri.length && [uri isEqualToString:self.onAirUri]) continue;
        if (!fallback) fallback = t;
        BOOL uriHit = [self.recentUris containsObject:uri];
        BOOL artHit = [self artistBlocked:t[@"akey"]];
        if (!uriHit && !artHit) [ok addObject:t];
        else [soft addObject:t];
    }
    NSArray *pool = ok.count ? ok : (soft.count ? soft : (fallback ? @[fallback] : @[]));
    if (!pool.count) {
        // pool agotado de verdad → un solo GET si no hay cuota
        if ([self backoffLeft] > 0) { *st = 429; *ej = nil; return nil; }
        if (![self refillTrackPool:src status:st json:ej]) return nil;
        NSMutableArray *again = [NSMutableArray array];
        for (NSDictionary *t in self.trackPool) {
            NSString *u = t[@"uri"];
            if (!u.length || [self.blockedUris containsObject:u]) continue;
            if (self.onAirUri.length && [u isEqualToString:self.onAirUri]) continue;
            [again addObject:t];
        }
        pool = again.count ? again : @[];
        if (!pool.count) { *st = 0; return nil; }
    }
    NSDictionary *pick = pool[arc4random_uniform((uint32_t)pool.count)];
    NSString *puri = pick[@"uri"];
    NSIndexSet *rm = [self.trackPool indexesOfObjectsPassingTest:^BOOL(NSDictionary *obj, NSUInteger idx, BOOL *stop) {
        return [obj[@"uri"] isEqualToString:puri];
    }];
    if (rm.count) [self.trackPool removeObjectsAtIndexes:rm];
    [self persistTrackPool];
    return pick;
}
// Cambiar = siempre canción al azar + momento al azar.
// Modo radio OFF solo afecta el auto-avance: siguiente desde el inicio, sin flip de carátulas.
// flip=YES → UI hace shuffle de carátulas (solo Cambiar / dial).
- (void)clearQuotaBanner {
    // Solo UI. NO borrar backoffUntil: si se limpia, la API vuelve a pegar y el 429 vuelve “muy rápido”.
    [self send:@{@"t": @"quota", @"sec": @0, @"clear": @YES}];
}
- (void)primeNextTrack {
    // Siguiente canción lista (pool) → el dial/Cambiar suena al tiro sin next×N
    if (!self.useLocalSpotify) return;
    NSString *src = self.store[@"cur"] ?: @"liked";
    if (![src isKindOfClass:[NSString class]] || !src.length) src = @"liked";
    if (![src isEqualToString:self.poolSrc] || self.trackPool.count < 1) {
        if ([self backoffLeft] > 0) return;
        NSInteger st = 0; id ej = nil;
        if (![self ensureTrackPool:src status:&st json:&ej]) return;
    }
    NSInteger st = 0; id ej = nil;
    NSDictionary *t = [self pickTrack:src status:&st json:&ej];
    if (!t[@"uri"]) return;
    NSMutableDictionary *p = [t mutableCopy];
    NSString *art = p[@"art"] ?: @"";
    if (!art.length) art = [self coverArtForTrackURI:p[@"uri"]] ?: @"";
    if (art.length) { p[@"art"] = art; [self rememberArt:art]; }
    p[@"src"] = src;
    self.primedNext = p;
    [self send:@{@"t": @"primed", @"uri": p[@"uri"] ?: @"", @"name": p[@"name"] ?: @"", @"artist": p[@"artist"] ?: @"", @"art": art ?: @""}];
}
- (double)radioMidSecForDurationMs:(double)durMs {
    if (durMs <= 20000) return 0;
    return (durMs / 1000.0) * (0.15 + 0.60 * ((double)arc4random_uniform(10000) / 10000.0));
}
- (void)finishLocalTune:(NSDictionary *)t posSec:(double)posSec flip:(BOOL)flip fromStart:(BOOL)fromStart {
    [self clearQuotaBanner];
    NSString *wantUri = t[@"uri"] ?: @"";
    NSDictionary *live = [self localSpotifyState];
    NSString *liveId = [live[@"id"] hasPrefix:@"spotify:track:"] ? live[@"id"] : @"";
    // Solo corregir posición si Spotify ya muestra LA canción pedida.
    // Si aún reporta la anterior, un seek a 0/mitad la REINICIA (bug b6 / peo).
    BOOL liveMatches = wantUri.length && liveId.length && [liveId isEqualToString:wantUri];
    NSString *uri = liveMatches ? liveId : (wantUri.length ? wantUri : liveId);
    NSString *name = @"";
    NSString *artist = @"";
    NSString *art = @"";
    if (liveMatches) {
        name = (live[@"name"] ?: t[@"name"]) ?: @"";
        artist = (live[@"artist"] ?: t[@"artist"]) ?: @"";
        art = (live[@"art"] ?: t[@"art"]) ?: @"";
    } else {
        // Sin liveMatch: NUNCA tomar nombre/tapa del now-playing (suele ser la canción anterior).
        name = t[@"name"] ?: @"";
        artist = t[@"artist"] ?: @"";
        art = t[@"art"] ?: @"";
    }
    double dur = liveMatches && live[@"dur"] ? [live[@"dur"] doubleValue] : ([t[@"dur"] doubleValue] ?: [live[@"dur"] doubleValue]);
    double pos = liveMatches && live[@"pos"] ? [live[@"pos"] doubleValue] : posSec;
    // Un solo seek, y solo si Spotify ya está en la URI pedida.
    if (fromStart) {
        if (liveMatches && pos > 1.0) [self seekLocalSec:0];
        pos = 0;
    } else if (liveMatches) {
        double want = posSec >= 2.0 ? posSec : [self radioMidSecForDurationMs:dur];
        if (want >= 2.0 && pos < 2.0) {
            [self seekLocalSec:want];
            pos = want;
        }
        // Si ya está al medio (AfterPlay): no segundo seek → peo.
    } else if (!fromStart && posSec >= 2.0) {
        pos = posSec; // sin seek: Spotify aún no matchea
    }
    NSString *akey = [self primaryArtist:artist] ?: (t[@"akey"] ?: @"");
    [self rememberPlayedUri:uri];
    [self rememberPlayedArtist:akey];
    if (art.length) [self rememberArt:art];
    self.onAirUri = uri;
    self.onAirArtist = akey;
    self.awaitingEnd = YES;
    self.lastTuneAt = [NSDate timeIntervalSinceReferenceDate];
    self.store[@"arts"] = [self.arts copy];
    [self rememberDevice:@"local" name:@"Spotify en este Mac" type:@"Computer"];
    [self persistPlayMemory];
    NSMutableDictionary *last = [@{@"id": uri, @"name": name, @"artist": artist,
                                   @"art": art ?: @"", @"dur": @(dur), @"pos": @(pos), @"st": @"playing"} mutableCopy];
    self.store[@"last"] = last;
    [self saveStore];
    [self send:@{@"t": @"tuned", @"uri": uri, @"name": name, @"artist": artist,
                 @"art": art ?: @"", @"dur": @(dur), @"pos": @(pos), @"flip": @(flip)}];
    dispatch_async(dispatch_get_main_queue(), ^{ [self ensurePoll:2.5]; });
    if (!art.length && uri.length) {
        NSString *uriCopy = [uri copy];
        dispatch_async(self.q, ^{
            NSString *a = [self coverArtForTrackURI:uriCopy timeout:3.0] ?: @"";
            if (!a.length) return;
            if (![uriCopy isEqualToString:self.onAirUri]) return;
            [self rememberArt:a];
            if ([self.store[@"last"] isKindOfClass:[NSDictionary class]]) {
                NSMutableDictionary *L = [self.store[@"last"] mutableCopy];
                L[@"art"] = a; self.store[@"last"] = L; [self saveStore];
            }
            [self send:@{@"t": @"art", @"uri": uriCopy, @"art": a}];
        });
    }
    dispatch_async(self.q, ^{ [self primeNextTrack]; });
}
- (void)cambiarRadio:(BOOL)radio device:(NSString *)forced fromStart:(BOOL)fromStart flip:(BOOL)flip {
    // No mandar arts históricos al flip (UI ya no los usa para shuffle)
    [self send:@{@"t": @"tuning", @"arts": @[], @"flip": @(flip)}];
    NSString *src = self.store[@"cur"] ?: @"liked";
    if (![src isKindOfClass:[NSString class]] || !src.length) src = @"liked";
    // Camino A local.
    if (self.useLocalSpotify) {
        BOOL sameCtx = self.localCtxSrc.length && [self.localCtxSrc isEqualToString:src];
        NSDictionary *got = nil;
        if (sameCtx) {
            // Mismo contexto: AS next (no abre). Pool AS solo si next falla + enterrar Spotify.
            [self beginSpotifyASQuiet];
            got = [self playLocalContext:src fromStart:fromStart];
            if (!got[@"uri"]) {
                NSDictionary *primed = self.primedNext;
                if (primed[@"uri"] && [primed[@"src"] isEqualToString:src]) {
                    got = [self playPickedLocal:primed src:src fromStart:fromStart];
                    self.primedNext = nil;
                }
            } else {
                self.primedNext = nil;
            }
            if (!got[@"uri"]) {
                NSInteger st = 0; id ej = nil;
                for (int attempt = 0; attempt < 3; attempt++) {
                    NSDictionary *picked = [self pickTrack:src status:&st json:&ej];
                    got = [self playPickedLocal:picked src:src fromStart:fromStart];
                    if (got[@"uri"] || !picked[@"uri"]) break;
                }
            }
            [self endSpotifyASQuiet];
        } else {
            // Cambio de playlist (evidencia Reddit/Alfred/spotify-cli):
            // 1) PUT /me/player/play con context_uri — NO pide /items (403 en playlists ajenas).
            //    Connect mantiene Spotify.app en background.
            // 2) Si API falla: AS play playlist + reactivar frente (sin hide → no flash abre/cierra).
            self.primedNext = nil;
            NSString *prevUri = self.onAirUri.length ? [self.onAirUri copy] : @"";
            if ([self backoffLeft] <= 0) {
                got = [self playApiContextUriOnly:src fromStart:fromStart];
                if (!got[@"uri"]) {
                    // Pool solo si la playlist es nuestra (items OK); no inventar error 403 de lectura.
                    got = [self playApiContext:src fromStart:fromStart];
                }
            }
            if (!got[@"uri"]) {
                [self beginSpotifyASQuiet];
                got = [self openPlaylistContextAS:src fromStart:fromStart];
                [self endSpotifyASQuiet];
                // Si AS devolvió la misma URI de antes, esperar asiento real.
                if ([got[@"uri"] hasPrefix:@"spotify:track:"] && prevUri.length && [got[@"uri"] isEqualToString:prevUri]) {
                    NSDictionary *w = [self waitForTrackChangeFrom:prevUri attempts:8 interval:0.28];
                    if ([w[@"uri"] hasPrefix:@"spotify:track:"]) got = w;
                    else got = nil;
                }
                if (got[@"uri"]) self.localCtxSrc = [src copy];
            }
        }
        if (got[@"uri"]) {
            if (fromStart) [self seekLocalSec:0];
            [self finishLocalTune:got posSec:fromStart ? 0 : [got[@"pos"] doubleValue] flip:flip fromStart:fromStart];
            return;
        }
        self.awaitingEnd = NO;
        self.lastTuneAt = [NSDate timeIntervalSinceReferenceDate];
        if (self.appleEventsDenied) {
            [self promptSpotifyAutomation];
            return;
        }
        [self send:@{@"t": @"err", @"msg": self.lastAppleScriptErr.length ? self.lastAppleScriptErr : @"No pude sintonizar. Prueba Cambiar de nuevo."}];
        return;
    }
    BOOL poolWarm = [src isEqualToString:self.poolSrc] && self.trackPool.count >= 1;
    if (!poolWarm && ![self waitForQuotaOrAbort]) { [self note429]; return; }
    NSInteger s = 0; id j = nil;
    NSDictionary *t = [self pickTrack:src status:&s json:&j];
    if (!t) {
        if (s == 429) { [self note429]; return; }
        if (s == 403 && ![src isEqualToString:@"liked"] && ![[self msgFor:s json:j] containsString:@"Premium"]) [self send:@{@"t": @"err", @"msg": @"Spotify solo permite leer playlists tuyas o colaborativas."}];
        else if (s == 404 && ![src isEqualToString:@"liked"]) [self send:@{@"t": @"err", @"msg": @"No encuentro esa playlist. Elige otra fuente."}];
        else if (s) [self fail:s json:j];
        else [self send:@{@"t": @"err", @"msg": @"No hay canciones reproducibles en esta fuente."}];
        return;
    }
    double dur = [t[@"dur"] doubleValue], pos = 0;
    if (!fromStart && dur > 20000) pos = dur * (0.15 + 0.60 * ((double)arc4random_uniform(10000) / 10000.0));
    // Preferir Spotify.app CON contexto de playlist
    if (self.useLocalSpotify && [self playLocalTrack:t[@"uri"] positionMs:pos contextSrc:src]) {
        NSMutableDictionary *lt = [t mutableCopy];
        [self finishLocalTune:lt posSec:pos / 1000.0 flip:flip fromStart:fromStart];
        return;
    }
    if (![self waitForQuotaOrAbort]) { [self note429]; return; }
    NSString *dev = forced;
    NSString *saved = [self.store[@"device"] isKindOfClass:[NSString class]] ? self.store[@"device"] : @"";
    if (!dev && saved.length && ![saved isEqualToString:@"local"]) dev = saved;
    if (!dev) {
        j = nil;
        s = [self api:@"GET" path:@"/me/player/devices" body:nil out:&j];
        if (s != 200) { [self fail:s json:j]; return; }
        NSArray *ds = [J(j, @"devices") isKindOfClass:[NSArray class]] ? J(j, @"devices") : @[];
        NSMutableArray *usable = [NSMutableArray array];
        for (id d in ds) if (JS(d, @"id") && ![J(d, @"is_restricted") boolValue]) [usable addObject:d];
        if (usable.count == 1) { dev = JS(usable[0], @"id"); [self rememberDevice:dev name:JS(usable[0], @"name") type:JS(usable[0], @"type")]; }
        if (!dev) { self.pendingTuneFromStart = fromStart; [self offerDevices:ds radio:radio]; return; }
    }
    j = nil;
    // context_uri (no uris sueltos): si no, Spotify arma radio de canción
    NSDictionary *body;
    if ([src isEqualToString:@"liked"]) {
        body = @{@"uris": @[t[@"uri"]], @"position_ms": @((long long)pos)};
    } else {
        body = @{@"context_uri": [NSString stringWithFormat:@"spotify:playlist:%@", src],
                 @"offset": @{@"uri": t[@"uri"]},
                 @"position_ms": @((long long)pos)};
    }
    s = [self api:@"PUT" path:[@"/me/player/play?device_id=" stringByAppendingString:Enc(dev)] body:body out:&j];
    if (s == 404) {
        id dj = nil;
        if ([self api:@"GET" path:@"/me/player/devices" body:nil out:&dj] == 200) { self.pendingTuneFromStart = fromStart; [self offerDevices:J(dj, @"devices") radio:radio]; return; }
    }
    if (s < 200 || s >= 300) { [self fail:s json:j]; return; }
    [self rememberPlayedUri:t[@"uri"]];
    [self rememberPlayedArtist:t[@"akey"]];
    self.onAirUri = t[@"uri"];
    self.onAirArtist = t[@"akey"];
    self.awaitingEnd = YES;
    self.store[@"arts"] = [self.arts copy];
    [self persistPlayMemory];
    [self send:@{@"t": @"tuned", @"uri": t[@"uri"] ?: @"", @"name": t[@"name"] ?: @"", @"artist": t[@"artist"] ?: @"",
                 @"art": t[@"art"] ?: @"", @"dur": t[@"dur"] ?: @0, @"pos": @(pos / 1000.0), @"flip": @(flip)}];
    dispatch_async(dispatch_get_main_queue(), ^{ if ([self backoffLeft] <= 0) [self ensurePoll:20.0]; });
}
- (void)advanceRadio {
    if (self.busy) return;
    // Evitar tormenta si el último tune falló hace <4s
    if ([NSDate timeIntervalSinceReferenceDate] - self.lastTuneAt < 4.0 && !self.awaitingEnd) return;
    if (!self.useLocalSpotify && [self backoffLeft] > 0) return;
    self.busy = YES;
    BOOL radio = self.store[@"radio"] == nil ? YES : [self.store[@"radio"] boolValue];
    NSString *before = self.onAirUri ?: @"";
    [self radioLog:@"advance radioOn=%d fromStart=%d", radio ? 1 : 0, radio ? 0 : 1];
    // Preferir Connect next (no abre Spotify.app); AS/cambiar si falla.
    BOOL hopped = NO;
    if (self.useLocalSpotify && [self backoffLeft] <= 0 && [self apiPlayerNext]) {
        [NSThread sleepForTimeInterval:0.35];
        NSDictionary *live = [self apiNowPlaying];
        if (![live[@"uri"] hasPrefix:@"spotify:track:"]) {
            NSDictionary *as = [self localSpotifyState];
            if ([as[@"id"] hasPrefix:@"spotify:track:"])
                live = @{@"uri": as[@"id"], @"name": as[@"name"] ?: @"", @"artist": as[@"artist"] ?: @"",
                         @"akey": [self primaryArtist:as[@"artist"]] ?: @"", @"art": as[@"art"] ?: @"",
                         @"dur": as[@"dur"] ?: @0, @"pos": as[@"pos"] ?: @0};
        }
        NSString *nu = live[@"uri"] ?: @"";
        if ([nu hasPrefix:@"spotify:track:"] && ![nu isEqualToString:before]) {
            double dur = [live[@"dur"] doubleValue];
            double posSec = radio ? [self radioMidSecForDurationMs:dur] : 0;
            if (radio && posSec >= 2.0) {
                if (![self seekApiMs:(long long)(posSec * 1000.0)]) [self seekLocalSec:posSec];
            } else if (!radio) {
                [self seekApiMs:0];
                posSec = 0;
            }
            NSMutableDictionary *got = [@{@"uri": nu, @"name": live[@"name"] ?: @"", @"artist": live[@"artist"] ?: @"",
                                          @"akey": live[@"akey"] ?: @"", @"art": live[@"art"] ?: @"",
                                          @"dur": live[@"dur"] ?: @0, @"pos": @(posSec)} mutableCopy];
            [self finishLocalTune:got posSec:posSec flip:NO fromStart:!radio];
            hopped = YES;
        }
    }
    if (!hopped) [self cambiarRadio:radio device:nil fromStart:!radio flip:NO];
    // Si no cambió: backoff corto PERO mantener awaitingEnd (antes NO → radio muerta para siempre).
    if (!self.onAirUri.length || [self.onAirUri isEqualToString:before]) {
        self.lastTuneAt = [NSDate timeIntervalSinceReferenceDate];
        self.awaitingEnd = YES;
        [self radioLog:@"advance no-hop; keep awaitingEnd"];
    }
    self.busy = NO;
    [self send:@{@"t": @"done", @"a": @"advance"}];
    [self pushState];
}
- (void)offerDevices:(NSArray *)ds radio:(BOOL)radio { self.pendingRadio = radio; [self sendDevices:ds pick:YES]; }
- (void)sendDevices:(NSArray *)ds pick:(BOOL)pick {
    NSMutableArray *o = [NSMutableArray array];
    if ([ds isKindOfClass:[NSArray class]]) for (id d in ds) { NSDictionary *i = [self devInfo:d]; if ([i[@"id"] length]) [o addObject:i]; }
    [self send:@{@"t": @"devices", @"items": o, @"pick": @(pick), @"saved": self.store[@"device"] ?: @""}];
}

- (void)userContentController:(WKUserContentController *)c didReceiveScriptMessage:(WKScriptMessage *)m {
    if (![m.body isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *b = m.body;
    NSString *a = b[@"a"];
    if (![a isKindOfClass:[NSString class]]) return;
    if ([a isEqualToString:@"ready"]) {
        [self send:[self setupMsg]];
        if ([self.store[@"last"] isKindOfClass:[NSDictionary class]]) {
            NSMutableDictionary *last = [self.store[@"last"] mutableCopy];
            last[@"t"] = @"state"; last[@"sp"] = @"on";
            [self send:last];
        }
        // Cache ya; si faltan tapas (art) forzar refetch aunque haya ≥8
        dispatch_async(self.q, ^{
            NSArray *have = [self playlistMenuItems];
            if (have.count) {
                self.playlists = have;
                [self send:@{@"t": @"playlists", @"items": have}];
            }
            BOOL stale = NO;
            for (id p in have) {
                if (![p isKindOfClass:[NSDictionary class]]) continue;
                if (!JS(p, @"art").length) { stale = YES; break; }
                // n:0 tras elegir playlist (bug rememberPlaylistId) → refetch
                if (![self.store[@"healedPlaylistCounts35"] boolValue] && [JOk(p, @"n") integerValue] <= 0) { stale = YES; break; }
            }
            if (have.count >= 8 && !stale) return;
            [self loadPlaylists:YES];
            if (![self.store[@"healedPlaylistCounts35"] boolValue]) {
                self.store[@"healedPlaylistCounts35"] = @YES;
                [self saveStore];
            }
        });
    } else if ([a isEqualToString:@"save"]) {
        if (b[@"cur"]) self.store[@"cur"] = b[@"cur"];
        if (b[@"curName"]) self.store[@"curName"] = b[@"curName"];
        // radio:false es válido — no usar if(b[@"radio"]) (NSNumber 0 sigue siendo objeto)
        if (b[@"radio"] != nil) self.store[@"radio"] = b[@"radio"];
        [self saveStore];
    } else if ([a isEqualToString:@"setSource"]) {
        // atómico: cambia fuente + limpia memoria + sintoniza (evita carrera save/tune y dial)
        NSString *cur = [b[@"cur"] description] ?: @"";
        NSString *curName = [b[@"curName"] description] ?: @"Playlist";
        if (!cur.length) return;
        NSString *prev = [self.store[@"cur"] description] ?: @"";
        self.store[@"cur"] = cur;
        self.store[@"curName"] = curName;
        [self rememberPlaylistId:cur name:curName];
        if (![cur isEqualToString:prev]) {
            [self.recent removeAllObjects];
            [self.recentUris removeAllObjects];
            [self.recentArtists removeAllObjects];
            [self.totals removeObjectForKey:cur];
            [self clearTrackPool];
            self.primedNext = nil;
            self.localCtxSrc = nil;
            // Limpiar carátulas: si no, el flip muestra covers de la playlist anterior
            [self.arts removeAllObjects];
            self.store[@"arts"] = @[];
            [self persistPlayMemory];
            [self send:@{@"t": @"cacheCleared", @"arts": @[]}];
            [self radioLog:@"setSource clear arts %@ → %@", prev, cur];
        }
        [self saveStore];
        // Siempre encolar (si busy=return se perdía el cambio de playlist)
        NSInteger watchId = ++self.tuneWatchId;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!self.busy || self.tuneWatchId != watchId) return;
            self.busy = NO;
            [self send:@{@"t": @"done", @"a": @"unlock"}]; // silencioso: sin toast
        });
        dispatch_async(self.q, ^{
            self.busy = YES;
            // forzar reopen de contexto: localCtxSrc ya quedó nil al cambiar fuente
            [self cambiarRadio:YES device:nil fromStart:NO flip:YES];
            if (self.tuneWatchId == watchId) self.busy = NO;
            [self send:@{@"t": @"done", @"a": @"setSource"}];
            [self pushState];
            dispatch_async(dispatch_get_main_queue(), ^{ [self ensurePoll:2.0]; });
        });
    } else if ([a isEqualToString:@"overscreen"]) {
        BOOL on = [b[@"on"] boolValue];
        dispatch_async(dispatch_get_main_queue(), ^{ [self setOverscreenMode:on]; });
    } else if ([a isEqualToString:@"pin"]) {
        BOOL on = [b[@"on"] boolValue];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.pinnedTop = on;
            [self applyWindowLevel];
            if (on) {
                [self.teardownTimer invalidate]; self.teardownTimer = nil;
                [self makeWeb];
                [self.panel setFrame:[self panelFrame] display:YES];
                [self applyPanelChrome];
                [NSApp activateIgnoringOtherApps:YES];
                [self.panel makeKeyAndOrderFront:nil];
                [self.panel makeFirstResponder:self.web];
                [self armOutsideClose:NO];
            } else if (self.panel.isVisible && !self.overscreen) {
                [self armOutsideClose:YES];
            }
            [self send:@{@"t": @"pin", @"on": @(on)}];
        });
    } else if ([a isEqualToString:@"setClient"]) {
        NSString *cid = [[b[@"id"] description] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSCharacterSet *bad = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
        if (cid.length < 16 || cid.length > 64 || [cid rangeOfCharacterFromSet:bad].location != NSNotFound) { [self send:@{@"t": @"err", @"msg": @"Ese Client ID no parece válido (32 caracteres, letras y números)."}]; return; }
        if (![cid isEqualToString:self.clientId]) {
            self.clientId = cid; [self writePrivate:@"config.json" obj:@{@"client_id": cid}];
            self.tokens = nil; [self writePrivate:@"tokens.json" obj:nil];
        }
        if ([b[@"login"] boolValue]) [self login]; else [self send:[self setupMsg]];
    } else if ([a isEqualToString:@"login"]) {
        [self login];
    } else if ([a isEqualToString:@"cancelLogin"]) {
        [self stopListener];
        [self send:@{@"t": @"wait", @"on": @NO}];
    } else if ([a isEqualToString:@"copy"]) {
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        [pb clearContents]; [pb setString:[b[@"text"] description] ?: @"" forType:NSPasteboardTypeString];
    } else if ([a isEqualToString:@"openDash"]) {
        [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://developer.spotify.com/dashboard"]];
    } else if ([a isEqualToString:@"openWeb"]) {
        [self hidePanel];
        NSURL *safari = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:@"com.apple.Safari"];
        NSURL *u = [NSURL URLWithString:@"https://open.spotify.com/"];
        if (safari) [[NSWorkspace sharedWorkspace] openURLs:@[u] withApplicationAtURL:safari configuration:[NSWorkspaceOpenConfiguration configuration] completionHandler:nil];
        else [[NSWorkspace sharedWorkspace] openURL:u];
    } else if ([a isEqualToString:@"devlist"]) {
        dispatch_async(self.q, ^{
            id j = nil;
            NSInteger s = [self api:@"GET" path:@"/me/player/devices" body:nil out:&j];
            if (s == 200) [self sendDevices:J(j, @"devices") pick:NO]; else { [self send:@{@"t": @"devices", @"items": @[], @"pick": @NO, @"err": [self msgFor:s json:j]}]; }
        });
    } else if ([a isEqualToString:@"thisMac"]) {
        [self listenHere];
    } else if ([a isEqualToString:@"transfer"]) {
        NSString *i = [b[@"id"] description];
        if (!i.length) return;
        self.webWaitId++;
        [self rememberDevice:i name:[b[@"name"] description] type:[b[@"type"] description]];
        dispatch_async(self.q, ^{
            id j = nil;
            NSInteger s = [self transferTo:i json:&j];
            if (s < 200 || s >= 300) [self fail:s json:j];
            [NSThread sleepForTimeInterval:0.5];
            [self pushState];
        });
    } else if ([a isEqualToString:@"playlists"]) {
        BOOL force = [b[@"force"] boolValue];
        dispatch_async(self.q, ^{ [self loadPlaylists:force]; });
    } else if ([a isEqualToString:@"cambiar"] || [a isEqualToString:@"tune"] || [a isEqualToString:@"inicio"] || [a isEqualToString:@"useDevice"]) {
        // Si ya hay un tune en vuelo, no tirar el mensaje: la UI ya puso busy.
        // Encolar en q (serial) en vez de return silencioso → evita bolita eterna.
        BOOL radio = YES;
        BOOL fromStart = [a isEqualToString:@"useDevice"] ? self.pendingTuneFromStart : NO;
        NSString *dev = [a isEqualToString:@"useDevice"] ? [b[@"id"] description] : nil;
        if (dev) { self.webWaitId++; self.store[@"device"] = dev; self.store[@"deviceName"] = [b[@"name"] description] ?: @""; self.store[@"deviceType"] = [b[@"type"] description] ?: @""; [self saveStore]; }
        NSInteger watchId = ++self.tuneWatchId;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!self.busy || self.tuneWatchId != watchId) return;
            self.busy = NO;
            [self send:@{@"t": @"done", @"a": @"unlock"}];
        });
        dispatch_async(self.q, ^{
            self.busy = YES;
            if ([a isEqualToString:@"inicio"]) {
                if (self.useLocalSpotify) {
                    if (![self seekLocalSec:0]) [self send:@{@"t": @"err", @"msg": @"No pude ir al inicio en Spotify.app."}];
                } else {
                    id j = nil;
                    NSInteger s = [self api:@"PUT" path:@"/me/player/seek?position_ms=0" body:nil out:&j];
                    if (s < 200 || s >= 300) { if (s == 404) [self send:@{@"t": @"err", @"msg": @"No hay nada sonando ahora."}]; else [self fail:s json:j]; }
                }
                [NSThread sleepForTimeInterval:0.2];
            } else [self cambiarRadio:radio device:dev fromStart:fromStart flip:YES];
            self.busy = NO;
            [self send:@{@"t": @"done", @"a": a}];
            [self pushState];
            dispatch_async(dispatch_get_main_queue(), ^{ [self ensurePoll:2.0]; });
        });
    } else if ([a isEqualToString:@"unlock"]) {
        self.busy = NO;
        self.tuneWatchId++;
        [self send:@{@"t": @"done", @"a": @"unlock"}];
    } else if ([a isEqualToString:@"seek"]) {
        long long ms = (long long)MAX(0, [b[@"ms"] doubleValue]);
        dispatch_async(self.q, ^{
            BOOL ok = NO;
            if (self.useLocalSpotify) ok = [self seekLocalSec:ms / 1000.0];
            else {
                id j = nil;
                NSInteger s = [self api:@"PUT" path:[NSString stringWithFormat:@"/me/player/seek?position_ms=%lld", ms] body:nil out:&j];
                ok = (s >= 200 && s < 300);
                if (!ok) {
                    if (s == 404) [self send:@{@"t": @"err", @"msg": @"No hay nada sonando ahora."}];
                    else [self fail:s json:j];
                }
            }
            if (self.useLocalSpotify && !ok) [self send:@{@"t": @"err", @"msg": @"No pude mover la posición en Spotify.app."}];
            [NSThread sleepForTimeInterval:0.15];
            [self pushState];
        });
    } else if ([a isEqualToString:@"close"]) {
        if (self.overscreen) dispatch_async(dispatch_get_main_queue(), ^{ [self setOverscreenMode:NO]; });
        else [self hidePanel];
    } else if ([a isEqualToString:@"clearCache"]) {
        dispatch_async(self.q, ^{ [self clearSongCache]; });
    } else if ([a isEqualToString:@"about"]) {
        [self send:@{@"t": @"about", @"ver": [self appVersion]}];
    }
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *d = [[AppDelegate alloc] init];
        app.delegate = d;
        [app run];
    }
    return 0;
}
