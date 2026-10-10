#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import "SynorMarkdown.h"

static void (*chatRequest)(const char *);
static NSMapTable<NSString *, WKWebView *> *requestViews;
static NSString *backgroundTranslationID;
// 后台翻译由原生直接发起，没有注册网页视图，因此不能依赖单独一条 apiMessages 事件，
// 而是在这里累积流式正文，结束时统一交给通知写回前台应用的输入框。
static NSMutableString *backgroundTranslationText;

void synor_chat_event(const char *json) {
    NSString *payload = [NSString stringWithUTF8String:json];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *event = [NSJSONSerialization JSONObjectWithData:[payload dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        NSString *requestID = event[@"id"];
        if (!requestID) return;
        if ([event[@"balanceChanged"] boolValue]) [[NSNotificationCenter defaultCenter] postNotificationName:@"SynorBalanceChanged" object:nil];
        if (backgroundTranslationID && [requestID isEqual:backgroundTranslationID]) {
            if ([event[@"text"] isKindOfClass:NSString.class]) {
                if (!backgroundTranslationText) backgroundTranslationText = [NSMutableString new];
                [backgroundTranslationText appendString:event[@"text"]];
            }
            if (event[@"done"] || event[@"error"]) {
                // 出错时已累积的只是半截译文，不能写回；无论成功与否都通知，以便释放回填状态。
                NSString *result = !event[@"error"] && backgroundTranslationText.length ? backgroundTranslationText : nil;
                backgroundTranslationText = nil;
                backgroundTranslationID = nil;
                [[NSNotificationCenter defaultCenter] postNotificationName:@"SynorBackgroundTranslationDone" object:result];
            }
            // 后台翻译的所有事件都不转发给网页，避免出现在聊天或翻译面板里。
            return;
        }
        WKWebView *view = [requestViews objectForKey:requestID];
        if (event[@"done"] || event[@"error"] || event[@"settings"] || event[@"models"] || event[@"balance"]) [requestViews removeObjectForKey:requestID];
        [view callAsyncJavaScript:@"window.dispatchEvent(new CustomEvent('synor-chat', {detail: JSON.parse(payload)}));"
            arguments:@{@"payload":payload} inFrame:nil inContentWorld:WKContentWorld.pageWorld completionHandler:nil];
    });
}

@interface SynorPanel : NSPanel
@property(weak) WKWebView *chatView;
@end
@implementation SynorPanel
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    NSEventModifierFlags modifiers = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if (modifiers == NSEventModifierFlagCommand && [event.charactersIgnoringModifiers.lowercaseString isEqual:@"l"]) {
        [self.chatView evaluateJavaScript:@"if(!window.__SYNOR_TRANSLATION__) window.dispatchEvent(new Event('synor-clear-context'));" completionHandler:nil];
        return YES;
    }
    if (modifiers == NSEventModifierFlagCommand && [event.charactersIgnoringModifiers.lowercaseString isEqual:@"a"]) {
        // 无菜单面板显式转发全选操作，由 WebKit 按当前输入焦点处理。
        if ([NSApp sendAction:@selector(selectAll:) to:nil from:self]) return YES;
    }
    if (modifiers == NSEventModifierFlagCommand && [event.charactersIgnoringModifiers.lowercaseString isEqual:@"c"]) {
        // 交给当前原生响应者复制选区，保留 WebKit 对正文和输入框的选择处理。
        if ([NSApp sendAction:@selector(copy:) to:nil from:self]) return YES;
    }
    if (modifiers == NSEventModifierFlagCommand && [event.charactersIgnoringModifiers.lowercaseString isEqual:@"v"]) {
        // 无菜单的面板直接处理系统粘贴快捷键，不依赖 WebKit 生成文件粘贴事件。
        [self.chatView evaluateJavaScript:@"document.activeElement?.matches('textarea.input')"
            completionHandler:^(id isChat, NSError *error) {
                if (!error && [isChat boolValue]) {
                    [self.chatView evaluateJavaScript:@"window.webkit.messageHandlers.synor.postMessage({type:'paste'});" completionHandler:nil];
                } else {
                    [NSApp sendAction:@selector(paste:) to:nil from:self];
                }
            }];
        return YES;
    }
    return [super performKeyEquivalent:event];
}
- (void)cancelOperation:(id)sender {
    (void)sender;
    [self.chatView evaluateJavaScript:@"(()=>{const dialog=document.querySelector('dialog[open]'); if(dialog) dialog.close(); else window.webkit.messageHandlers.synor.postMessage({type:'close'});})();" completionHandler:nil];
}
@end

// 无选区时按 ⌘C 会复制整行的编辑器（VSCode 的 emptySelectionClipboard 等），
// 模拟复制的结果和真实选区无法从剪贴板区分，需要额外判断。
static NSSet<NSString *> *SynorLineCopyBundleIdentifiers(void) {
    static NSSet<NSString *> *identifiers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        identifiers = [NSSet setWithArray:@[
            @"com.microsoft.VSCode",
            @"com.microsoft.VSCodeInsiders",
            @"com.visualstudio.code.oss",
            @"com.vscodium",
            @"com.todesktop.230313mzl4w4u92", // Cursor
            @"com.exafunction.windsurf",
            @"dev.zed.Zed",
            @"com.sublimetext.4",
            @"com.sublimetext.3",
        ]];
    });
    return identifiers;
}
// 单行且以换行结尾的文本与“无选区复制整行”的结果无法区分，不作为可翻译的选区。
static BOOL SynorCopyLooksLikeWholeLine(NSString *text) {
    NSUInteger contentLength = text.length;
    if (!contentLength) return NO;
    if ([text hasSuffix:@"\r\n"]) contentLength -= 2;
    else if ([text hasSuffix:@"\n"] || [text hasSuffix:@"\r"]) contentLength -= 1;
    else return NO;
    return [text rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet options:0
        range:NSMakeRange(0, contentLength)].location == NSNotFound;
}

typedef struct {
    BOOL secure;          // 安全输入框，禁止读取选区
    BOOL apiAvailable;    // 元素对选区属性有响应，空选区才可信
    BOOL contentExposed;  // 元素暴露了完整文本（编辑器处于屏幕阅读器模式，如 VSCode）
    CFAbsoluteTime deadline;  // 遍历子元素/祖先的时限，避免阻塞主线程
} SynorSelectionProbe;

// 参数化属性可能返回普通字符串或富文本，统一取纯文本。
static NSString *SynorPlainTextFromValue(CFTypeRef value) {
    if (!value) return @"";
    if (CFGetTypeID(value) == CFStringGetTypeID()) return (__bridge NSString *)value;
    if (CFGetTypeID(value) == CFAttributedStringGetTypeID()) return [(__bridge NSAttributedString *)value string];
    return @"";
}

