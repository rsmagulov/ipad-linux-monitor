/*
 * Connector for iPad: shows the H.264 stream from connector-host and sends
 * touches back as mouse input.
 *
 * Cable: the app listens on 127.0.0.1:CONNECTOR_PORT and the Linux host
 * reaches it through usbmuxd; the host also hands over its pairing key.
 * Wi-Fi/internet: once paired, the app finds the host on the local network
 * (UDP broadcast) or uses its internet address, and connects to it with
 * TLS-PSK. The cable wins whenever it is plugged in.
 * Decoding and display are done by AVSampleBufferDisplayLayer (hardware
 * decoder, frames shown immediately).
 *
 * Gestures (touch mode; trackpad mode moves the pointer instead, tap clicks,
 * tap-and-touch-again drags):
 *   tap                  left click
 *   touch + drag         left-button drag (select, move windows)
 *   hold still ~0.5 s    right click
 *   two-finger tap       right click
 *   two-finger hold      middle click
 *   two-finger drag      scroll
 *   three-finger tap     settings
 *   four-finger tap      keyboard
 */
#import <AVFoundation/AVFoundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <Network/Network.h>
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/utsname.h>
#include <stdatomic.h>
#include <sys/socket.h>
#include <unistd.h>

#include "../host/protocol.h"

#define L(s) NSLocalizedString(s, nil)

static uint32_t rd32(const uint8_t *p) { return (uint32_t)p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]; }

#pragma mark - Log

/* The app's own log, for bug reports: kept in Caches/connector.log, shown in
 * the settings, and sent to the computer's log (MSG_LOG) while connected.
 * Lines are in English; a line repeating the previous one only bumps a count. */
@interface AppLog : NSObject
+ (instancetype)shared;
- (void)log:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);
@property(atomic, copy) void (^sink)(NSString *lines); /* set while connected */
- (void)flushToSink;       /* sends what the computer hasn't seen yet */
- (NSString *)text;
@end

@implementation AppLog {
    dispatch_queue_t _q;
    NSMutableArray<NSString *> *_lines;
    NSMutableArray<NSString *> *_unsent;
    NSString *_last;
    int _repeats;
    NSString *_path;
}

+ (instancetype)shared
{
    static AppLog *log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = [[AppLog alloc] init]; });
    return log;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _q = dispatch_queue_create("connector.log", DISPATCH_QUEUE_SERIAL);
        _unsent = [NSMutableArray array];
        NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        _path = [caches stringByAppendingPathComponent:@"connector.log"];
        /* earlier runs: shown in the settings, not sent again */
        NSString *old = [NSString stringWithContentsOfFile:_path encoding:NSUTF8StringEncoding error:NULL];
        _lines = [[old componentsSeparatedByString:@"\n"] mutableCopy] ?: [NSMutableArray array];
        [_lines removeObject:@""];
        [self trim];
    }
    return self;
}

- (void)trim
{
    if (_lines.count > 400)
        [_lines removeObjectsInRange:NSMakeRange(0, _lines.count - 300)];
    if (_unsent.count > 300)
        [_unsent removeObjectsInRange:NSMakeRange(0, _unsent.count - 300)];
}

