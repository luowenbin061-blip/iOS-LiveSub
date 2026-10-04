// LiveSub dylib 入口。
//
// Swift 没有 dyld 构造器，所以由这个 ObjC 文件承担入口：
// 加载时把引导丢进主队列（此时主队列可能还没跑起来，块会在 UIApplication 起来后执行），
// Swift 侧（@_cdecl("livesub_bootstrap")）再等 App 激活后安装悬浮层。

#import <Foundation/Foundation.h>

extern void livesub_bootstrap(void);

__attribute__((constructor))
static void LiveSubEntry(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        livesub_bootstrap();
    });
}