// 读取单个元素的选区：AXSelectedText → Text Marker → 选区范围参数化属性 → AXValue 按范围切片。
static NSString *SynorSelectionTextFromElement(AXUIElementRef element, SynorSelectionProbe *probe) {
    CFTypeRef subrole = NULL;
    if (AXUIElementCopyAttributeValue(element, kAXSubroleAttribute, &subrole) == kAXErrorSuccess && subrole) {
        if (CFEqual(subrole, kAXSecureTextFieldSubrole)) probe->secure = YES;
        CFRelease(subrole);
    }
    if (probe->secure) return @"";

    CFTypeRef selected = NULL;
    AXError selectedError = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute, &selected);
    if (selectedError == kAXErrorSuccess) {
        probe->apiAvailable = YES;
        NSString *text = selected ? [SynorPlainTextFromValue(selected) copy] : @"";
        if (selected) CFRelease(selected);
        if (text.length) return text;
    }

    // 网页与 WKWebView/Chromium 常用 Text Marker 报告选区。
    CFTypeRef markerRange = NULL;
    if (AXUIElementCopyAttributeValue(element, CFSTR("AXSelectedTextMarkerRange"), &markerRange) == kAXErrorSuccess && markerRange) {
        probe->apiAvailable = YES;
        CFStringRef markerAttributes[] = {CFSTR("AXStringForTextMarkerRange"), CFSTR("AXAttributedStringForTextMarkerRange")};
        for (size_t index = 0; index < sizeof(markerAttributes) / sizeof(markerAttributes[0]); index++) {
            CFTypeRef markerText = NULL;
            if (AXUIElementCopyParameterizedAttributeValue(element, markerAttributes[index], markerRange, &markerText) == kAXErrorSuccess && markerText) {
                NSString *text = [SynorPlainTextFromValue(markerText) copy];
                CFRelease(markerText);
                if (text.length) {
                    CFRelease(markerRange);
                    return text;
                }
            }
        }
        CFRelease(markerRange);
    }

    // 部分应用只暴露选区范围，通过参数化属性或整段文本切片获取对应文字。
    CFTypeRef range = NULL;
    if (AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute, &range) == kAXErrorSuccess && range) {
        probe->apiAvailable = YES;
        if (CFGetTypeID(range) == AXValueGetTypeID() && AXValueGetType((AXValueRef)range) == kAXValueCFRangeType) {
            CFRange selectedRange;
            if (AXValueGetValue((AXValueRef)range, kAXValueCFRangeType, &selectedRange) && selectedRange.length > 0) {
                CFStringRef rangeAttributes[] = {kAXStringForRangeParameterizedAttribute, kAXAttributedStringForRangeParameterizedAttribute};
                for (size_t index = 0; index < sizeof(rangeAttributes) / sizeof(rangeAttributes[0]); index++) {
                    CFTypeRef rangeText = NULL;
                    if (AXUIElementCopyParameterizedAttributeValue(element, rangeAttributes[index], range, &rangeText) == kAXErrorSuccess && rangeText) {
                        NSString *text = [SynorPlainTextFromValue(rangeText) copy];
                        CFRelease(rangeText);
                        if (text.length) {
                            CFRelease(range);
                            return text;
                        }
                    }
                }
                CFTypeRef value = NULL;
                if (AXUIElementCopyAttributeValue(element, kAXValueAttribute, &value) == kAXErrorSuccess && value && CFGetTypeID(value) == CFStringGetTypeID()) {
                    NSString *fullText = (__bridge NSString *)value;
                    // 选区范围按 UTF-16 偏移计算。
                    NSRange slice = NSMakeRange((NSUInteger)selectedRange.location, (NSUInteger)selectedRange.length);
                    NSString *text = NSMaxRange(slice) <= fullText.length ? [[fullText substringWithRange:slice] copy] : @"";
                    CFRelease(value);
                    if (text.length) {
                        CFRelease(range);
                        return text;
                    }
                } else if (value) {
                    CFRelease(value);
                }
            }
        }
        CFRelease(range);
    }
    return @"";
}

// 焦点元素：找到文字即返回；没有文字时额外读 AXValue，判断“空选区”是否可信。
static NSString *SynorSelectionTextFromFocusedElement(AXUIElementRef element, SynorSelectionProbe *probe) {
    NSString *text = SynorSelectionTextFromElement(element, probe);
    if (!text.length && !probe->secure) {
        CFTypeRef value = NULL;
        if (AXUIElementCopyAttributeValue(element, kAXValueAttribute, &value) == kAXErrorSuccess && value) {
            probe->contentExposed = SynorPlainTextFromValue(value).length > 0;
            CFRelease(value);
        }
    }
    return text;
}

// 网页里焦点元素往往只是容器，真正持有选区的节点在子树里；限制深度与节点数，避免在主线程上长时间等待。
static NSString *SynorSelectionTextInSubtree(AXUIElementRef element, NSInteger depth, NSInteger *budget, SynorSelectionProbe *probe) {
    if (depth <= 0 || *budget <= 0 || probe->secure || CFAbsoluteTimeGetCurrent() > probe->deadline) return @"";
    CFTypeRef childrenValue = NULL;
    if (AXUIElementCopyAttributeValue(element, kAXChildrenAttribute, &childrenValue) != kAXErrorSuccess || !childrenValue) return @"";
    if (CFGetTypeID(childrenValue) != CFArrayGetTypeID()) {
        CFRelease(childrenValue);
        return @"";
    }
    CFArrayRef children = (CFArrayRef)childrenValue;
    NSString *text = @"";
    for (CFIndex index = 0; index < CFArrayGetCount(children) && *budget > 0 && !probe->secure; index++) {
        CFTypeRef childValue = (CFTypeRef)CFArrayGetValueAtIndex(children, index);
        if (CFGetTypeID(childValue) != AXUIElementGetTypeID()) continue;
        *budget -= 1;
        AXUIElementRef child = (AXUIElementRef)childValue;
        text = SynorSelectionTextFromElement(child, probe);
        if (!text.length) text = SynorSelectionTextInSubtree(child, depth - 1, budget, probe);
        if (text.length || probe->secure) break;
    }
    CFRelease(childrenValue);
    return text;
}

// 跨节点的选区可能只由祖先（通常是 AXWebArea）报告，沿父链向上回溯若干层。
static NSString *SynorSelectionTextInAncestors(AXUIElementRef element, SynorSelectionProbe *probe) {
    const int maxLevels = 10;
    AXUIElementRef current = (AXUIElementRef)CFRetain(element);
    NSString *text = @"";
    for (int level = 0; level < maxLevels && !probe->secure && CFAbsoluteTimeGetCurrent() <= probe->deadline; level++) {
        CFTypeRef parentValue = NULL;
        AXError error = AXUIElementCopyAttributeValue(current, kAXParentAttribute, &parentValue);
        CFRelease(current);
        current = NULL;
        if (error != kAXErrorSuccess || !parentValue) break;
        if (CFGetTypeID(parentValue) != AXUIElementGetTypeID()) {
            CFRelease(parentValue);
            break;
        }
        current = (AXUIElementRef)parentValue;
        text = SynorSelectionTextFromElement(current, probe);
        if (text.length) break;
    }
    if (current) CFRelease(current);
    return text;
}