- (void)append:(NSString *)line
{
    static NSDateFormatter *f;
    if (!f) {
        f = [[NSDateFormatter alloc] init];
        f.dateFormat = @"MM-dd HH:mm:ss";
    }
    line = [NSString stringWithFormat:@"%@ %@", [f stringFromDate:[NSDate date]], line];
    [_lines addObject:line];
    [_unsent addObject:line];
    [self trim];
    NSString *all = [[_lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
    [all writeToFile:_path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

- (void)log:(NSString *)format, ...
{
    va_list ap;
    va_start(ap, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);
    NSLog(@"%@", msg);
    dispatch_async(_q, ^{
        if ([msg isEqualToString:self->_last]) {
            self->_repeats++;
            return;
        }
        if (self->_repeats)
            [self append:[NSString stringWithFormat:@"(the line above repeated %d more times)", self->_repeats]];
        self->_repeats = 0;
        self->_last = msg;
        [self append:msg];
        [self sendUnsent];
    });
}

- (void)sendUnsent
{
    void (^sink)(NSString *) = self.sink;
    if (!sink || !_unsent.count)
        return;
    sink([_unsent componentsJoinedByString:@"\n"]);
    [_unsent removeAllObjects];
}

- (void)flushToSink
{
    dispatch_async(_q, ^{ [self sendUnsent]; });
}

- (NSString *)text
{
    __block NSString *t;
    dispatch_sync(_q, ^{ t = [self->_lines componentsJoinedByString:@"\n"]; });
    return t;
}
@end

#define APPLOG(...) [AppLog.shared log:__VA_ARGS__]

static NSString *deviceModel(void)
{
    struct utsname u;
    uname(&u);
    return @(u.machine);
}

static NSString *appDescription(void)
{
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    return [NSString stringWithFormat:@"app=%@ (%@) ios=%@ model=%@", info[@"CFBundleShortVersionString"],
                                      info[@"CFBundleVersion"], UIDevice.currentDevice.systemVersion, deviceModel()];
}

#pragma mark - Video view

@interface VideoView : UIView
@property(nonatomic, readonly) AVSampleBufferDisplayLayer *displayLayer;
@end

@implementation VideoView
+ (Class)layerClass { return [AVSampleBufferDisplayLayer class]; }
- (AVSampleBufferDisplayLayer *)displayLayer { return (AVSampleBufferDisplayLayer *)self.layer; }
@end

#pragma mark - H.264 Annex B -> CMSampleBuffer

@interface H264Feeder : NSObject
- (instancetype)initWithLayer:(AVSampleBufferDisplayLayer *)layer;
/* Returns NO if the decoder needs a keyframe. */
- (BOOL)feedAnnexB:(const uint8_t *)data length:(size_t)len;
- (void)reset;
@end

@implementation H264Feeder {
    AVSampleBufferDisplayLayer *_layer;
    CMVideoFormatDescriptionRef _format;
    NSData *_sps, *_pps;
    BOOL _waitingForIDR;
}

- (instancetype)initWithLayer:(AVSampleBufferDisplayLayer *)layer
{
    if ((self = [super init])) {
        _layer = layer;
        _waitingForIDR = YES;
    }
    return self;
}

- (void)dealloc
{
    if (_format)
        CFRelease(_format);
}

- (void)reset
{
    _waitingForIDR = YES;
    [_layer flush];
}

/* Splits an Annex B buffer into NAL units (without start codes). */
static void forEachNAL(const uint8_t *d, size_t len, void (^block)(const uint8_t *nal, size_t n))
{
    size_t i = 0, start = SIZE_MAX;
    while (i + 3 <= len) {
        if (d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 1) {
            if (start != SIZE_MAX) {
                size_t end = i;
                while (end > start && d[end - 1] == 0)
                    end--;
                block(d + start, end - start);
            }
            i += 3;
            start = i;
        } else {
            i++;
        }
    }
    if (start != SIZE_MAX && start < len)
        block(d + start, len - start);
}

- (BOOL)feedAnnexB:(const uint8_t *)data length:(size_t)len
{
    __block NSData *sps = nil, *pps = nil;
    __block BOOL idr = NO;
    /* AVCC goes straight into the block buffer's memory. Each NAL trades a
     * start code of 3+ bytes for a 4-byte length, so len + len/4 is enough. */
    uint8_t *mem = malloc(len + len / 4 + 4);
    if (!mem)
        return NO;
    __block size_t used = 0;
    forEachNAL(data, len, ^(const uint8_t *nal, size_t n) {
        if (n == 0)
            return;
        int type = nal[0] & 0x1f;
        if (type == 7) {
            sps = [NSData dataWithBytes:nal length:n];
        } else if (type == 8) {
            pps = [NSData dataWithBytes:nal length:n];
        } else if (type == 1 || type == 5) {
            if (type == 5)
                idr = YES;
            uint32_t be = htonl((uint32_t)n);
            memcpy(mem + used, &be, 4);
            memcpy(mem + used + 4, nal, n);
            used += 4 + n;
        }
    });

    if (sps && pps && (!_format || ![sps isEqualToData:_sps] || ![pps isEqualToData:_pps])) {
        const uint8_t *sets[2] = {sps.bytes, pps.bytes};
        size_t sizes[2] = {sps.length, pps.length};
        CMVideoFormatDescriptionRef fmt = NULL;
        OSStatus st = CMVideoFormatDescriptionCreateFromH264ParameterSets(NULL, 2, sets, sizes, 4, &fmt);
        if (st != noErr) {
            APPLOG(@"decoder: bad SPS/PPS (%d)", (int)st);
            free(mem);
            return NO;
        }
        if (_format)
            CFRelease(_format);
        _format = fmt;
        _sps = sps;
        _pps = pps;
    }

    if (!used) {
        free(mem);
        return YES;
    }
    if (_waitingForIDR) {
        if (!idr || !_format) {
            free(mem);
            return NO;
        }
        _waitingForIDR = NO;
    }

    if (_layer.status == AVQueuedSampleBufferRenderingStatusFailed) {
        APPLOG(@"decoder: display layer failed: %@", _layer.error.localizedDescription);
        [self reset];
        free(mem);
        return NO;
    }
    /* The decoder fell behind: drop the backlog instead of letting the layer's
     * queue grow, and restart from the next keyframe. */
    if (!_layer.readyForMoreMediaData) {
        APPLOG(@"decoder: fell behind, dropping frames until the next keyframe");
        [self reset];
        free(mem);
        return NO;
    }

    /* Hand the bytes to the block buffer; it frees them with free(). */
    size_t n = used;
    CMBlockBufferRef block = NULL;
    if (CMBlockBufferCreateWithMemoryBlock(NULL, mem, n, kCFAllocatorMalloc, NULL, 0, n, 0, &block) != noErr) {
        free(mem);
        return NO;
    }
    CMSampleBufferRef sample = NULL;
    size_t sampleSize = n;
    OSStatus st = CMSampleBufferCreateReady(NULL, block, _format, 1, 0, NULL, 1, &sampleSize, &sample);
    CFRelease(block);
    if (st != noErr)
        return NO;
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, YES);
    CFMutableDictionaryRef dict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
    CFDictionarySetValue(dict, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
    [_layer enqueueSampleBuffer:sample];
    CFRelease(sample);
    return YES;
}
@end

#pragma mark - Pairing

/* Every computer the iPad was paired with by cable, the one used last first. */
static NSString *const kComputersKey = @"computers";
/* in each computer's dictionary: */
static NSString *const kKeyKey = @"key";         /* NSData, from the host over USB */
static NSString *const kNameKey = @"name";       /* the computer's host name */
static NSString *const kPortKey = @"port";
static NSString *const kPairAddressKey = @"pairAddress"; /* internet address the host told us */
static NSString *const kAddressKey = @"address";         /* internet address typed on the iPad (wins, "" = none) */
static NSString *const kLastLANKey = @"lastLAN";         /* where the host was last found on Wi-Fi */
static const NSUInteger kMaxComputers = 8;

static NSObject *computersLock(void)
{
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [[NSObject alloc] init]; });
    return lock;
}

/* App 1.4 knew one computer, kept under these keys of its own. */
static void migrateSinglePairing(NSUserDefaults *d)
{
    NSData *key = [d dataForKey:@"pairKey"];
    if (key.length == CONNECTOR_KEY_LEN && ![d arrayForKey:kComputersKey]) {
        NSMutableDictionary *c = [NSMutableDictionary dictionary];
        c[kKeyKey] = key;
        c[kNameKey] = [d stringForKey:@"pairName"] ?: L(@"the computer");
        c[kPortKey] = @([d integerForKey:@"pairPort"] ?: CONNECTOR_PORT);
        c[kPairAddressKey] = [d stringForKey:@"pairAddress"];
        NSString *typed = [d stringForKey:@"address"];
        c[kAddressKey] = typed.length ? typed : nil; /* 1.4 fell back to the host's address on "" */
        c[kLastLANKey] = [d stringForKey:@"lastLAN"];
        [d setObject:@[c] forKey:kComputersKey];
    }
    if (key)
        for (NSString *k in @[@"pairKey", @"pairName", @"pairPort", @"pairAddress", @"address", @"lastLAN"])
            [d removeObjectForKey:k];
}

static NSArray<NSDictionary *> *computers(void)
{
    @synchronized(computersLock()) {
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        migrateSinglePairing(d);
        NSMutableArray *list = [NSMutableArray array];
        for (NSDictionary *c in [d arrayForKey:kComputersKey])
            if ([c isKindOfClass:NSDictionary.class] && [c[kKeyKey] length] == CONNECTOR_KEY_LEN)
                [list addObject:c];
        return list;
    }
}

/* Applies `change` to the computer with `key`, or forgets it if `change` returns NO;
 * `front` makes it the one used last. */
static void editComputer(NSData *key, BOOL front, BOOL (^change)(NSMutableDictionary *c))
{
    @synchronized(computersLock()) {
        NSMutableArray *list = [computers() mutableCopy];
        for (NSUInteger i = 0; i < list.count; i++) {
            if (![list[i][kKeyKey] isEqualToData:key])
                continue;
            NSMutableDictionary *c = [list[i] mutableCopy];
            [list removeObjectAtIndex:i];
            if (change(c))
                [list insertObject:c atIndex:front ? 0 : i];
            break;
        }
        [NSUserDefaults.standardUserDefaults setObject:list forKey:kComputersKey];
    }
}

/* A cable pairing: the computer goes first. The same key or the same name is the
 * same computer (its key may have been made anew); the address typed for it and
 * where it was on Wi-Fi stay. */
static void addComputer(NSMutableDictionary *c)
{
    @synchronized(computersLock()) {
        NSMutableArray *list = [computers() mutableCopy];
        for (NSUInteger i = list.count; i-- > 0;) {
            NSDictionary *old = list[i];
            if (![old[kKeyKey] isEqualToData:c[kKeyKey]] && ![old[kNameKey] isEqualToString:c[kNameKey]])
                continue;
            for (NSString *k in @[kAddressKey, kLastLANKey])
                if (!c[k])
                    c[k] = old[k];
            [list removeObjectAtIndex:i];
        }
        [list insertObject:c atIndex:0];
        while (list.count > kMaxComputers)
            [list removeLastObject];
        [NSUserDefaults.standardUserDefaults setObject:list forKey:kComputersKey];
    }
}

static NSString *computerName(NSDictionary *c)
{
    return c[kNameKey] ?: L(@"the computer");
}

static NSString *internetAddress(NSDictionary *c)
{
    NSString *typed = c[kAddressKey];
    return typed ? typed : c[kPairAddressKey];
}

/* "host", "host:port", "[v6]:port" or a bare IPv6 address. */
static BOOL parseAddress(NSString *s, NSString **host, uint16_t *port)
{
    s = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *h = s, *p = nil;
    if ([s hasPrefix:@"["]) {
        NSRange r = [s rangeOfString:@"]"];
        if (!r.length)
            return NO;
        h = [s substringWithRange:NSMakeRange(1, r.location - 1)];
        NSString *rest = [s substringFromIndex:NSMaxRange(r)];
        if ([rest hasPrefix:@":"])
            p = [rest substringFromIndex:1];
    } else {
        NSRange first = [s rangeOfString:@":"], last = [s rangeOfString:@":" options:NSBackwardsSearch];
        if (first.length && first.location == last.location) {
            h = [s substringToIndex:first.location];
            p = [s substringFromIndex:first.location + 1];
        }
    }
    int port_ = p ? p.intValue : CONNECTOR_PORT;
    if (!h.length || port_ <= 0 || port_ > 65535)
        return NO;
    *host = h;
    *port = (uint16_t)port_;
    return YES;
}

/* What the host puts in its discovery replies: SHA-256(salt || key)[0..7]. */
static NSData *hostId(NSData *key)
{
    NSMutableData *m = [NSMutableData dataWithBytes:CONNECTOR_ID_SALT length:strlen(CONNECTOR_ID_SALT)];
    [m appendData:key];
    uint8_t h[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(m.bytes, (CC_LONG)m.length, h);
    return [NSData dataWithBytes:h length:CONNECTOR_ID_LEN];
}

#pragma mark - Connection

typedef NS_ENUM(int, LinkKind) { LinkNone, LinkUSB, LinkLAN, LinkInternet };

@protocol ConnectionDelegate
- (void)connectionDidOpen:(LinkKind)kind;
- (void)connectionDidClose;
- (void)connectionDidPair;
- (void)connectionStatusDidChange;
- (void)connectionDidConfigureWidth:(uint32_t)w height:(uint32_t)h;
- (void)connectionDidReceiveVideo:(const uint8_t *)data length:(size_t)len;
@end

/* One host connection at a time: either the host connects over USB to
 * 127.0.0.1:CONNECTOR_PORT, or we connect to it over the network. */
@interface Connection : NSObject
@property(nonatomic, weak) id<ConnectionDelegate> delegate;
@property(atomic, readonly) LinkKind link;
@property(atomic, readonly, copy) NSString *networkStatus; /* what the Wi-Fi side is doing, for the UI */
- (void)start;
- (void)send:(uint8_t)type payload:(const void *)payload length:(uint32_t)len;
- (void)dropNetwork; /* ends a Wi-Fi/internet session, so the computers are looked for again */
@end

@interface Connection ()
@property(atomic, readwrite) LinkKind link;
@property(atomic, readwrite, copy) NSString *networkStatus;
@end

@implementation Connection {
    NSMutableArray<NSString *> *_attempts; /* this round of the network loop, for the log */
    NSString *_lastFailure;
    int _listenFd;
    int _usbFd;
    nw_connection_t _net;
    dispatch_queue_t _writeQueue; /* serializes sends; guards _usbFd, _net and link changes */
    dispatch_queue_t _netQueue;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _listenFd = -1;
        _usbFd = -1;
        _writeQueue = dispatch_queue_create("connector.write", DISPATCH_QUEUE_SERIAL);
        _netQueue = dispatch_queue_create("connector.net", DISPATCH_QUEUE_SERIAL);
        self.networkStatus = @"";
    }
    return self;
}

- (void)start
{
    [NSThread detachNewThreadSelector:@selector(acceptLoop) toTarget:self withObject:nil];
    [NSThread detachNewThreadSelector:@selector(networkLoop) toTarget:self withObject:nil];
}

- (void)setStatus:(NSString *)status
{
    if ([status isEqualToString:self.networkStatus])
        return;
    self.networkStatus = status;
    [self.delegate connectionStatusDidChange];
}

#pragma mark USB

- (int)openListener
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr = {0};
    addr.sin_len = sizeof(addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons(CONNECTOR_PORT);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0 || listen(fd, 1) < 0) {
        APPLOG(@"usb: listen on port %d failed: %s", CONNECTOR_PORT, strerror(errno));
        close(fd);
        return -1;
    }
    return fd;
}

- (void)acceptLoop
{
    for (;;) {
        @autoreleasepool {
            if (_listenFd < 0 && (_listenFd = [self openListener]) < 0) {
                sleep(1);
                continue;
            }
            int fd = accept(_listenFd, NULL, NULL);
            if (fd < 0) {
                /* The listener dies when iOS suspends the app; reopen it. */
                close(_listenFd);
                _listenFd = -1;
                usleep(200000);
                continue;
            }
            int one = 1;
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
            int rcvbuf = 4 << 20;
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));
            /* The cable wins: drop a Wi-Fi session if there is one. */
            dispatch_sync(_writeQueue, ^{
                if (self->_net)
                    nw_connection_cancel(self->_net);
                self->_net = nil;
                self->_usbFd = fd;
                self.link = LinkUSB;
            });
            APPLOG(@"usb: the computer connected");
            [self.delegate connectionDidOpen:LinkUSB];
            [self readLoop:fd];
            APPLOG(@"usb: connection closed");
            dispatch_sync(_writeQueue, ^{
                self->_usbFd = -1;
                self.link = LinkNone;
            });
            close(fd);
            [self.delegate connectionDidClose];
        }
    }
}

static BOOL readFully(int fd, uint8_t *buf, size_t len)
{
    while (len) {
        ssize_t n = recv(fd, buf, len, 0);
        if (n <= 0) {
            if (n < 0 && errno == EINTR)
                continue;
            return NO;
        }
        buf += n;
        len -= n;
    }
    return YES;
}

- (void)readLoop:(int)fd
{
    size_t cap = 1 << 20;
    uint8_t *buf = malloc(cap);
    uint8_t hdr[CONNECTOR_HDR_LEN];
    while (readFully(fd, hdr, sizeof(hdr))) {
        uint32_t len = rd32(hdr + 1);
        if (len > (64u << 20))
            break;
        if (len > cap) {
            cap = len;
            buf = realloc(buf, cap);
        }
        if (!readFully(fd, buf, len))
            break;
        /* One pool per message: the connection can last for hours, and
         * acceptLoop's pool is only drained when it ends. */
        @autoreleasepool {
            [self handle:hdr[0] payload:buf length:len overUSB:YES];
        }
    }
    free(buf);
}

- (void)handle:(uint8_t)type payload:(const uint8_t *)p length:(uint32_t)len overUSB:(BOOL)usb
{
    if (type == MSG_CONFIG && len >= 8)
        [self.delegate connectionDidConfigureWidth:rd32(p) height:rd32(p + 4)];
    else if (type == MSG_VIDEO)
        [self.delegate connectionDidReceiveVideo:p length:len];
    else if (type == MSG_PAIR && usb)
        [self storePairing:p length:len];
}