// 只有可编辑控件（输入框、contenteditable）才适合后台翻译后就地回填；
// 只有真正的输入控件才适合后台翻译后就地回填；静态文本（AI 回复、网页正文）写不进去，应改走翻译面板。
// 注意：Codex 的容器节点（AXGroup 等）会把 AXValue / AXSelectedText 的 IsAttributeSettable 报成 true，
// 属于假阳性，这里不能采信；只认 AXEditable 与文字角色。
static BOOL SynorElementIsEditable(AXUIElementRef element) {
    // 可编辑的文字角色集合；命中即认为适合写回。
    NSSet<NSString *> *editableRoles = [NSSet setWithArray:@[ @"AXTextField", @"AXTextArea", @"AXComboBox" ]];
    AXUIElementRef current = (AXUIElementRef)CFRetain(element);
    BOOL editable = NO;
    for (int level = 0; level < 4 && current; level++) {
        CFTypeRef value = NULL;
        if (AXUIElementCopyAttributeValue(current, CFSTR("AXEditable"), &value) == kAXErrorSuccess && value) {
            if (CFGetTypeID(value) == CFBooleanGetTypeID()) editable = CFBooleanGetValue((CFBooleanRef)value);
            CFRelease(value);
        }
        if (!editable) {
            CFTypeRef role = NULL;
            if (AXUIElementCopyAttributeValue(current, kAXRoleAttribute, &role) == kAXErrorSuccess && role) {
                editable = [editableRoles containsObject:(__bridge NSString *)role];
                CFRelease(role);
            }
        }
        if (editable) break;
        CFTypeRef parent = NULL;
        AXError error = AXUIElementCopyAttributeValue(current, kAXParentAttribute, &parent);
        CFRelease(current);
        current = NULL;
        if (error != kAXErrorSuccess || !parent || CFGetTypeID(parent) != AXUIElementGetTypeID()) {
            if (parent) CFRelease(parent);
            break;
        }
        current = (AXUIElementRef)parent;
    }
    if (current) CFRelease(current);
    return editable;
}

@interface PanelController : NSObject <NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate>
@property(strong) SynorPanel *panel;
@property(strong) NSURL *pageURL;
@property(strong) NSStatusItem *statusItem;
@property(strong) NSMenu *statusMenu;
@property(strong) id globalKeyMonitor;
@property(strong) id localKeyMonitor;
@property BOOL optionHeld;
@property NSTimeInterval lastOptionTap;
@property(strong) NSTimer *selectionTimer;
@property BOOL selectionIsSecure;
@property BOOL selectionAPIAvailable;
@property BOOL selectionContentExposed;
@property(strong) SynorPanel *translationPanel;
@property(strong) NSURL *translationURL;
@property BOOL translationReady;
@property(copy) NSString *pendingTranslation;
@property AXUIElementRef backgroundElement;
@property(copy) NSString *backgroundOriginal;
@property NSRange backgroundSelection;
@property BOOL backgroundHasSelection;
@property(strong) SynorPanel *settingsPanel;
@property(strong) NSURL *settingsURL;
@end
@implementation PanelController
- (void)clearBackgroundTranslation {
    if (self.backgroundElement) CFRelease(self.backgroundElement);
    self.backgroundElement = NULL;
    self.backgroundOriginal = nil;
    self.backgroundHasSelection = NO;
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    __weak PanelController *backgroundWeakSelf = self;
    [[NSNotificationCenter defaultCenter] addObserverForName:@"SynorBalanceChanged" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        (void)note;
        [backgroundWeakSelf.panel.chatView evaluateJavaScript:@"window.dispatchEvent(new Event('synor-settings-refresh'));" completionHandler:nil];
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:@"SynorBackgroundTranslationDone" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        PanelController *owner = backgroundWeakSelf; NSString *translated = note.object;
        if (!owner) return;
        if (!owner.backgroundElement || !translated.length) { [owner clearBackgroundTranslation]; return; }
        CFTypeRef current = NULL;
        NSString *currentText = nil;
        if (AXUIElementCopyAttributeValue(owner.backgroundElement, kAXValueAttribute, &current) == kAXErrorSuccess && current && CFGetTypeID(current) == CFStringGetTypeID()) currentText = (__bridge NSString *)current;
        // 只有能核对到完整原值未变时才写回；用户继续输入或读不到原值时放弃，避免冲掉新内容。
        BOOL unchanged = owner.backgroundOriginal && currentText && [currentText isEqual:owner.backgroundOriginal];
        if (unchanged && currentText) {
            NSRange selection = owner.backgroundSelection;
            if (owner.backgroundHasSelection && NSMaxRange(selection) <= currentText.length) {
                // 只替换选中的那一段，保留输入框里的其它内容，并把光标定位到译文末尾。
                NSString *updated = [currentText stringByReplacingCharactersInRange:selection withString:translated];
                if (AXUIElementSetAttributeValue(owner.backgroundElement, kAXValueAttribute, (__bridge CFStringRef)updated) == kAXErrorSuccess) {
                    CFRange caret = CFRangeMake(selection.location, translated.length);
                    AXValueRef range = AXValueCreate(kAXValueCFRangeType, &caret);
                    if (range) { AXUIElementSetAttributeValue(owner.backgroundElement, kAXSelectedTextRangeAttribute, range); CFRelease(range); }
                }
            }
        }
        if (current) CFRelease(current);
        [owner clearBackgroundTranslation];
    }];
    self.panel = [[SynorPanel alloc] initWithContentRect:NSMakeRect(0, 0, 680, 740)
        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    self.panel.contentMinSize = NSMakeSize(460, 500);
    self.panel.title = @"Synor · Web 聊天演示";
    self.panel.level = NSFloatingWindowLevel;
    self.panel.opaque = NO;
    self.panel.backgroundColor = NSColor.clearColor;
    self.panel.hasShadow = YES;
    self.panel.movableByWindowBackground = YES;
    self.panel.hidesOnDeactivate = NO;
    self.panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
        NSWindowCollectionBehaviorFullScreenAuxiliary;
    NSGlassEffectView *glass = [[NSGlassEffectView alloc] initWithFrame:NSMakeRect(0, 0, 680, 740)];
    glass.style = NSGlassEffectViewStyleRegular;
    glass.cornerRadius = 18;
    glass.clipsToBounds = YES;
    NSView *content = [[NSView alloc] initWithFrame:glass.bounds];
    content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    glass.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    glass.contentView = content;
    self.panel.contentView = glass;
    NSURL *iconURL = [[self.pageURL.URLByDeletingLastPathComponent URLByDeletingLastPathComponent]
        URLByAppendingPathComponent:@"Assets/MenuBarIcon.png"];
    NSImageView *logo = [[NSImageView alloc] initWithFrame:NSMakeRect(26, 689, 32, 32)];
    logo.image = [[NSImage alloc] initWithContentsOfURL:iconURL];
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];
    NSImage *statusImage = [[NSImage alloc] initWithContentsOfURL:[iconURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"MenuBarIcon.png"]];
    statusImage.size = NSMakeSize(18, 18);
    statusImage.template = YES;
    self.statusItem.button.image = statusImage;
    self.statusItem.button.toolTip = @"Synor · 点击显示，右键打开菜单";
    self.statusItem.button.accessibilityLabel = @"Synor";
    self.statusItem.button.target = self;
    self.statusItem.button.action = @selector(statusClicked:);
    [self.statusItem.button sendActionOn:NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp];
    self.statusMenu = [NSMenu new];
    NSMenuItem *show = [self.statusMenu addItemWithTitle:@"显示窗口" action:@selector(showWindow:) keyEquivalent:@""];
    show.target = self;
    NSMenuItem *translate = [self.statusMenu addItemWithTitle:@"快捷翻译" action:@selector(showTranslation:) keyEquivalent:@""];
    translate.target = self;
    NSMenuItem *settings = [self.statusMenu addItemWithTitle:@"AI 配置…" action:@selector(showSettings:) keyEquivalent:@""];
    settings.target = self;
    NSMenuItem *hide = [self.statusMenu addItemWithTitle:@"隐藏窗口" action:@selector(hideWindow:) keyEquivalent:@""];
    hide.target = self;
    NSMenuItem *shortcut = [self.statusMenu addItemWithTitle:@"启用连按两次 Option 快捷键…" action:@selector(requestShortcutPermission:) keyEquivalent:@""];
    shortcut.target = self;
    [self.statusMenu addItem:NSMenuItem.separatorItem];
    NSMenuItem *quit = [self.statusMenu addItemWithTitle:@"退出 Synor" action:@selector(terminate:) keyEquivalent:@"q"];
    quit.target = NSApp;
    logo.imageScaling = NSImageScaleProportionallyUpOrDown;
    logo.autoresizingMask = NSViewMinYMargin;
    logo.wantsLayer = YES;
    logo.layer.cornerRadius = 8;
    logo.layer.cornerCurve = kCACornerCurveContinuous;
    logo.layer.masksToBounds = YES;
    logo.accessibilityLabel = @"Synor 品牌标志";
    [content addSubview:logo];
    NSTextField *brand = [NSTextField labelWithString:@"SYNOR"];
    brand.font = [NSFont systemFontOfSize:17 weight:NSFontWeightSemibold];
    [brand sizeToFit];
    brand.frame = NSMakeRect(66, 691 + (28 - NSHeight(brand.frame)) / 2,
                             NSWidth(brand.frame), NSHeight(brand.frame));
    brand.autoresizingMask = NSViewMinYMargin;
    [content addSubview:brand];
    NSTextField *subtitle = [NSTextField labelWithString:@"让想法更清晰，让表达更自然。"];
    subtitle.font = [NSFont systemFontOfSize:12];
    subtitle.textColor = NSColor.secondaryLabelColor;
    [subtitle sizeToFit];
    CGFloat subtitleX = NSMaxX(brand.frame) + 10;
    subtitle.frame = NSMakeRect(subtitleX, NSMidY(brand.frame) - NSHeight(subtitle.frame) / 2,
                                604 - subtitleX, NSHeight(subtitle.frame));
    subtitle.lineBreakMode = NSLineBreakByTruncatingTail;
    subtitle.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [content addSubview:subtitle];
    NSTextField *escapeHint = [NSTextField labelWithString:@"Esc 隐藏"];
    escapeHint.font = [NSFont systemFontOfSize:11];
    escapeHint.textColor = NSColor.secondaryLabelColor;
    [escapeHint sizeToFit];
    escapeHint.frame = NSMakeRect(654 - NSWidth(escapeHint.frame),
        NSMidY(brand.frame) - NSHeight(escapeHint.frame) / 2,
        NSWidth(escapeHint.frame), NSHeight(escapeHint.frame));
    escapeHint.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    [content addSubview:escapeHint];
    NSRect subtitleFrame = subtitle.frame;
    subtitleFrame.size.width = NSMinX(escapeHint.frame) - 16 - NSMinX(subtitleFrame);
    subtitle.frame = subtitleFrame;


    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    configuration.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
    [configuration.userContentController addScriptMessageHandler:self name:@"synor"];
    WKWebView *web = [[WKWebView alloc] initWithFrame:NSMakeRect(20, 20, 640, 658) configuration:configuration];
    web.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.panel.chatView = web;

    web.navigationDelegate = self;
    web.wantsLayer = YES;
    web.layer.cornerRadius = 12;
    web.layer.cornerCurve = kCACornerCurveContinuous;
    web.layer.masksToBounds = YES;
    // WKWebView 的内部属性：演示中关闭默认底色，透出原生玻璃；系统升级需复核。
    [web setValue:@NO forKey:@"drawsBackground"];
    web.underPageBackgroundColor = NSColor.clearColor;
    [content addSubview:web];
    [web loadFileURL:self.pageURL allowingReadAccessToURL:self.pageURL.URLByDeletingLastPathComponent];
    __weak PanelController *weakSelf = self;
    NSEventMask shortcutEvents = NSEventMaskFlagsChanged | NSEventMaskKeyDown |
        NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown | NSEventMaskOtherMouseDown | NSEventMaskScrollWheel;
    self.localKeyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:shortcutEvents handler:^NSEvent *(NSEvent *event) {
        [weakSelf handleOptionEvent:event];
        return event;
    }];
    [self refreshGlobalShortcut];
    if (!AXIsProcessTrusted()) {
        AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge id)kAXTrustedCheckOptionPrompt:@YES});
    }
    [self restoreFrameForWindow:self.panel name:@"SynorMainWindow"];
    [self.panel makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}
// 只观察按键，不拦截、不记录输入；单独连按两次 Option 触发，其它组合键或鼠标操作会取消本次计数。
- (void)handleOptionEvent:(NSEvent *)event {
    NSEventModifierFlags mask = NSEventModifierFlagOption | NSEventModifierFlagCommand |
        NSEventModifierFlagControl | NSEventModifierFlagShift | NSEventModifierFlagFunction;
    NSEventModifierFlags flags = event.modifierFlags & mask;
    if (event.type != NSEventTypeFlagsChanged) {
        // 普通按键或鼠标操作会打断连按，取消已有计数。
        self.optionHeld = NO;
        self.lastOptionTap = 0;
        return;
    }
    if (flags != NSEventModifierFlagOption) {
        self.optionHeld = (flags & NSEventModifierFlagOption) != 0;
        // 只有组合了其它修饰键才取消计数；单纯松开保留时间戳，等待第二次按下。
        if (flags) self.lastOptionTap = 0;
        return;
    }
    if (self.optionHeld) return;  // 按住期间系统会重复发送，只认第一次按下
    self.optionHeld = YES;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (self.lastOptionTap > 0 && now - self.lastOptionTap <= MAX(NSEvent.doubleClickInterval, 0.35)) {
        self.lastOptionTap = 0;
        [self triggerOptionShortcut];
        return;
    }
    self.lastOptionTap = now;
}
// 连按两次 Option 后执行：有可读选区则翻译；Codex 输入框无选区时翻译整个输入；否则复制选区或显示聊天窗口。
- (void)triggerOptionShortcut {
    NSString *selection = [self selectedTextFromFrontmostApp];
    NSRunningApplication *app = NSWorkspace.sharedWorkspace.frontmostApplication;
    AXUIElementRef focused = NULL;
    if (!self.selectionIsSecure && [app.bundleIdentifier isEqual:@"com.openai.codex"]) {
        AXUIElementRef axApp = AXUIElementCreateApplication(app.processIdentifier);
        AXUIElementSetMessagingTimeout(axApp, 0.25);
        BOOL wholeInput = !selection.length;
        if (AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute, (CFTypeRef *)&focused) == kAXErrorSuccess && focused) {
            NSString *text = selection;
            // 没有选区时读取整个输入框作为原文。
            if (wholeInput && SynorElementIsEditable(focused)) {
                CFTypeRef value = NULL;
                if (AXUIElementCopyAttributeValue(focused, kAXValueAttribute, &value) == kAXErrorSuccess && value && CFGetTypeID(value) == CFStringGetTypeID()) text = [(__bridge NSString *)value copy];
                if (value) CFRelease(value);
            }
            if ([text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length && [self beginBackgroundTranslationIfPossible:text element:focused application:app wholeInput:wholeInput]) { CFRelease(focused); CFRelease(axApp); return; }
        }
        if (focused) CFRelease(focused); CFRelease(axApp);
    }
    if (!selection.length) { [self copySelectionOrShowChat]; return; }
    // Codex 的 Markdown 只存在于应用自己的复制格式里（AXSelectedText 会丢掉链接和行内代码），
    // 静态选区时再模拟一次 ⌘C 取 HTML 转 Markdown，失败则回退辅助功能读到的文本。
    if ([app.bundleIdentifier isEqual:@"com.openai.codex"] && !self.selectionTimer) {
        __weak PanelController *weakSelf = self;
        [self captureSelectionFrom:app completion:^(NSString *plain, NSString *html) {
            PanelController *owner = weakSelf;
            if (!owner) return;
            NSString *markdown = SynorMarkdownFromHTML(html);
            [owner presentTranslationText:(markdown.length ? markdown : (plain.length ? plain : selection))];
        }];
        return;
    }
    [self presentTranslationText:selection];
}
- (void)refreshGlobalShortcut {
    if (!AXIsProcessTrusted()) {
        if (self.globalKeyMonitor) [NSEvent removeMonitor:self.globalKeyMonitor];
        self.globalKeyMonitor = nil;
        return;
    }
    if (self.globalKeyMonitor) return;
    __weak PanelController *weakSelf = self;
    self.globalKeyMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:
        NSEventMaskFlagsChanged | NSEventMaskKeyDown | NSEventMaskLeftMouseDown |
        NSEventMaskRightMouseDown | NSEventMaskOtherMouseDown | NSEventMaskScrollWheel
        handler:^(NSEvent *event) { [weakSelf handleOptionEvent:event]; }];
}
- (void)requestShortcutPermission:(id)sender {
    (void)sender;
    if (AXIsProcessTrusted()) {
        [self refreshGlobalShortcut];
    } else {
        AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge id)kAXTrustedCheckOptionPrompt:@YES});
        [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
    }
}
- (void)applicationDidBecomeActive:(NSNotification *)notification {
    (void)notification;
    [self refreshGlobalShortcut];
}
- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self.selectionTimer invalidate];
    if (backgroundTranslationID && chatRequest) {
        NSData *cancel = [NSJSONSerialization dataWithJSONObject:@{ @"type": @"cancel", @"id": backgroundTranslationID } options:0 error:nil];
        if (cancel) chatRequest([[NSString alloc] initWithData:cancel encoding:NSUTF8StringEncoding].UTF8String);
    }
    backgroundTranslationID = nil;
    backgroundTranslationText = nil;
    [self clearBackgroundTranslation];
    // 退出前主动落盘，确保最后一次移动/缩放也被记住。
    [self.panel saveFrameUsingName:@"SynorMainWindow"];
    [self.translationPanel saveFrameUsingName:@"SynorTranslationWindow"];
    [self.settingsPanel saveFrameUsingName:@"SynorSettingsWindow"];
    if (self.globalKeyMonitor) [NSEvent removeMonitor:self.globalKeyMonitor];
    if (self.localKeyMonitor) [NSEvent removeMonitor:self.localKeyMonitor];
}
- (NSString *)selectedTextFromFrontmostApp {
    self.selectionIsSecure = NO;
    self.selectionAPIAvailable = NO;
    self.selectionContentExposed = NO;
    NSRunningApplication *application = NSWorkspace.sharedWorkspace.frontmostApplication;
    if (!AXIsProcessTrusted() || !application || application.processIdentifier == NSProcessInfo.processInfo.processIdentifier) return @"";
    AXUIElementRef app = AXUIElementCreateApplication(application.processIdentifier);
    AXUIElementSetMessagingTimeout(app, 0.25);
    SynorSelectionProbe probe = {NO, NO, NO, CFAbsoluteTimeGetCurrent() + 0.3};
    NSString *text = @"";
    CFTypeRef focused = NULL;
    if (AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute, &focused) == kAXErrorSuccess &&
        focused && CFGetTypeID(focused) == AXUIElementGetTypeID()) {
        text = SynorSelectionTextFromFocusedElement((AXUIElementRef)focused, &probe);
        if (!text.length && !probe.secure) {
            // 顺序与 selection-hook 一致：焦点元素 → 子树 → 祖先（跨节点选区由 AXWebArea 报告）。
            NSInteger budget = 20;
            text = SynorSelectionTextInSubtree((AXUIElementRef)focused, 2, &budget, &probe);
        }
        if (!text.length && !probe.secure) text = SynorSelectionTextInAncestors((AXUIElementRef)focused, &probe);
        CFRelease(focused);
    }
    self.selectionIsSecure = probe.secure;
    self.selectionAPIAvailable = probe.apiAvailable;
    self.selectionContentExposed = probe.contentExposed;
    // Chromium/Electron 默认不构建辅助功能树：连选区属性都问不到时打开开关（幂等），
    // 之后取词就能直接读 AX，不必再模拟 ⌘C。代价是目标应用会构建完整 AX 树。
    if (!text.length && !probe.secure && !probe.apiAvailable) {
        AXUIElementSetAttributeValue(app, CFSTR("AXEnhancedUserInterface"), kCFBooleanTrue);
        AXUIElementSetAttributeValue(app, CFSTR("AXManualAccessibility"), kCFBooleanTrue);
    }
    CFRelease(app);
    return text;
}