- (void)storePairing:(const uint8_t *)p length:(uint32_t)len
{
    size_t o = 2 + CONNECTOR_KEY_LEN;
    if (len < o + 1 || o + 1 + p[o] > len)
        return;
    uint16_t port = (uint16_t)(p[0] << 8 | p[1]);
    NSData *key = [NSData dataWithBytes:p + 2 length:CONNECTOR_KEY_LEN];
    NSString *name = [[NSString alloc] initWithBytes:p + o + 1 length:p[o] encoding:NSUTF8StringEncoding];
    o += 1 + p[o];
    NSString *address = nil;
    if (o < len && o + 1 + p[o] <= len)
        address = [[NSString alloc] initWithBytes:p + o + 1 length:p[o] encoding:NSUTF8StringEncoding];

    NSMutableDictionary *c = [NSMutableDictionary dictionary];
    c[kKeyKey] = key;
    c[kNameKey] = name.length ? name : L(@"the computer");
    c[kPortKey] = @(port);
    c[kPairAddressKey] = address.length ? address : nil;
    addComputer(c);
    APPLOG(@"paired with “%@” (port %u, internet address %@)", name, port, address.length ? @"set" : @"none");
    [self.delegate connectionDidPair];
}

#pragma mark Wi-Fi / internet

- (void)networkLoop
{
    for (;;) {
        @autoreleasepool {
            NSArray<NSDictionary *> *list = computers();
            if (self.link != LinkNone || !list.count) {
                if (!list.count)
                    [self setStatus:@""];
                sleep(1);
                continue;
            }
            /* One computer is named in the status; several, by default the one used last. */
            NSString *name = computerName(list[0]), *host = nil, *address = nil;
            uint16_t port = 0;
            BOOL connected = NO, triedAddress = NO;

            [self setStatus:list.count == 1 ? [NSString stringWithFormat:L(@"Looking for “%@” on this Wi-Fi…"), name]
                                            : L(@"Looking for your computers on this Wi-Fi…")];
            _attempts = [NSMutableArray array];
            NSMutableArray<NSData *> *ids = [NSMutableArray array];
            for (NSDictionary *c in list)
                [ids addObject:hostId(c[kKeyKey])];
            NSInteger found = [self discover:ids host:&host port:&port];
            if (found >= 0) {
                NSDictionary *c = list[found];
                [_attempts addObject:[NSString stringWithFormat:@"wifi: found “%@” at %@:%u", computerName(c), host, port]];
                editComputer(c[kKeyKey], NO, ^BOOL(NSMutableDictionary *m) {
                    m[kLastLANKey] = host;
                    return YES;
                });
                [self setStatus:[NSString stringWithFormat:L(@"Connecting to “%@” over Wi-Fi (%@)…"), computerName(c), host]];
                connected = [self runSessionTo:host port:port kind:LinkLAN key:c[kKeyKey] timeout:6];
            } else {
                /* Broadcasts may be filtered; the last known addresses may still work. */
                for (NSDictionary *c in list) {
                    if (connected || self.link != LinkNone || !(host = c[kLastLANKey]))
                        continue;
                    [_attempts addObject:[NSString stringWithFormat:
                        @"wifi: no answer to the discovery broadcast, trying the last address of “%@”", computerName(c)]];
                    connected = [self runSessionTo:host port:[c[kPortKey] intValue] ?: CONNECTOR_PORT kind:LinkLAN
                                               key:c[kKeyKey] timeout:2];
                }
            }

            for (NSDictionary *c in list) {
                NSString *a = internetAddress(c);
                if (connected || self.link != LinkNone || !a.length)
                    continue;
                triedAddress = YES;
                address = address ?: a;
                if (parseAddress(a, &host, &port)) {
                    [self setStatus:[NSString stringWithFormat:L(@"Connecting over the internet to %@…"), a]];
                    connected = [self runSessionTo:host port:port kind:LinkInternet key:c[kKeyKey] timeout:8];
                } else {
                    [self setStatus:[NSString stringWithFormat:L(@"Can't read the address “%@”"), a]];
                    sleep(3);
                }
            }

            if (!connected && self.link == LinkNone) {
                if (found < 0 && !triedAddress)
                    [_attempts addObject:@"wifi: no answer to the discovery broadcast, no internet address set"];
                /* every few seconds: log only when something changed */
                NSString *summary = [_attempts componentsJoinedByString:@"\n"];
                if (![summary isEqualToString:_lastFailure]) {
                    for (NSString *line in _attempts)
                        APPLOG(@"%@", line);
                    APPLOG(@"network: not connected, retrying every few seconds");
                }
                _lastFailure = summary;
                [self setStatus:list.count > 1 ? L(@"None of your computers answers. Retrying…")
                                : address.length
                                ? [NSString stringWithFormat:L(@"“%@” is not on this Wi-Fi nor at %@. Retrying…"), name, address]
                                : [NSString stringWithFormat:L(@"“%@” is not on this Wi-Fi. Retrying…"), name]];
                sleep(3);
            }
        }
    }
}

- (void)dropNetwork
{
    dispatch_sync(_writeQueue, ^{
        if (self->_net)
            nw_connection_cancel(self->_net);
    });
}

static void broadcastQuery(int fd)
{
    struct sockaddr_in to = {.sin_len = sizeof(to), .sin_family = AF_INET, .sin_port = htons(CONNECTOR_PORT)};
    to.sin_addr.s_addr = htonl(INADDR_BROADCAST);
    sendto(fd, CONNECTOR_DISCOVER_QUERY, 4, 0, (struct sockaddr *)&to, sizeof(to));
    /* Directed broadcasts too: some setups don't pass 255.255.255.255. */
    struct ifaddrs *ifs;
    if (getifaddrs(&ifs) != 0)
        return;
    for (struct ifaddrs *i = ifs; i; i = i->ifa_next) {
        if (!i->ifa_addr || i->ifa_addr->sa_family != AF_INET || !i->ifa_dstaddr ||
            (i->ifa_flags & (IFF_UP | IFF_BROADCAST | IFF_LOOPBACK)) != (IFF_UP | IFF_BROADCAST))
            continue;
        struct sockaddr_in b = *(struct sockaddr_in *)i->ifa_dstaddr;
        b.sin_port = htons(CONNECTOR_PORT);
        sendto(fd, CONNECTOR_DISCOVER_QUERY, 4, 0, (struct sockaddr *)&b, sizeof(b));
    }
    freeifaddrs(ifs);
}

/* Asks the local network for the paired hosts; ~1.5 s at most. Returns the index
 * in `ids` of the first one that answered (0 ends the search at once), or -1. */
- (NSInteger)discover:(NSArray<NSData *> *)ids host:(NSString **)host port:(uint16_t *)port
{
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0)
        return -1;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, sizeof(one));
    struct timeval tv = {0, 100000};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    NSInteger found = -1;
    for (int round = 0; round < 3 && found < 0; round++) {
        broadcastQuery(fd);
        CFTimeInterval until = CACurrentMediaTime() + 0.5;
        while (found != 0 && CACurrentMediaTime() < until) {
            uint8_t r[64];
            struct sockaddr_in from;
            socklen_t fl = sizeof(from);
            ssize_t n = recvfrom(fd, r, sizeof(r), 0, (struct sockaddr *)&from, &fl);
            if (n < 4 + CONNECTOR_ID_LEN + 2 || memcmp(r, CONNECTOR_DISCOVER_REPLY, 4) != 0)
                continue;
            NSInteger i = 0, end = found < 0 ? (NSInteger)ids.count : found;
            while (i < end && memcmp(r + 4, ids[i].bytes, CONNECTOR_ID_LEN) != 0)
                i++;
            if (i == end)
                continue;
            found = i;
            char ip[INET_ADDRSTRLEN];
            inet_ntop(AF_INET, &from.sin_addr, ip, sizeof(ip));
            *host = @(ip);
            *port = (uint16_t)(r[4 + CONNECTOR_ID_LEN] << 8 | r[5 + CONNECTOR_ID_LEN]);
        }
    }
    close(fd);
    return found;
}

static BOOL isIPAddress(NSString *s)
{
    struct in6_addr a6;
    struct in_addr a4;
    return inet_pton(AF_INET, s.UTF8String, &a4) == 1 || inet_pton(AF_INET6, s.UTF8String, &a6) == 1;
}

/* Connects and runs one session until it ends. Returns NO if it never got connected. */
- (BOOL)runSessionTo:(NSString *)host port:(uint16_t)port kind:(LinkKind)kind key:(NSData *)key
             timeout:(int)timeout
{
    nw_endpoint_t endpoint = nw_endpoint_create_host(host.UTF8String, @(port).stringValue.UTF8String);
    BOOL named = !isIPAddress(host);
    nw_parameters_t params = nw_parameters_create_secure_tcp(^(nw_protocol_options_t tls) {
        sec_protocol_options_t sec = nw_tls_copy_sec_protocol_options(tls);
        dispatch_data_t psk = dispatch_data_create(key.bytes, key.length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
        dispatch_data_t identity = dispatch_data_create(CONNECTOR_PSK_IDENTITY, strlen(CONNECTOR_PSK_IDENTITY), NULL,
                                                        DISPATCH_DATA_DESTRUCTOR_DEFAULT);
        sec_protocol_options_add_pre_shared_key(sec, psk, identity);
        sec_protocol_options_add_tls_ciphersuite(sec, TLS_PSK_WITH_AES_128_GCM_SHA256);
        sec_protocol_options_set_tls_min_version(sec, kTLSProtocol12);
        sec_protocol_options_set_tls_max_version(sec, kTLSProtocol12);
        if (named) /* SNI: lets relays such as Tailscale Funnel route the connection */
            sec_protocol_options_set_tls_server_name(sec, host.UTF8String);
    }, ^(nw_protocol_options_t tcp) {
        nw_tcp_options_set_no_delay(tcp, true);
        nw_tcp_options_set_enable_keepalive(tcp, true);
        nw_tcp_options_set_keepalive_idle_time(tcp, 5);
        nw_tcp_options_set_keepalive_interval(tcp, 2);
        nw_tcp_options_set_keepalive_count(tcp, 3);
        nw_tcp_options_set_connection_timeout(tcp, timeout);
    });
    nw_connection_t c = nw_connection_create(endpoint, params);
    /* for the log: the internet address is the user's own business */
    NSString *where = kind == LinkLAN ? [NSString stringWithFormat:@"wifi: %@:%u", host, port] : @"internet address";

    dispatch_semaphore_t settled = dispatch_semaphore_create(0), ended = dispatch_semaphore_create(0);
    __block BOOL ready = NO;
    __block NSString *failure = @"timed out";
    nw_connection_set_state_changed_handler(c, ^(nw_connection_state_t state, nw_error_t error) {
        if (error) {
            NSError *e = (__bridge_transfer NSError *)nw_error_copy_cf_error(error);
            failure = [NSString stringWithFormat:@"%@ (%@ %ld)", e.localizedDescription, e.domain, (long)e.code];
        }
        if (state == nw_connection_state_ready) {
            ready = YES;
            dispatch_semaphore_signal(settled);
        } else if (state == nw_connection_state_failed || state == nw_connection_state_cancelled) {
            dispatch_semaphore_signal(settled);
            dispatch_semaphore_signal(ended);
        }
    });
    nw_connection_set_queue(c, _netQueue);
    nw_connection_start(c);
    dispatch_semaphore_wait(settled, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout + 2) * NSEC_PER_SEC));

    __block BOOL taken = NO;
    if (ready) {
        dispatch_sync(_writeQueue, ^{
            if (self.link == LinkNone) {
                self->_net = c;
                self.link = kind;
                taken = YES;
            }
        });
    }
    if (!taken) {
        nw_connection_cancel(c);
        [_attempts addObject:[NSString stringWithFormat:@"%@: failed: %@", where,
                                                        ready ? @"the cable took over" : failure]];
        return NO;
    }

    APPLOG(@"%@: connected", where);
    editComputer(key, YES, ^BOOL(NSMutableDictionary *m) { return YES; }); /* now the one used last */
    failure = @"closed";
    _lastFailure = nil;
    [self setStatus:@""];
    [self.delegate connectionDidOpen:kind];
    [self receiveOn:c ended:ended];
    dispatch_semaphore_wait(ended, DISPATCH_TIME_FOREVER);

    __block BOOL wasCurrent = NO;
    dispatch_sync(_writeQueue, ^{
        if (self->_net == c) { /* not replaced by the cable */
            self->_net = nil;
            self.link = LinkNone;
            wasCurrent = YES;
        }
    });
    nw_connection_cancel(c);
    APPLOG(@"%@: connection ended%@", where,
           wasCurrent ? [NSString stringWithFormat:@": %@", failure] : @" (switched to the cable)");
    if (wasCurrent)
        [self.delegate connectionDidClose];
    return YES;
}

static BOOL copyData(dispatch_data_t data, uint8_t *out, size_t len)
{
    if (!data || dispatch_data_get_size(data) != len)
        return NO;
    const void *bytes;
    size_t n;
    dispatch_data_t map = dispatch_data_create_map(data, &bytes, &n);
    memcpy(out, bytes, len);
    (void)map;
    return YES;
}

/* Reads one message, hands it on, and queues the next read; signals `ended` on error. */
- (void)receiveOn:(nw_connection_t)c ended:(dispatch_semaphore_t)ended
{
    nw_connection_receive(c, CONNECTOR_HDR_LEN, CONNECTOR_HDR_LEN,
                          ^(dispatch_data_t content, nw_content_context_t ctx, bool complete, nw_error_t error) {
        uint8_t hdr[CONNECTOR_HDR_LEN];
        if (error || !copyData(content, hdr, sizeof(hdr))) {
            dispatch_semaphore_signal(ended);
            return;
        }
        uint8_t type = hdr[0];
        uint32_t len = rd32(hdr + 1);
        if (len > (64u << 20)) {
            dispatch_semaphore_signal(ended);
            return;
        }
        if (len == 0) {
            [self handle:type payload:NULL length:0 overUSB:NO];
            [self receiveOn:c ended:ended];
            return;
        }
        nw_connection_receive(c, len, len,
                              ^(dispatch_data_t body, nw_content_context_t ctx2, bool complete2, nw_error_t error2) {
            if (error2 || !body || dispatch_data_get_size(body) != len) {
                dispatch_semaphore_signal(ended);
                return;
            }
            @autoreleasepool {
                const void *bytes;
                size_t n;
                dispatch_data_t map = dispatch_data_create_map(body, &bytes, &n);
                [self handle:type payload:bytes length:len overUSB:NO];
                (void)map;
            }
            [self receiveOn:c ended:ended];
        });
    });
}

#pragma mark Sending

- (void)send:(uint8_t)type payload:(const void *)payload length:(uint32_t)len
{
    NSMutableData *msg = [NSMutableData dataWithLength:CONNECTOR_HDR_LEN + len];
    uint8_t *p = msg.mutableBytes;
    p[0] = type;
    p[1] = len >> 24;
    p[2] = len >> 16;
    p[3] = len >> 8;
    p[4] = len;
    if (len)
        memcpy(p + CONNECTOR_HDR_LEN, payload, len);
    dispatch_async(_writeQueue, ^{
        if (self->_net) {
            dispatch_data_t d = dispatch_data_create(msg.bytes, msg.length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
            nw_connection_send(self->_net, d, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true, ^(nw_error_t e) {});
            return;
        }
        if (self->_usbFd < 0)
            return;
        const uint8_t *b = msg.bytes;
        size_t left = msg.length;
        while (left) {
            ssize_t n = send(self->_usbFd, b, left, 0);
            if (n <= 0) {
                if (n < 0 && errno == EINTR)
                    continue;
                return;
            }
            b += n;
            left -= n;
        }
    });
}
@end

#pragma mark - Settings

static NSString *const kScaleKey = @"scale";             /* percent */
static NSString *const kQualityKey = @"quality";         /* 0 normal, 1 high, 2 maximum */
static NSString *const kOrientationKey = @"orientation"; /* 0 auto, 1 landscape, 2 portrait */
static NSString *const kMirrorKey = @"mirror";           /* 0 second monitor, 1 mirror the computer's screen */
static NSString *const kTrackpadKey = @"trackpad";       /* 0 touch where you point, 1 trackpad */
static NSString *const kIndicatorKey = @"indicator";     /* 1 shows link and frame rate in a corner */

static const int kScales[] = {100, 125, 150, 175, 200};
static const int kScaleCount = sizeof(kScales) / sizeof(kScales[0]);

static int settingInt(NSString *key, int fallback)
{
    NSNumber *n = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return n ? n.intValue : fallback;
}

#pragma mark - App signature

/* A free Apple ID signs the app for 7 days; the date is in the provisioning
 * profile, a signed blob with a plist inside. */
static NSDate *signatureExpiry(void)
{
    NSString *path = [NSBundle.mainBundle pathForResource:@"embedded" ofType:@"mobileprovision"];
    NSData *d = path ? [NSData dataWithContentsOfFile:path] : nil;
    if (!d)
        return nil;
    NSRange a = [d rangeOfData:[@"<?xml" dataUsingEncoding:NSASCIIStringEncoding] options:0
                         range:NSMakeRange(0, d.length)];
    NSRange b = [d rangeOfData:[@"</plist>" dataUsingEncoding:NSASCIIStringEncoding] options:NSDataSearchBackwards
                         range:NSMakeRange(0, d.length)];
    if (!a.length || !b.length || NSMaxRange(b) <= a.location)
        return nil;
    NSData *plist = [d subdataWithRange:NSMakeRange(a.location, NSMaxRange(b) - a.location)];
    NSDictionary *p = [NSPropertyListSerialization propertyListWithData:plist options:0 format:NULL error:NULL];
    id e = [p isKindOfClass:NSDictionary.class] ? p[@"ExpirationDate"] : nil;
    return [e isKindOfClass:NSDate.class] ? e : nil;
}

static NSString *shortDate(NSDate *d)
{
    return [NSDateFormatter localizedStringFromDate:d dateStyle:NSDateFormatterMediumStyle
                                          timeStyle:NSDateFormatterShortStyle];
}

/* Local notifications a day and two hours before the app stops opening. */
static void scheduleResignReminders(NSDate *expires)
{
    if (!expires)
        return;
    UNUserNotificationCenter *c = UNUserNotificationCenter.currentNotificationCenter;
    [c requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionSound
                     completionHandler:^(BOOL granted, NSError *error) {
        [c removePendingNotificationRequestsWithIdentifiers:@[@"resign-1", @"resign-2"]];
        if (!granted)
            return;
        const NSTimeInterval before[2] = {24 * 3600, 2 * 3600};
        for (int i = 0; i < 2; i++) {
            NSTimeInterval in = expires.timeIntervalSinceNow - before[i];
            if (in < 60)
                continue;
            UNMutableNotificationContent *m = [[UNMutableNotificationContent alloc] init];
            m.title = L(@"Connector needs re-signing");
            m.body = [NSString stringWithFormat:L(@"The app stops opening on %@. Plug the iPad into the computer "
                                                  @"and run ipad-install from Connector."), shortDate(expires)];
            m.sound = UNNotificationSound.defaultSound;
            UNTimeIntervalNotificationTrigger *t = [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:in
                                                                                                      repeats:NO];
            [c addNotificationRequest:[UNNotificationRequest
                                          requestWithIdentifier:[NSString stringWithFormat:@"resign-%d", i + 1]
                                                        content:m trigger:t]
                withCompletionHandler:nil];
        }
    }];
}

#pragma mark - Settings panel

/* Overlay with the settings, scrollable when it doesn't fit; swallows touches
 * so they don't reach the mouse logic. */
@interface SettingsPanel : UIView
@property(nonatomic, copy) void (^onChange)(void);
@property(nonatomic, copy) void (^onClose)(void);
@property(nonatomic, copy) void (^onEditAddress)(void);
@property(nonatomic, copy) void (^onComputers)(void);
@property(nonatomic, copy) void (^onKeyboard)(void);
@property(nonatomic, copy) void (^onLog)(void);
- (void)setNetworkLine:(NSString *)line address:(NSString *)address computers:(NSString *)names;
- (void)fitInto:(CGSize)size;
@end

@implementation SettingsPanel {
    UIScrollView *_scroll;
    CGFloat _contentHeight;
    UISegmentedControl *_mirror, *_scale, *_quality, *_orientation, *_trackpad, *_indicator;
    UILabel *_networkLine;
    UIButton *_address, *_computers;
}

- (instancetype)init
{
    if ((self = [super initWithFrame:CGRectMake(0, 0, 560, 600)])) {
        self.backgroundColor = [UIColor colorWithWhite:0.11 alpha:0.96];
        self.layer.cornerRadius = 16;
        self.clipsToBounds = YES;
        self.tintColor = [UIColor colorWithRed:0.35 green:0.67 blue:1 alpha:1];
        _scroll = [[UIScrollView alloc] initWithFrame:self.bounds];
        _scroll.indicatorStyle = UIScrollViewIndicatorStyleWhite;
        _scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_scroll];

        CGFloat y = 24;
        UILabel *title = [self label:L(@"Settings") y:y size:24 bold:YES];
        y = CGRectGetMaxY(title.frame) + 18;

        y = [self section:L(@"iPad screen")
                    items:@[L(@"Second monitor"), L(@"Mirror the computer")]
                 selected:settingInt(kMirrorKey, 0) y:y control:&_mirror];

        NSMutableArray *scaleTitles = [NSMutableArray array];
        int scaleIndex = 1;
        for (int i = 0; i < kScaleCount; i++) {
            [scaleTitles addObject:[NSString stringWithFormat:@"%d%%", kScales[i]]];
            if (kScales[i] == settingInt(kScaleKey, CONNECTOR_SCALE_DEFAULT))
                scaleIndex = i;
        }
        y = [self section:L(@"Text and window size (100% is the smallest but the sharpest)")
                    items:scaleTitles selected:scaleIndex y:y control:&_scale];
        y = [self section:L(@"Sharpness (higher is crisper text, more traffic)")
                    items:@[L(@"Normal"), L(@"High"), L(@"Maximum")]
                 selected:settingInt(kQualityKey, 1) y:y control:&_quality];
        y = [self section:L(@"Orientation")
                    items:@[L(@"Auto"), L(@"Landscape"), L(@"Portrait")]
                 selected:settingInt(kOrientationKey, 0) y:y control:&_orientation];
        y = [self section:L(@"Pointer (trackpad: a finger moves the pointer, tap clicks, double-tap and drag drags)")
                    items:@[L(@"Touch where you point"), L(@"Trackpad")]
                 selected:settingInt(kTrackpadKey, 0) y:y control:&_trackpad];
        y = [self section:L(@"Connection and frame rate in the corner")
                    items:@[L(@"Hide"), L(@"Show")]
                 selected:settingInt(kIndicatorKey, 0) y:y control:&_indicator];

        UIButton *keyboard = [self button:L(@"Keyboard (or tap with four fingers)") y:y - 6 action:@selector(keyboard)];
        y = CGRectGetMaxY(keyboard.frame) + 14;

        UILabel *net = [self label:L(@"Wi-Fi and internet") y:y size:16 bold:NO];
        net.textColor = [UIColor colorWithWhite:0.8 alpha:1];
        _networkLine = [self label:@"" y:CGRectGetMaxY(net.frame) + 2 size:15 bold:NO];
        _networkLine.numberOfLines = 2;
        _networkLine.adjustsFontSizeToFitWidth = NO;
        _networkLine.frame = CGRectMake(24, CGRectGetMaxY(net.frame) + 2, self.bounds.size.width - 48, 42);
        _address = [self button:@"" y:CGRectGetMaxY(_networkLine.frame) + 2 action:@selector(editAddress)];
        _computers = [self button:@"" y:CGRectGetMaxY(_address.frame) action:@selector(editComputers)];
        y = CGRectGetMaxY(_computers.frame) + 14;

        NSDate *expires = signatureExpiry();
        UILabel *sig = [self label:expires ? [NSString stringWithFormat:L(@"App signature valid until %@"),
                                                                        shortDate(expires)]
                                           : L(@"App signature: date unknown")
                                y:y size:15 bold:NO];
        if (expires && expires.timeIntervalSinceNow < 2 * 24 * 3600)
            sig.textColor = [UIColor colorWithRed:1 green:0.6 blue:0.2 alpha:1];
        y = CGRectGetMaxY(sig.frame) + 10;

        UIButton *log = [self button:L(@"App log (for bug reports)") y:y - 4 action:@selector(showLog)];
        y = CGRectGetMaxY(log.frame) + 10;

        UILabel *hint = [self label:L(@"Three fingers: settings · four fingers: keyboard · two-finger hold: middle click")
                                  y:y size:14 bold:NO];
        hint.textColor = [UIColor colorWithWhite:0.6 alpha:1];

        UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem];
        [done setTitle:L(@"Done") forState:UIControlStateNormal];
        done.titleLabel.font = [UIFont boldSystemFontOfSize:20];
        done.frame = CGRectMake(0, CGRectGetMaxY(hint.frame) + 12, self.bounds.size.width, 44);
        [done addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
        [_scroll addSubview:done];

        _contentHeight = CGRectGetMaxY(done.frame) + 14;
        _scroll.contentSize = CGSizeMake(self.bounds.size.width, _contentHeight);
    }
    return self;
}