- (BOOL)beginBackgroundTranslationIfPossible:(NSString *)text element:(AXUIElementRef)element application:(NSRunningApplication *)application wholeInput:(BOOL)wholeInput {
    if (!text.length || text.length > 16000 || !element || !application || ![application.bundleIdentifier isEqual:@"com.openai.codex"] || !chatRequest) return NO;
    // 静态选区（例如 AI 回复正文）没有可写回的输入框，交给翻译面板处理。
    if (!SynorElementIsEditable(element)) return NO;
    // 记录全框原值与选区范围：之后按范围做就地替换，而不是用译文覆盖整个输入框。
    CFTypeRef value = NULL;
    NSString *fullText = nil;
    if (AXUIElementCopyAttributeValue(element, kAXValueAttribute, &value) == kAXErrorSuccess && value && CFGetTypeID(value) == CFStringGetTypeID()) fullText = [(__bridge NSString *)value copy];
    if (value) CFRelease(value);
    // 没有可核对的原值快照就无法安全写回，交给翻译面板处理；整框翻译时快照必须与原文一致。
    if (!fullText || fullText.length > 16000 || (wholeInput && ![fullText isEqualToString:text])) return NO;
    NSRange selection = NSMakeRange(NSNotFound, 0);
    CFTypeRef range = NULL;
    if (AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute, &range) == kAXErrorSuccess && range && CFGetTypeID(range) == AXValueGetTypeID()) {
        CFRange selected = {0, 0};
        if (AXValueGetValue((AXValueRef)range, kAXValueCFRangeType, &selected)) selection = NSMakeRange((NSUInteger)selected.location, (NSUInteger)selected.length);
    }
    if (range) CFRelease(range);
    // 无选区时覆盖全文，不能把译文插入零长度光标位置。
    if (wholeInput) selection = NSMakeRange(0, fullText.length);
    // 选区范围必须落在原值内且与读到的选中文字一致，否则回填位置不可信。
    if (selection.location == NSNotFound || selection.location > fullText.length ||
        selection.length > fullText.length - selection.location ||
        ![[fullText substringWithRange:selection] isEqualToString:text]) return NO;
    [self clearBackgroundTranslation];
    self.backgroundElement = (AXUIElementRef)CFRetain(element);
    self.backgroundOriginal = fullText;
    self.backgroundSelection = selection;
    self.backgroundHasSelection = selection.location != NSNotFound;
    NSString *requestID = [NSUUID UUID].UUIDString;
    backgroundTranslationText = nil;
    backgroundTranslationID = requestID;
    NSDictionary *body = @{ @"type": @"translate", @"id": requestID, @"text": text, @"target": @"English" };
    NSData *data = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    if (data) chatRequest([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
    return YES;
}
// 模拟一次 ⌘C 读取前台应用选区，读完还原剪贴板；plain 与 html 都可能为空。
- (void)captureSelectionFrom:(NSRunningApplication *)source completion:(void (^)(NSString *plain, NSString *html))completion {
    if (self.selectionTimer) return;
    __weak PanelController *weakSelf = self;
    NSDate *started = NSDate.date;
    __block NSDate *copiedAt = nil;
    __block NSInteger originalChange = 0;
    __block NSArray<NSPasteboardItem *> *savedItems = nil;
    self.selectionTimer = [NSTimer timerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *timer) {
        PanelController *owner = weakSelf;
        if (!owner) { [timer invalidate]; completion(@"", nil); return; }
        // 触发后立即读取；切换应用则取消，避免复制错误窗口。
        if (NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier != source.processIdentifier || -started.timeIntervalSinceNow > 5) {
            [timer invalidate]; owner.selectionTimer = nil; completion(@"", nil);
            return;
        }
        NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
        if (!copiedAt) {
            NSEventModifierFlags otherModifiers = NSEvent.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagShift | NSEventModifierFlagFunction);
            if (otherModifiers) {
                [timer invalidate]; owner.selectionTimer = nil; completion(@"", nil);
                return;
            }
            // 复制所有已发布的剪贴板格式，图片和富文本也一并保留。
            originalChange = pasteboard.changeCount;
            NSMutableArray *snapshot = [NSMutableArray array];
            for (NSPasteboardItem *item in pasteboard.pasteboardItems) {
                NSPasteboardItem *saved = [NSPasteboardItem new];
                for (NSPasteboardType type in item.types) {
                    NSData *data = [item dataForType:type];
                    if (data) [saved setData:data forType:type];
                }
                if (saved.types.count) [snapshot addObject:saved];
            }
            savedItems = snapshot;
            if (pasteboard.changeCount != originalChange || NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier != source.processIdentifier) {
                [timer invalidate]; owner.selectionTimer = nil; completion(@"", nil);
                return;
            }
            // 使用独立按键状态并明确只设置 Command，不继承用户仍按住的 Option。
            CGEventSourceRef copySource = CGEventSourceCreate(kCGEventSourceStatePrivate);
            CGEventRef down = copySource ? CGEventCreateKeyboardEvent(copySource, 8, true) : NULL;
            CGEventRef up = copySource ? CGEventCreateKeyboardEvent(copySource, 8, false) : NULL;
            if (copySource) CFRelease(copySource);
            if (!down || !up) {
                if (down) CFRelease(down);
                if (up) CFRelease(up);
                [timer invalidate]; owner.selectionTimer = nil; completion(@"", nil);
                return;
            }
            CGEventSetFlags(down, kCGEventFlagMaskCommand);
            CGEventSetFlags(up, kCGEventFlagMaskCommand);
            CGEventPostToPid(source.processIdentifier, down);
            CGEventPostToPid(source.processIdentifier, up);
            CFRelease(down); CFRelease(up);
            copiedAt = NSDate.date;
            return;
        }
        if (pasteboard.changeCount == originalChange && -copiedAt.timeIntervalSinceNow < 0.8) return;
        NSString *plain = @"", *html = nil;
        if (pasteboard.changeCount != originalChange) {
            NSInteger copiedChange = pasteboard.changeCount;
            plain = [[pasteboard stringForType:NSPasteboardTypeString] copy] ?: @"";
            // 富文本一并取下来，HTML 可用来还原 Markdown 结构。
            html = [[pasteboard stringForType:NSPasteboardTypeHTML] copy];
            // 只恢复仍然是本次读取版本的剪贴板，避免覆盖随后发生的更新。
            if (pasteboard.changeCount == copiedChange) {
                [pasteboard clearContents];
                if (savedItems.count) [pasteboard writeObjects:savedItems];
            }
        }
        [timer invalidate]; owner.selectionTimer = nil;
        completion(plain, html);
    }];
    [NSRunLoop.mainRunLoop addTimer:self.selectionTimer forMode:NSRunLoopCommonModes];
}
// 浏览器、微信等未提供 AX 选区时，通过应用自己的复制能力获取文本。
- (void)copySelectionOrShowChat {
    if (self.selectionTimer) return;
    NSRunningApplication *source = NSWorkspace.sharedWorkspace.frontmostApplication;
    if (self.selectionIsSecure || !AXIsProcessTrusted() || !source || source.processIdentifier == NSProcessInfo.processInfo.processIdentifier) {
        [self showWindow:nil];
        return;
    }
    // 编辑器在无选区时会复制整行：AX 树确实暴露了内容（屏幕阅读器模式）时，才把“空选区”当真。
    NSString *bundleIdentifier = source.bundleIdentifier ?: @"";
    BOOL lineCopyRisk = [SynorLineCopyBundleIdentifiers() containsObject:bundleIdentifier];
    if (self.selectionAPIAvailable && (!lineCopyRisk || self.selectionContentExposed)) {
        [self showWindow:nil];
        return;
    }
    __weak PanelController *weakSelf = self;
    [self captureSelectionFrom:source completion:^(NSString *plain, NSString *html) {
        (void)html;
        PanelController *owner = weakSelf;
        if (!owner) return;
        // 无选区时编辑器会复制整行，结果与“选中一整行”完全一致，只能按无选区处理。
        if (plain.length && !(lineCopyRisk && SynorCopyLooksLikeWholeLine(plain))) [owner presentTranslationText:plain];
        else [owner showWindow:nil];
    }];
}
- (void)presentTranslationText:(NSString *)text {
    if (text.length) self.pendingTranslation = text;
    if (!self.translationPanel) {
        self.translationURL = [self.pageURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"translation.html"];
        self.translationPanel = [[SynorPanel alloc] initWithContentRect:NSMakeRect(0, 0, 520, 660)
            styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel | NSWindowStyleMaskResizable
            backing:NSBackingStoreBuffered defer:NO];
        self.translationPanel.title = @"Synor · 快捷翻译";
        self.translationPanel.contentMinSize = NSMakeSize(420, 500);
        self.translationPanel.level = NSFloatingWindowLevel;
        self.translationPanel.opaque = NO;
        self.translationPanel.backgroundColor = NSColor.clearColor;
        self.translationPanel.hasShadow = YES;
        self.translationPanel.movableByWindowBackground = YES;
        self.translationPanel.hidesOnDeactivate = NO;
        self.translationPanel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
        NSGlassEffectView *glass = [[NSGlassEffectView alloc] initWithFrame:NSMakeRect(0, 0, 520, 660)];
        glass.style = NSGlassEffectViewStyleRegular;
        glass.cornerRadius = 18;
        glass.clipsToBounds = YES;
        glass.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        NSView *content = [[NSView alloc] initWithFrame:glass.bounds];
        content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        glass.contentView = content;
        self.translationPanel.contentView = glass;
        NSURL *iconURL = [[self.pageURL.URLByDeletingLastPathComponent URLByDeletingLastPathComponent]
            URLByAppendingPathComponent:@"Assets/MenuBarIcon.png"];
        NSImageView *logo = [[NSImageView alloc] initWithFrame:NSMakeRect(28, 625, 24, 24)];
        logo.image = [[NSImage alloc] initWithContentsOfURL:iconURL];
        logo.imageScaling = NSImageScaleProportionallyUpOrDown;
        logo.autoresizingMask = NSViewMinYMargin;
        logo.accessibilityLabel = @"Synor 品牌标志";
        [content addSubview:logo];
        NSTextField *title = [NSTextField labelWithString:@"SYNOR · 翻译"];
        title.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
        title.textColor = NSColor.secondaryLabelColor;
        title.frame = NSMakeRect(60, 628, 300, 18);
        title.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
        [content addSubview:title];
        NSTextField *escapeHint = [NSTextField labelWithString:@"Esc 隐藏"];
        escapeHint.font = [NSFont systemFontOfSize:11];
        escapeHint.textColor = NSColor.secondaryLabelColor;
        escapeHint.alignment = NSTextAlignmentRight;
        escapeHint.frame = NSMakeRect(420, 628, 72, 18);
        escapeHint.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
        [content addSubview:escapeHint];
        WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
        configuration.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
        [configuration.userContentController addScriptMessageHandler:self name:@"synor"];
        WKWebView *web = [[WKWebView alloc] initWithFrame:NSMakeRect(16, 16, 488, 604) configuration:configuration];
        web.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        web.navigationDelegate = self;
        [web setValue:@NO forKey:@"drawsBackground"];
        web.underPageBackgroundColor = NSColor.clearColor;
        self.translationPanel.chatView = web;
        [content addSubview:web];
        [web loadFileURL:self.translationURL allowingReadAccessToURL:self.translationURL.URLByDeletingLastPathComponent];
        [self restoreFrameForWindow:self.translationPanel name:@"SynorTranslationWindow"];
    }
    [NSApp activateIgnoringOtherApps:YES];
    [self.translationPanel makeKeyAndOrderFront:nil];
    [self deliverTranslation];
}
- (void)deliverTranslation {
    if (!self.translationReady || !self.pendingTranslation) return;
    [self.translationPanel.chatView callAsyncJavaScript:@"window.dispatchEvent(new CustomEvent('synor-chat', {detail:{type:'open-translation',text:text}}));"
        arguments:@{@"text":self.pendingTranslation} inFrame:nil inContentWorld:WKContentWorld.pageWorld completionHandler:nil];
    self.pendingTranslation = nil;
}
- (void)showTranslation:(id)sender {
    (void)sender;
    [self presentTranslationText:[self selectedTextFromFrontmostApp]];
}
- (void)presentSettings {
    if (!self.settingsPanel) {
        self.settingsURL = [self.pageURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"settings.html"];
        self.settingsPanel = [[SynorPanel alloc] initWithContentRect:NSMakeRect(0, 0, 560, 720)
            styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel | NSWindowStyleMaskResizable
            backing:NSBackingStoreBuffered defer:NO];
        self.settingsPanel.title = @"Synor · AI 配置";
        self.settingsPanel.contentMinSize = NSMakeSize(460, 560);
        self.settingsPanel.level = NSFloatingWindowLevel;
        self.settingsPanel.opaque = NO;
        self.settingsPanel.backgroundColor = NSColor.clearColor;
        self.settingsPanel.hasShadow = YES;
        self.settingsPanel.movableByWindowBackground = YES;
        self.settingsPanel.hidesOnDeactivate = NO;
        self.settingsPanel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
        NSGlassEffectView *glass = [[NSGlassEffectView alloc] initWithFrame:NSMakeRect(0, 0, 560, 720)];
        glass.style = NSGlassEffectViewStyleRegular;
        glass.cornerRadius = 18;
        glass.clipsToBounds = YES;
        glass.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        NSView *content = [[NSView alloc] initWithFrame:glass.bounds];
        content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        glass.contentView = content;
        self.settingsPanel.contentView = glass;
        NSURL *iconURL = [[self.pageURL.URLByDeletingLastPathComponent URLByDeletingLastPathComponent]
            URLByAppendingPathComponent:@"Assets/MenuBarIcon.png"];
        NSImageView *logo = [[NSImageView alloc] initWithFrame:NSMakeRect(26, 674, 32, 32)];
        logo.image = [[NSImage alloc] initWithContentsOfURL:iconURL];
        logo.imageScaling = NSImageScaleProportionallyUpOrDown;
        logo.autoresizingMask = NSViewMinYMargin;
        logo.wantsLayer = YES;
        logo.layer.cornerRadius = 8;
        logo.layer.cornerCurve = kCACornerCurveContinuous;
        logo.layer.masksToBounds = YES;
        logo.accessibilityLabel = @"Synor 品牌标志";
        [content addSubview:logo];
        // 与主窗口使用同一套品牌标题，避免配置窗口看起来像另一个应用。
        NSTextField *brand = [NSTextField labelWithString:@"SYNOR"];
        brand.font = [NSFont systemFontOfSize:17 weight:NSFontWeightSemibold];
        [brand sizeToFit];
        brand.frame = NSMakeRect(66, 676 + (28 - NSHeight(brand.frame)) / 2, NSWidth(brand.frame), NSHeight(brand.frame));
        brand.autoresizingMask = NSViewMinYMargin;
        [content addSubview:brand];
        NSTextField *subtitle = [NSTextField labelWithString:@"AI 配置"];
        subtitle.font = [NSFont systemFontOfSize:12];
        subtitle.textColor = NSColor.secondaryLabelColor;
        [subtitle sizeToFit];
        CGFloat subtitleX = NSMaxX(brand.frame) + 10;
        subtitle.frame = NSMakeRect(subtitleX, NSMidY(brand.frame) - NSHeight(subtitle.frame) / 2, 520 - subtitleX, NSHeight(subtitle.frame));
        subtitle.lineBreakMode = NSLineBreakByTruncatingTail;
        subtitle.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
        [content addSubview:subtitle];
        NSTextField *escapeHint = [NSTextField labelWithString:@"Esc 返回"];
        escapeHint.font = [NSFont systemFontOfSize:11];
        escapeHint.textColor = NSColor.secondaryLabelColor;
        [escapeHint sizeToFit];
        escapeHint.frame = NSMakeRect(540 - NSWidth(escapeHint.frame), NSMidY(brand.frame) - NSHeight(escapeHint.frame) / 2, NSWidth(escapeHint.frame), NSHeight(escapeHint.frame));
        escapeHint.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
        [content addSubview:escapeHint];
        NSRect subtitleFrame = subtitle.frame;
        subtitleFrame.size.width = NSMinX(escapeHint.frame) - 16 - NSMinX(subtitleFrame);
        subtitle.frame = subtitleFrame;
        WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
        configuration.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
        [configuration.userContentController addScriptMessageHandler:self name:@"synor"];
        WKWebView *web = [[WKWebView alloc] initWithFrame:NSMakeRect(20, 20, 520, 640) configuration:configuration];
        web.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        web.navigationDelegate = self;
        [web setValue:@NO forKey:@"drawsBackground"];
        web.underPageBackgroundColor = NSColor.clearColor;
        self.settingsPanel.chatView = web;
        [content addSubview:web];
        [web loadFileURL:self.settingsURL allowingReadAccessToURL:self.settingsURL.URLByDeletingLastPathComponent];
        [self restoreFrameForWindow:self.settingsPanel name:@"SynorSettingsWindow"];
    }
    [NSApp activateIgnoringOtherApps:YES];
    [self.settingsPanel makeKeyAndOrderFront:nil];
}
- (void)showSettings:(id)sender {
    (void)sender;
    [self presentSettings];
}
- (NSURL *)localPageForWebView:(WKWebView *)webView {
    if (self.translationPanel && webView == self.translationPanel.chatView) return self.translationURL;
    if (self.settingsPanel && webView == self.settingsPanel.chatView) return self.settingsURL;
    return self.pageURL;
}
// 各窗口共用：优先恢复上次的位置与大小；首次运行或保存位置已不在屏幕内时居中，并按最小尺寸收敛。
- (void)restoreFrameForWindow:(NSWindow *)window name:(NSString *)name {
    window.frameAutosaveName = name;
    BOOL restored = [window setFrameUsingName:name];
    NSSize minimum = window.contentMinSize;
    NSRect frame = window.frame;
    frame.size.width = MAX(NSWidth(frame), minimum.width);
    frame.size.height = MAX(NSHeight(frame), minimum.height);
    if (!NSEqualRects(frame, window.frame)) [window setFrame:frame display:NO];
    if (!restored || ![self windowFrameOnVisibleScreen:window]) [window center];
}
// 保存的位置可能来自已拔掉的显示器，完全不在任何屏幕内时视为失效。
- (BOOL)windowFrameOnVisibleScreen:(NSWindow *)window {
    for (NSScreen *screen in NSScreen.screens) {
        if (NSIntersectsRect(window.frame, screen.visibleFrame)) return YES;
    }
    return NO;
}
- (void)showWindow:(id)sender {
    (void)sender;
    [NSApp activateIgnoringOtherApps:YES];
    [self.panel makeKeyAndOrderFront:nil];
}
- (void)hideWindow:(id)sender {
    (void)sender;
    [self.panel orderOut:nil];
}
- (void)statusClicked:(id)sender {
    (void)sender;
    if (NSApp.currentEvent.type == NSEventTypeRightMouseUp) {
        [NSMenu popUpContextMenu:self.statusMenu withEvent:NSApp.currentEvent forView:self.statusItem.button];
    } else {
        [self showWindow:nil];
    }
}
- (BOOL)applicationShouldHandleReopen:(NSApplication *)application hasVisibleWindows:(BOOL)visible {
    (void)application; (void)visible;
    [self showWindow:nil];
    return YES;
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)application {
    (void)application;
    return NO;
}
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action
    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    // 每个窗口只允许加载自己的本地页面。
    decisionHandler([action.request.URL isEqual:[self localPageForWebView:webView]] ? WKNavigationActionPolicyAllow : WKNavigationActionPolicyCancel);
}
- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
    (void)controller;
    NSURL *allowedURL = [self localPageForWebView:message.webView];
    if (!message.frameInfo.isMainFrame || ![message.frameInfo.request.URL isEqual:allowedURL] ||
        ![message.body isKindOfClass:NSDictionary.class]) return;
    NSDictionary *body = message.body;
    if ([body[@"type"] isEqual:@"replace-chat-box"] && [body[@"text"] isKindOfClass:NSString.class]) {
        NSString *text = body[@"text"];
        // 顶层是字符串，必须显式允许 JSON 片段，否则 dataWithJSONObject 会抛异常。
        NSData *json = [NSJSONSerialization dataWithJSONObject:text options:NSJSONWritingFragmentsAllowed error:nil];
        NSString *literal = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
        [self.panel.chatView evaluateJavaScript:[NSString stringWithFormat:@"window.dispatchEvent(new CustomEvent('synor-translation-result',{detail:{text:%@}}))", literal] completionHandler:nil];
        return;
    }
    if ([body[@"type"] isEqual:@"open-translation"]) [self showTranslation:nil];
    if ([body[@"type"] isEqual:@"open-settings"]) [self presentSettings];
    if (([body[@"type"] isEqual:@"chat"] || [body[@"type"] isEqual:@"translate"] || [body[@"type"] isEqual:@"cancel"] || [body[@"type"] isEqual:@"settings-load"] || [body[@"type"] isEqual:@"settings-save"] || [body[@"type"] isEqual:@"models-load"] || [body[@"type"] isEqual:@"balance-load"]) && chatRequest) {
        if (![body[@"type"] isEqual:@"cancel"] && [body[@"id"] isKindOfClass:NSString.class]) {
            [requestViews setObject:message.webView forKey:body[@"id"]];
        }
        NSData *data = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
        if (data) chatRequest([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
    }
    if ([body[@"type"] isEqual:@"ready"]) {
        if (message.webView == self.translationPanel.chatView) { self.translationReady = YES; [self deliverTranslation]; }
        NSLog(@"Synor React chat mounted successfully");
    }
    if ([body[@"type"] isEqual:@"close"]) {
        if (message.webView == self.translationPanel.chatView) [self.translationPanel orderOut:nil];
        else if (message.webView == self.settingsPanel.chatView) {
            [self.settingsPanel orderOut:nil];
            // 关闭配置窗口后让聊天页重新读取配置，刷新底部模型名与思考开关。
            [self.panel.chatView evaluateJavaScript:@"window.dispatchEvent(new Event('synor-settings-refresh'));" completionHandler:nil];
        } else [self hideWindow:nil];
    }
    if ([body[@"type"] isEqual:@"paste"]) {
        NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
        NSImage *image = [[NSImage alloc] initWithPasteboard:pasteboard];
        NSDictionary *payload;
        if (image) {
            NSBitmapImageRep *bitmap = [NSBitmapImageRep imageRepWithData:image.TIFFRepresentation];
            NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
            payload = png ? @{@"image":[png base64EncodedStringWithOptions:0]} : @{@"error":@"无法读取剪贴板图片，请重新复制图片后再试。"};
        } else {
            payload = @{@"text":[pasteboard stringForType:NSPasteboardTypeString] ?: @""};
        }
        [message.webView callAsyncJavaScript:@"window.dispatchEvent(new CustomEvent('synor-paste', {detail: payload}));"
            arguments:@{@"payload":payload} inFrame:nil inContentWorld:WKContentWorld.pageWorld
            completionHandler:^(id result, NSError *error) {
                (void)result;
                if (error) NSLog(@"Native paste delivery failed: %@", error.localizedDescription);
            }];
    }
    if ([body[@"type"] isEqual:@"copy"] && [body[@"text"] isKindOfClass:NSString.class]) {
        [NSPasteboard.generalPasteboard clearContents];
        [NSPasteboard.generalPasteboard setString:body[@"text"] forType:NSPasteboardTypeString];
    }
}
@end

int synor_panel_run(const char *pagePath, void (*callback)(const char *)) {
    chatRequest = callback;
    requestViews = [NSMapTable strongToWeakObjectsMapTable];
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        PanelController *controller = [PanelController new];
        controller.pageURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:pagePath]];
        NSApp.delegate = controller;
        [NSApp run];
        (void)controller;
    }
    return 0;
}