- (void)fitInto:(CGSize)size
{
    CGRect f = self.frame;
    f.size.width = MIN(560, size.width - 32);
    f.size.height = MIN(_contentHeight, size.height - 40);
    self.frame = f;
    self.center = CGPointMake(size.width / 2, size.height / 2);
}

- (UILabel *)label:(NSString *)text y:(CGFloat)y size:(CGFloat)size bold:(BOOL)bold
{
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(24, y, self.bounds.size.width - 48, size + 8)];
    l.text = text;
    l.textColor = UIColor.whiteColor;
    l.font = bold ? [UIFont boldSystemFontOfSize:size] : [UIFont systemFontOfSize:size];
    l.adjustsFontSizeToFitWidth = YES;
    l.minimumScaleFactor = 0.6;
    [_scroll addSubview:l];
    return l;
}

- (UIButton *)button:(NSString *)title y:(CGFloat)y action:(SEL)action
{
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:17];
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    b.frame = CGRectMake(24, y, self.bounds.size.width - 48, 36);
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [_scroll addSubview:b];
    return b;
}

- (CGFloat)section:(NSString *)title items:(NSArray *)items selected:(int)sel y:(CGFloat)y
           control:(UISegmentedControl *__strong *)out
{
    UILabel *l = [self label:title y:y size:16 bold:NO];
    l.textColor = [UIColor colorWithWhite:0.8 alpha:1];
    UISegmentedControl *c = [[UISegmentedControl alloc] initWithItems:items];
    c.frame = CGRectMake(24, CGRectGetMaxY(l.frame) + 6, self.bounds.size.width - 48, 40);
    c.selectedSegmentIndex = MAX(0, MIN(sel, (int)items.count - 1));
    [c setTitleTextAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:17]} forState:UIControlStateNormal];
    [c addTarget:self action:@selector(changed) forControlEvents:UIControlEventValueChanged];
    [_scroll addSubview:c];
    *out = c;
    return CGRectGetMaxY(c.frame) + 20;
}

- (void)changed
{
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setInteger:_mirror.selectedSegmentIndex forKey:kMirrorKey];
    [d setInteger:kScales[_scale.selectedSegmentIndex] forKey:kScaleKey];
    [d setInteger:_quality.selectedSegmentIndex forKey:kQualityKey];
    [d setInteger:_orientation.selectedSegmentIndex forKey:kOrientationKey];
    [d setInteger:_trackpad.selectedSegmentIndex forKey:kTrackpadKey];
    [d setInteger:_indicator.selectedSegmentIndex forKey:kIndicatorKey];
    APPLOG(@"settings: mirror %d, scale %d%%, quality %d, orientation %d, trackpad %d",
           (int)_mirror.selectedSegmentIndex, kScales[_scale.selectedSegmentIndex], (int)_quality.selectedSegmentIndex,
           (int)_orientation.selectedSegmentIndex, (int)_trackpad.selectedSegmentIndex);
    if (self.onChange)
        self.onChange();
}

- (void)close
{
    if (self.onClose)
        self.onClose();
}

- (void)editAddress
{
    if (self.onEditAddress)
        self.onEditAddress();
}

- (void)editComputers
{
    if (self.onComputers)
        self.onComputers();
}

- (void)keyboard
{
    if (self.onKeyboard)
        self.onKeyboard();
}

- (void)showLog
{
    if (self.onLog)
        self.onLog();
}

- (void)setNetworkLine:(NSString *)line address:(NSString *)address computers:(NSString *)names
{
    _networkLine.text = line;
    _address.hidden = _computers.hidden = !names.length;
    [_address setTitle:[NSString stringWithFormat:L(@"Internet address: %@ (change)"),
                                                   address.length ? address : L(@"not set")]
              forState:UIControlStateNormal];
    [_computers setTitle:[NSString stringWithFormat:L(@"Computers: %@ (change)"), names] forState:UIControlStateNormal];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}
@end

#pragma mark - Keyboard

/* X keysyms the app sends (see X11/keysymdef.h). */
enum {
    KS_BackSpace = 0xff08, KS_Tab = 0xff09, KS_Return = 0xff0d, KS_Escape = 0xff1b,
    KS_Home = 0xff50, KS_Left = 0xff51, KS_Up = 0xff52, KS_Right = 0xff53, KS_Down = 0xff54,
    KS_PageUp = 0xff55, KS_PageDown = 0xff56, KS_End = 0xff57, KS_Delete = 0xffff,
};

/* Keysym for one character pressed together with modifiers. */
static uint32_t keysymForChar(unichar c, int *mods)
{
    if (c == '\n' || c == '\r')
        return KS_Return;
    if (c == '\t')
        return KS_Tab;
    if (c == '\b')
        return KS_BackSpace;
    if (c >= 'A' && c <= 'Z') {
        *mods |= MOD_SHIFT;
        return c - 'A' + 'a';
    }
    return c < 0x100 ? c : 0x01000000 | c;
}

static uint32_t keysymForInput(NSString *input, int *mods)
{
    if ([input isEqualToString:UIKeyInputUpArrow]) return KS_Up;
    if ([input isEqualToString:UIKeyInputDownArrow]) return KS_Down;
    if ([input isEqualToString:UIKeyInputLeftArrow]) return KS_Left;
    if ([input isEqualToString:UIKeyInputRightArrow]) return KS_Right;
    if ([input isEqualToString:UIKeyInputEscape]) return KS_Escape;
    return input.length ? keysymForChar([input characterAtIndex:0], mods) : 0;
}

/* The bar above the on-screen keyboard: keys it doesn't have. Ctrl/Alt/Win
 * stay pressed for the next key. */
@interface KeyBar : UIView
@property(nonatomic, copy) void (^onKey)(uint32_t keysym);
@property(nonatomic, copy) void (^onHide)(void);
- (int)takeModifiers;
@end

@implementation KeyBar {
    NSMutableDictionary<NSNumber *, UIButton *> *_mods;
}

- (instancetype)init
{
    if ((self = [super initWithFrame:CGRectMake(0, 0, 768, 52)])) {
        self.backgroundColor = [UIColor colorWithWhite:0.16 alpha:1];
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        _mods = [NSMutableDictionary dictionary];
        NSArray *keys = @[@[@"Esc", @(KS_Escape)], @[@"Tab", @(KS_Tab)], @[@"Ctrl", @(-MOD_CTRL)],
                          @[@"Alt", @(-MOD_ALT)], @[@"Win", @(-MOD_SUPER)], @[@"◀", @(KS_Left)],
                          @[@"▲", @(KS_Up)], @[@"▼", @(KS_Down)], @[@"▶", @(KS_Right)],
                          @[@"Home", @(KS_Home)], @[@"End", @(KS_End)], @[@"PgUp", @(KS_PageUp)],
                          @[@"PgDn", @(KS_PageDown)], @[@"Del", @(KS_Delete)], @[@"⌨︎✕", @0]];
        NSMutableArray *buttons = [NSMutableArray array];
        for (NSArray *k in keys) {
            UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
            [b setTitle:k[0] forState:UIControlStateNormal];
            [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
            [b setTitleColor:UIColor.blackColor forState:UIControlStateSelected];
            b.titleLabel.font = [UIFont systemFontOfSize:17];
            b.titleLabel.adjustsFontSizeToFitWidth = YES;
            b.backgroundColor = [UIColor colorWithWhite:0.3 alpha:1];
            b.layer.cornerRadius = 6;
            b.tag = [k[1] intValue];
            [b addTarget:self action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];
            if (b.tag < 0)
                _mods[@(-b.tag)] = b;
            [buttons addObject:b];
        }
        UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:buttons];
        row.distribution = UIStackViewDistributionFillEqually;
        row.spacing = 6;
        row.frame = CGRectInset(self.bounds, 6, 6);
        row.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:row];
    }
    return self;
}

- (void)tapped:(UIButton *)b
{
    if (b.tag < 0) {
        b.selected = !b.selected;
        b.backgroundColor = b.selected ? self.tintColor : [UIColor colorWithWhite:0.3 alpha:1];
    } else if (b.tag == 0) {
        if (self.onHide)
            self.onHide();
    } else if (self.onKey) {
        self.onKey((uint32_t)b.tag);
    }
}

- (int)takeModifiers
{
    int mods = 0;
    for (NSNumber *m in _mods) {
        UIButton *b = _mods[m];
        if (b.selected)
            mods |= m.intValue;
        b.selected = NO;
        b.backgroundColor = [UIColor colorWithWhite:0.3 alpha:1];
    }
    return mods;
}
@end

#pragma mark - View controller

@interface ViewController : UIViewController <ConnectionDelegate, UIKeyInput>
@end

@implementation ViewController {
    VideoView *_video;
    UILabel *_status, *_indicator;
    SettingsPanel *_settings;
    KeyBar *_keyBar;
    __weak UITextView *_logText;
    __weak UIViewController *_logVC;
    NSArray<UIKeyCommand *> *_keyCommands;
    Connection *_conn;
    H264Feeder *_feeder;
    CGSize _remoteSize; /* host pixels, guarded by main thread */
    BOOL _streaming;
    LinkKind _link;     /* main thread copy, for the UI */
    atomic_int _frames; /* shown since the indicator last looked */

    /* touch state (main thread) */
    UITouch *_primary;
    CGPoint _startPoint, _lastPoint;
    CFTimeInterval _startTime, _lastTime;
    NSUInteger _maxFingers;
    BOOL _leftDown, _dragging, _twoFinger, _twoFingerMoved, _multiFinger, _consumed;
    CGPoint _scrollAnchor;
    CGFloat _scrollAccumX, _scrollAccumY, _relAccumX, _relAccumY;
    NSTimer *_holdTimer, *_middleTimer;
    NSTimer *_tapRelease; /* trackpad: the button of the last tap is still down until this fires */
    BOOL _tapDrag;        /* trackpad: this touch began during a tap, so it drags */
}

- (void)loadView
{
    UIView *root = [[UIView alloc] init];
    root.backgroundColor = UIColor.blackColor;
    root.multipleTouchEnabled = YES;

    _video = [[VideoView alloc] init];
    _video.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _video.displayLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    _video.userInteractionEnabled = NO;
    [root addSubview:_video];

    _status = [[UILabel alloc] init];
    _status.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _status.textAlignment = NSTextAlignmentCenter;
    _status.numberOfLines = 0;
    _status.textColor = [UIColor colorWithWhite:0.75 alpha:1];
    _status.font = [UIFont systemFontOfSize:20];
    [root addSubview:_status];

    _indicator = [[UILabel alloc] init];
    _indicator.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    _indicator.textAlignment = NSTextAlignmentCenter;
    _indicator.textColor = UIColor.whiteColor;
    _indicator.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium];
    _indicator.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    _indicator.layer.cornerRadius = 6;
    _indicator.clipsToBounds = YES;
    _indicator.userInteractionEnabled = NO;
    _indicator.hidden = YES;
    [root addSubview:_indicator];

    self.view = root;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    _video.frame = self.view.bounds;
    _status.frame = self.view.bounds;
    _indicator.frame = CGRectMake(self.view.bounds.size.width - 170, 8, 160, 24);

    _feeder = [[H264Feeder alloc] initWithLayer:_video.displayLayer];
    _conn = [[Connection alloc] init];
    _conn.delegate = self;
    [self showStatus:L(@"Waiting for the computer")];
    [_conn start];

    /* No suggestion/undo bar over the keyboard: it types into another computer. */
    self.inputAssistantItem.leadingBarButtonGroups = @[];
    self.inputAssistantItem.trailingBarButtonGroups = @[];

    __weak ViewController *weakSelf = self;
    [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *t) { [weakSelf updateIndicator]; }];
}

- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }

- (UIInterfaceOrientationMask)supportedInterfaceOrientations
{
    switch (settingInt(kOrientationKey, 0)) {
    case 1: return UIInterfaceOrientationMaskLandscape;
    case 2: return UIInterfaceOrientationMaskPortrait | UIInterfaceOrientationMaskPortraitUpsideDown;
    default: return UIInterfaceOrientationMaskAll;
    }
}

- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator
{
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [coordinator animateAlongsideTransition:^(id ctx) {
        [self->_settings fitInto:size];
    } completion:^(id ctx) {
        [self sendSettings];
    }];
}

static NSString *linkName(LinkKind k)
{
    switch (k) {
    case LinkUSB: return L(@"by cable");
    case LinkLAN: return L(@"over Wi-Fi");
    case LinkInternet: return L(@"over the internet");
    default: return L(@"not connected");
    }
}

- (void)setStreaming:(BOOL)streaming
{
    _streaming = streaming;
    /* Keep the screen on while it's a monitor, let it sleep otherwise. */
    UIApplication.sharedApplication.idleTimerDisabled = streaming;
}

/* Shows `text` with a hint about how to connect; nil hides the overlay. */
- (void)showStatus:(NSString *)text
{
    if (text) {
        NSString *how;
        if (_link != LinkNone)
            how = @"";
        else if (!computers().count)
            how = L(@"Connect the iPad to the computer with the cable.\n"
                    @"After the first time by cable it also works over Wi-Fi.\n");
        else
            how = [NSString stringWithFormat:L(@"%@\nOr plug in the cable.\n"), _conn.networkStatus ?: @""];
        text = [NSString stringWithFormat:L(@"%@\n\n%@Tap with three fingers for settings."), text, how];
    }
    _status.text = text;
    _status.hidden = text == nil;
    [self refreshSettingsNetwork];
}

- (void)refreshSettingsNetwork
{
    NSArray<NSDictionary *> *list = computers();
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSDictionary *c in list)
        [names addObject:computerName(c)];
    /* the first one is the one connected now, or used last */
    NSString *line = list.count
        ? [NSString stringWithFormat:L(@"Computer “%@”, now %@."), names[0], linkName(_link)]
        : L(@"Not paired yet: connect the iPad by cable once.");
    [_settings setNetworkLine:line address:list.count ? internetAddress(list[0]) : nil
                    computers:[names componentsJoinedByString:@", "]];
}

- (void)updateIndicator
{
    int frames = atomic_exchange(&_frames, 0);
    _indicator.hidden = !settingInt(kIndicatorKey, 0) || _link == LinkNone;
    _indicator.text = [NSString stringWithFormat:L(@"%@ · %d fps"), linkName(_link), frames];
}

/* The internet address of the computer used last (the first one). */
- (void)editAddress
{
    NSDictionary *c = computers().firstObject;
    if (!c)
        return;
    NSData *key = c[kKeyKey];
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:[NSString stringWithFormat:L(@"Internet address of “%@”"), computerName(c)]
                         message:L(@"Name or IP and port of the computer as reachable from the internet, "
                                   @"for example myhome.example.com:27183. Not needed on the same Wi-Fi.")
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.text = internetAddress(c);
        f.placeholder = L(@"name-or-ip:27183");
        f.keyboardType = UIKeyboardTypeURL;
        f.autocapitalizationType = UITextAutocapitalizationTypeNone;
        f.autocorrectionType = UITextAutocorrectionTypeNo;
        f.clearButtonMode = UITextFieldViewModeAlways;
    }];
    __weak UIAlertController *weakAlert = a;
    __weak ViewController *weakSelf = self;
    [a addAction:[UIAlertAction actionWithTitle:L(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    if ([c[kPairAddressKey] length])
        [a addAction:[UIAlertAction actionWithTitle:L(@"As set on the computer") style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *x) {
            editComputer(key, NO, ^BOOL(NSMutableDictionary *m) {
                [m removeObjectForKey:kAddressKey];
                return YES;
            });
            [weakSelf refreshSettingsNetwork];
        }]];
    [a addAction:[UIAlertAction actionWithTitle:L(@"Save") style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) {
        NSString *s = [weakAlert.textFields.firstObject.text
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        /* Empty means "nothing", even if the host suggested an address. */
        editComputer(key, NO, ^BOOL(NSMutableDictionary *m) {
            m[kAddressKey] = s;
            return YES;
        });
        [weakSelf refreshSettingsNetwork];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

/* Switch to another paired computer, or forget one. */
- (void)editComputers
{
    NSArray<NSDictionary *> *list = computers();
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:L(@"Paired computers")
                         message:L(@"Over Wi-Fi the iPad connects to the one used last. "
                                   @"To add a computer, connect the iPad to it by cable once.")
                  preferredStyle:UIAlertControllerStyleAlert];
    __weak ViewController *weakSelf = self;
    for (NSUInteger i = 1; i < list.count; i++) {
        NSData *key = list[i][kKeyKey];
        [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:L(@"Connect to “%@”"),
                                                                                computerName(list[i])]
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *x) {
            editComputer(key, YES, ^BOOL(NSMutableDictionary *m) { return YES; });
            [weakSelf switchedComputers];
        }]];
    }
    for (NSDictionary *c in list) {
        NSData *key = c[kKeyKey];
        [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:L(@"Forget “%@”"), computerName(c)]
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *x) {
            BOOL current = c == list[0];
            editComputer(key, NO, ^BOOL(NSMutableDictionary *m) { return NO; });
            if (current)
                [weakSelf switchedComputers];
            else
                [weakSelf refreshSettingsNetwork];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:L(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

/* The first computer changed: a Wi-Fi/internet session with another one ends (the cable stays). */
- (void)switchedComputers
{
    if (_link == LinkLAN || _link == LinkInternet)
        [_conn dropNetwork];
    [self refreshSettingsNetwork];
}

- (void)sendSettings
{
    CGSize b = self.view.bounds.size;
    int scale = settingInt(kScaleKey, CONNECTOR_SCALE_DEFAULT);
    uint8_t p[5] = {(uint8_t)(scale >> 8), (uint8_t)scale, (uint8_t)settingInt(kQualityKey, 1),
                    b.height > b.width, (uint8_t)settingInt(kMirrorKey, 0)};
    [_conn send:MSG_SETTINGS payload:p length:sizeof(p)];
}

- (void)sendAppInfo
{
    uint32_t t = (uint32_t)signatureExpiry().timeIntervalSince1970;
    NSMutableData *p = [NSMutableData dataWithBytes:(uint8_t[4]){t >> 24, t >> 16, t >> 8, t} length:4];
    [p appendData:[appDescription() dataUsingEncoding:NSUTF8StringEncoding]];
    [_conn send:MSG_APP_INFO payload:p.bytes length:(uint32_t)p.length];
}

/* The app's log goes to the computer's log while connected. */
- (void)connectLogSink:(BOOL)on
{
    __weak Connection *conn = _conn;
    AppLog.shared.sink = on ? ^(NSString *lines) {
        NSData *d = [lines dataUsingEncoding:NSUTF8StringEncoding];
        [conn send:MSG_LOG payload:d.bytes length:(uint32_t)d.length];
    } : nil;
    if (on)
        [AppLog.shared flushToSink];
}

- (void)showLog
{
    UIViewController *vc = [[UIViewController alloc] init];
    vc.modalPresentationStyle = UIModalPresentationFormSheet;
    vc.view.backgroundColor = [UIColor colorWithWhite:0.1 alpha:1];
    UITextView *text = [[UITextView alloc] initWithFrame:CGRectInset(vc.view.bounds, 0, 0)];
    text.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    text.editable = NO;
    text.backgroundColor = UIColor.clearColor;
    text.textColor = [UIColor colorWithWhite:0.85 alpha:1];
    text.font = [UIFont fontWithName:@"Menlo" size:12];
    text.text = [NSString stringWithFormat:@"%@\n\n%@", appDescription(), AppLog.shared.text];
    text.contentInset = UIEdgeInsetsMake(56, 0, 0, 0);
    [vc.view addSubview:text];

    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, vc.view.bounds.size.width, 52)];
    bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    bar.backgroundColor = [UIColor colorWithWhite:0.16 alpha:1];
    [vc.view addSubview:bar];
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectInset(bar.bounds, 120, 0)];
    title.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    title.text = L(@"App log");
    title.textColor = UIColor.whiteColor;
    title.textAlignment = NSTextAlignmentCenter;
    title.font = [UIFont boldSystemFontOfSize:17];
    [bar addSubview:title];
    __weak UIViewController *weakVC = vc;
    __weak UITextView *weakText = text;
    UIButton *copy = [UIButton buttonWithType:UIButtonTypeSystem];
    [copy setTitle:L(@"Copy") forState:UIControlStateNormal];
    copy.frame = CGRectMake(12, 8, 100, 36);
    copy.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [copy addTarget:self action:@selector(copyLog:) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:copy];
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setTitle:L(@"Close") forState:UIControlStateNormal];
    close.frame = CGRectMake(bar.bounds.size.width - 112, 8, 100, 36);
    close.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    close.contentHorizontalAlignment = UIControlContentHorizontalAlignmentRight;
    [close addTarget:self action:@selector(closeLog) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:close];
    _logText = weakText;
    _logVC = weakVC;
    [self presentViewController:vc animated:YES completion:^{
        [weakText scrollRangeToVisible:NSMakeRange(weakText.text.length, 0)];
    }];
}

- (void)copyLog:(UIButton *)sender
{
    UIPasteboard.generalPasteboard.string = _logText.text;
    [sender setTitle:L(@"Copied") forState:UIControlStateNormal];
}

- (void)closeLog
{
    [_logVC dismissViewControllerAnimated:YES completion:nil];
}

- (void)toggleSettings
{
    if (_settings) {
        [_settings removeFromSuperview];
        _settings = nil;
        return;
    }
    _settings = [[SettingsPanel alloc] init];
    [_settings fitInto:self.view.bounds.size];
    __weak ViewController *weakSelf = self;
    _settings.onChange = ^{
        ViewController *s = weakSelf;
        [UIViewController attemptRotationToDeviceOrientation];
        [s sendSettings];
        [s updateIndicator];
    };
    _settings.onClose = ^{ [weakSelf toggleSettings]; };
    _settings.onEditAddress = ^{ [weakSelf editAddress]; };
    _settings.onComputers = ^{ [weakSelf editComputers]; };
    _settings.onLog = ^{ [weakSelf showLog]; };
    _settings.onKeyboard = ^{
        [weakSelf toggleSettings];
        [weakSelf toggleKeyboard];
    };
    [self refreshSettingsNetwork];
    [self.view addSubview:_settings];
}

#pragma mark Keyboard

- (void)toggleKeyboard
{
    if (self.isFirstResponder)
        [self resignFirstResponder];
    else
        [self becomeFirstResponder];
}

- (BOOL)canBecomeFirstResponder { return YES; }

- (UIView *)inputAccessoryView
{
    if (!_keyBar) {
        _keyBar = [[KeyBar alloc] init];
        __weak ViewController *weakSelf = self;
        _keyBar.onKey = ^(uint32_t keysym) {
            ViewController *s = weakSelf;
            [s sendKeysym:keysym mods:[s->_keyBar takeModifiers]];
        };
        _keyBar.onHide = ^{ [weakSelf resignFirstResponder]; };
    }
    return _keyBar;
}

- (void)sendKeysym:(uint32_t)keysym mods:(int)mods
{
    uint8_t p[5] = {keysym >> 24, keysym >> 16, keysym >> 8, keysym, (uint8_t)mods};
    [_conn send:MSG_KEY payload:p length:sizeof(p)];
}

/* UIKeyInput: the on-screen keyboard and plain keys of a hardware one. */
- (BOOL)hasText { return YES; } /* so Backspace always works */

- (void)insertText:(NSString *)text
{
    int mods = [_keyBar takeModifiers];
    if (!mods) {
        NSData *utf8 = [text dataUsingEncoding:NSUTF8StringEncoding];
        [_conn send:MSG_TEXT payload:utf8.bytes length:(uint32_t)utf8.length];
        return;
    }
    for (NSUInteger i = 0; i < text.length; i++) {
        int m = mods;
        uint32_t ks = keysymForChar([text characterAtIndex:i], &m);
        [self sendKeysym:ks mods:m];
    }
}

- (void)deleteBackward { [self sendKeysym:KS_BackSpace mods:[_keyBar takeModifiers]]; }

/* What it types goes to another computer: no autocorrection or smart punctuation. */
- (UITextAutocorrectionType)autocorrectionType { return UITextAutocorrectionTypeNo; }
- (UITextAutocapitalizationType)autocapitalizationType { return UITextAutocapitalizationTypeNone; }
- (UITextSpellCheckingType)spellCheckingType { return UITextSpellCheckingTypeNo; }
- (UITextSmartQuotesType)smartQuotesType { return UITextSmartQuotesTypeNo; }
- (UITextSmartDashesType)smartDashesType { return UITextSmartDashesTypeNo; }
- (UITextSmartInsertDeleteType)smartInsertDeleteType { return UITextSmartInsertDeleteTypeNo; }
- (UIKeyboardAppearance)keyboardAppearance { return UIKeyboardAppearanceDark; }

/* Hardware keyboard: arrows, Esc and shortcuts. Cmd works as Ctrl, the way
 * Mac habits expect it on Linux. */
- (NSArray<UIKeyCommand *> *)keyCommands
{
    if (_keyCommands)
        return _keyCommands;
    NSMutableArray *a = [NSMutableArray array];
    const UIKeyModifierFlags S = UIKeyModifierShift, C = UIKeyModifierControl, A = UIKeyModifierAlternate,
                             M = UIKeyModifierCommand;
    NSArray *specials = @[UIKeyInputUpArrow, UIKeyInputDownArrow, UIKeyInputLeftArrow, UIKeyInputRightArrow,
                          UIKeyInputEscape];
    const UIKeyModifierFlags specialMods[] = {0, S, C, A, M, C | S, M | S, A | S};
    for (NSString *in in specials)
        for (size_t i = 0; i < sizeof(specialMods) / sizeof(specialMods[0]); i++)
            [a addObject:[UIKeyCommand keyCommandWithInput:in modifierFlags:specialMods[i]
                                                    action:@selector(keyCommand:)]];
    NSString *chars = @"abcdefghijklmnopqrstuvwxyz0123456789-=[];',./`\\\t\b\r ";
    const UIKeyModifierFlags charMods[] = {C, M, A, C | S, M | S, C | A, A | S};
    for (NSUInteger i = 0; i < chars.length; i++)
        for (size_t j = 0; j < sizeof(charMods) / sizeof(charMods[0]); j++)
            [a addObject:[UIKeyCommand keyCommandWithInput:[chars substringWithRange:NSMakeRange(i, 1)]
                                             modifierFlags:charMods[j]
                                                    action:@selector(keyCommand:)]];
    /* Shift+Tab doesn't reach insertText. */
    [a addObject:[UIKeyCommand keyCommandWithInput:@"\t" modifierFlags:S action:@selector(keyCommand:)]];
    _keyCommands = a;
    return a;
}

- (void)keyCommand:(UIKeyCommand *)c
{
    UIKeyModifierFlags f = c.modifierFlags;
    int mods = (f & UIKeyModifierShift ? MOD_SHIFT : 0) | (f & (UIKeyModifierControl | UIKeyModifierCommand) ? MOD_CTRL : 0) |
               (f & UIKeyModifierAlternate ? MOD_ALT : 0);
    uint32_t ks = keysymForInput(c.input, &mods);
    if (ks)
        [self sendKeysym:ks mods:mods | [_keyBar takeModifiers]];
}

#pragma mark ConnectionDelegate (called on the network thread)

- (void)connectionDidOpen:(LinkKind)kind
{
    CGSize px = UIScreen.mainScreen.nativeBounds.size;
    uint32_t w = (uint32_t)MAX(px.width, px.height), h = (uint32_t)MIN(px.width, px.height);
    uint8_t p[8] = {w >> 24, w >> 16, w >> 8, w, h >> 24, h >> 16, h >> 8, h};
    [_conn send:MSG_HELLO payload:p length:sizeof(p)];
    dispatch_async(dispatch_get_main_queue(), ^{
        /* Possibly a switch from Wi-Fi to the cable: start from a fresh keyframe. */
        self->_link = kind;
        self.streaming = NO;
        [self->_feeder reset];
        [self sendSettings];
        [self sendAppInfo];
        [self connectLogSink:YES];
        [self showStatus:[NSString stringWithFormat:L(@"Connected %@, waiting for the picture…"), linkName(kind)]];
    });
}

- (void)connectionDidClose
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_link = LinkNone;
        [self connectLogSink:NO];
        self.streaming = NO;
        [self->_feeder reset];
        [self showStatus:L(@"Connection lost")];
        [self updateIndicator];
    });
}

- (void)connectionDidPair
{
    dispatch_async(dispatch_get_main_queue(), ^{ [self refreshSettingsNetwork]; });
}

- (void)connectionStatusDidChange
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_link == LinkNone && !self->_status.hidden)
            [self showStatus:L(@"Waiting for the computer")];
    });
}

- (void)connectionDidConfigureWidth:(uint32_t)w height:(uint32_t)h
{
    dispatch_async(dispatch_get_main_queue(), ^{ self->_remoteSize = CGSizeMake(w, h); });
}

- (void)connectionDidReceiveVideo:(const uint8_t *)data length:(size_t)len
{
    if (![_feeder feedAnnexB:data length:len]) {
        [_conn send:MSG_KEYFRAME payload:NULL length:0];
        return;
    }
    atomic_fetch_add(&_frames, 1);
    if (!_streaming) {
        _streaming = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.streaming = YES;
            [self showStatus:nil];
        });
    }
}

#pragma mark Touch -> mouse

- (BOOL)trackpad { return settingInt(kTrackpadKey, 0) != 0; }

/* Maps a view point to normalized host coordinates, honouring aspect-fit letterboxing. */
- (BOOL)normalize:(CGPoint)pt x:(uint16_t *)nx y:(uint16_t *)ny
{
    if (_remoteSize.width <= 0)
        return NO;
    CGRect video = AVMakeRectWithAspectRatioInsideRect(_remoteSize, self.view.bounds);
    CGFloat fx = (pt.x - video.origin.x) / video.size.width;
    CGFloat fy = (pt.y - video.origin.y) / video.size.height;
    *nx = (uint16_t)lround(fmin(fmax(fx, 0), 1) * 65535);
    *ny = (uint16_t)lround(fmin(fmax(fy, 0), 1) * 65535);
    return YES;
}

- (void)moveTo:(CGPoint)pt
{
    uint16_t x, y;
    if (![self normalize:pt x:&x y:&y])
        return;
    uint8_t p[4] = {x >> 8, x, y >> 8, y};
    [_conn send:MSG_MOUSE_MOVE payload:p length:4];
}

/* Trackpad: moves the pointer by a finger movement, faster for quick swipes. */
- (void)moveBy:(CGPoint)d time:(CFTimeInterval)dt
{
    if (_remoteSize.width <= 0)
        return;
    CGRect video = AVMakeRectWithAspectRatioInsideRect(_remoteSize, self.view.bounds);
    CGFloat speed = hypot(d.x, d.y) / fmax(dt, 0.004); /* points per second */
    CGFloat gain = _remoteSize.width / video.size.width * (1 + fmin(speed / 700, 2));
    _relAccumX += d.x * gain;
    _relAccumY += d.y * gain;
    int dx = (int)_relAccumX, dy = (int)_relAccumY;
    if (!dx && !dy)
        return;
    _relAccumX -= dx;
    _relAccumY -= dy;
    uint8_t p[4] = {(uint16_t)dx >> 8, dx, (uint16_t)dy >> 8, dy};
    [_conn send:MSG_MOUSE_REL payload:p length:4];
}

- (void)button:(uint8_t)b down:(BOOL)down
{
    uint8_t p[2] = {b, down};
    [_conn send:MSG_BUTTON payload:p length:2];
}

- (void)click:(uint8_t)b
{
    [self button:b down:YES];
    [self button:b down:NO];
}

- (void)scrollX:(int)dx y:(int)dy
{
    uint8_t p[4] = {(uint16_t)dx >> 8, dx, (uint16_t)dy >> 8, dy};
    [_conn send:MSG_SCROLL payload:p length:4];
}

- (void)cancelHold
{
    [_holdTimer invalidate];
    _holdTimer = nil;
    [_middleTimer invalidate];
    _middleTimer = nil;
}

- (NSArray<UITouch *> *)activeTouches:(UIEvent *)event
{
    NSMutableArray *a = [NSMutableArray array];
    for (UITouch *t in [event touchesForView:self.view])
        if (t.phase != UITouchPhaseEnded && t.phase != UITouchPhaseCancelled)
            [a addObject:t];
    return a;
}

- (CGPoint)centroid:(UIEvent *)event
{
    CGPoint c = CGPointZero;
    NSArray<UITouch *> *all = [self activeTouches:event];
    for (UITouch *t in all) {
        CGPoint p = [t locationInView:self.view];
        c.x += p.x;
        c.y += p.y;
    }
    return all.count ? CGPointMake(c.x / all.count, c.y / all.count) : c;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    NSUInteger active = [self activeTouches:event].count;
    __weak ViewController *weakSelf = self;
    if (!_primary) {
        _primary = touches.anyObject;
        _startPoint = _lastPoint = [_primary locationInView:self.view];
        _startTime = _lastTime = _primary.timestamp;
        _maxFingers = 0;
        _leftDown = _dragging = _twoFinger = _multiFinger = _tapDrag = NO;
        /* A tap outside the open settings panel just closes it. */
        _consumed = _settings != nil;
        if (_settings)
            [self toggleSettings];
        if (self.trackpad && _tapRelease && !_consumed) {
            /* Touched again right after a tap: keep the button down and drag. */
            [_tapRelease invalidate];
            _tapRelease = nil;
            _tapDrag = _leftDown = YES;
        }
        if (active == 1 && !_consumed && !_tapDrag) {
            if (!self.trackpad)
                [self moveTo:_startPoint];
            _holdTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:NO block:^(NSTimer *t) {
                [weakSelf longPress];
            }];
        }
    }
    _maxFingers = MAX(_maxFingers, active);
    if (active >= 3) {
        [self cancelHold];
        if (_leftDown) {
            [self button:1 down:NO];
            _leftDown = NO;
        }
        _multiFinger = _consumed = YES;
        _twoFinger = NO;
    } else if (active == 2 && !_leftDown && !_consumed) {
        [self cancelHold];
        _twoFinger = YES;
        _twoFingerMoved = NO;
        _scrollAnchor = [self centroid:event];
        _scrollAccumX = _scrollAccumY = 0;
        _middleTimer = [NSTimer scheduledTimerWithTimeInterval:0.6 repeats:NO block:^(NSTimer *t) {
            [weakSelf middleHold];
        }];
    }
}

- (void)longPress
{
    _holdTimer = nil;
    if (!_primary || _leftDown || _twoFinger || _consumed)
        return;
    _consumed = YES;
    [self click:3];
}

- (void)middleHold
{
    _middleTimer = nil;
    if (!_primary || !_twoFinger || _twoFingerMoved || _consumed)
        return;
    _consumed = YES;
    [self click:2];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    if (!_primary || _consumed)
        return;
    if (_twoFinger) {
        CGPoint c = [self centroid:event];
        _scrollAccumX += c.x - _scrollAnchor.x;
        _scrollAccumY += c.y - _scrollAnchor.y;
        _scrollAnchor = c;
        const CGFloat step = 24; /* points per wheel click */
        int dx = (int)(_scrollAccumX / step), dy = (int)(_scrollAccumY / step);
        if (dx || dy) {
            _twoFingerMoved = YES;
            [_middleTimer invalidate];
            _middleTimer = nil;
            _scrollAccumX -= dx * step;
            _scrollAccumY -= dy * step;
            /* natural scrolling: content follows the fingers */
            [self scrollX:-dx y:-dy];
        }
        return;
    }
    if (![touches containsObject:_primary])
        return;
    CGPoint p = [_primary locationInView:self.view];
    BOOL moved = hypot(p.x - _startPoint.x, p.y - _startPoint.y) > 6;
    if (self.trackpad) {
        if (!_dragging && moved) {
            [self cancelHold];
            _dragging = YES;
        }
        if (_dragging)
            [self moveBy:CGPointMake(p.x - _lastPoint.x, p.y - _lastPoint.y) time:_primary.timestamp - _lastTime];
        _lastPoint = p;
        _lastTime = _primary.timestamp;
        return;
    }
    if (!_dragging && moved) {
        [self cancelHold];
        _dragging = YES;
        [self button:1 down:YES];
        _leftDown = YES;
    }
    if (_dragging)
        [self moveTo:p];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    [self finishTouches:touches event:event];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    [self finishTouches:touches event:event];
}

- (void)finishTouches:(NSSet<UITouch *> *)touches event:(UIEvent *)event
{
    if (!_primary || [self activeTouches:event].count)
        return;

    [self cancelHold];
    BOOL quick = CACurrentMediaTime() - _startTime < 0.8;
    if (_multiFinger) {
        if (quick && _maxFingers == 3)
            [self toggleSettings];
        else if (quick && _maxFingers >= 4)
            [self toggleKeyboard];
    } else if (_twoFinger) {
        if (!_twoFingerMoved && !_consumed)
            [self click:3];
    } else if (self.trackpad) {
        if (_tapDrag) {
            [self button:1 down:NO];
            if (!_dragging) /* tap, tap: a double click */
                [self click:1];
        } else if (!_dragging && !_consumed) {
            /* Hold the button a moment: touching again within it starts a drag. */
            [self button:1 down:YES];
            __weak ViewController *weakSelf = self;
            _tapRelease = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:NO block:^(NSTimer *t) {
                ViewController *s = weakSelf;
                s->_tapRelease = nil;
                [s button:1 down:NO];
            }];
        }
    } else if (_leftDown) {
        [self moveTo:[_primary locationInView:self.view]];
        [self button:1 down:NO];
    } else if (!_consumed) {
        [self click:1];
    }
    _primary = nil;
    _leftDown = _dragging = _twoFinger = _multiFinger = _consumed = _tapDrag = NO;
}
@end

#pragma mark - App delegate

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts
{
    NSDate *expires = signatureExpiry();
    APPLOG(@"launched: %@, signature until %@", appDescription(), expires ?: @"unknown");
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[ViewController alloc] init];
    [self.window makeKeyAndVisible];
    scheduleResignReminders(expires);
    return YES;
}

- (void)applicationDidReceiveMemoryWarning:(UIApplication *)app
{
    APPLOG(@"memory warning");
}

- (void)applicationDidEnterBackground:(UIApplication *)app
{
    APPLOG(@"app went to the background");
}

- (void)applicationWillEnterForeground:(UIApplication *)app
{
    APPLOG(@"app back in the foreground");
}
@end

int main(int argc, char *argv[])
{
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
